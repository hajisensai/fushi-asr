import type { Backend, Format, ProgressEvent, Result } from './types';
export function auth(token: string): Record<string, string> { return token.trim() ? { Authorization: 'Bearer ' + token.trim() } : {}; }
export class TranscriptionTask {
  readonly controller = new AbortController();
  readonly id: Promise<string>;
  stopRequested = false;
  private pendingStop: Promise<void> | null = null;
  private acknowledge!: () => void;
  readonly stopped = new Promise<void>(resolve => { this.acknowledge = resolve; });
  private token: string;
  constructor(token: string) {
    this.token = token;
    this.id = fetch('v1/jobs', { method: 'POST', headers: auth(token) }).then(async r => {
      if (!r.ok) throw new Error('创建任务失败：HTTP ' + r.status);
      return (await r.json()).jobId as string;
    });
  }
  stop(): Promise<void> {
    this.stopRequested = true;
    this.controller.abort();
    if (this.pendingStop) return this.pendingStop;
    this.pendingStop = this.id.then(async id => {
      const r = await fetch(`v1/jobs/${id}/cancel`, { method: 'POST', headers: auth(this.token) });
      if (!r.ok) throw new Error('终止请求失败：HTTP ' + r.status);
      await r.json(); // The server acknowledges only after releasing the slot.
    }, () => { /* No ID: audio was never submitted. */ })
      .then(() => this.acknowledge()).finally(() => { this.pendingStop = null; });
    return this.pendingStop;
  }
}
export async function readEvents(response: Response, onProgress: (e: ProgressEvent) => void): Promise<Result> {
  if (!response.ok) throw new Error('HTTP ' + response.status + ' ' + await response.text());
  if (!response.body) throw new Error('服务端没有返回数据流');
  const reader = response.body.getReader(), decoder = new TextDecoder();
  let buffer = '', result: Result | null = null;
  function line(value: string) {
    if (!value.trim()) return;
    const ev = JSON.parse(value) as ProgressEvent;
    if (ev.phase === 'error') throw new Error(ev.error || '生成失败');
    if (ev.phase === 'cancelled') throw new DOMException('任务已终止', 'AbortError');
    if (ev.phase === 'result') { result = ev as Result; return; }
    onProgress(ev);
  }
  try {
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n'); buffer = lines.pop()!; lines.forEach(line);
    }
    line(buffer + decoder.decode());
    if (!result) throw new Error('连接结束但没有收到结果');
    return result;
  } finally { await reader.cancel(); }
}
export async function transcribe(backend: Backend, file: File, book: File | null, language: string, format: Format, token: string, onProgress: (e: ProgressEvent) => void, task: TranscriptionTask) {
  return submit('transcribe', backend, file, book ? { field: 'epub', file: book } : null, language, format, token, onProgress, task);
}
export async function retime(backend: Backend, file: File, subtitle: File, language: string, format: Format, token: string, onProgress: (e: ProgressEvent) => void, task: TranscriptionTask) {
  return submit('retime', backend, file, { field: 'subtitle', file: subtitle }, language, format, token, onProgress, task);
}
async function submit(endpoint: 'transcribe' | 'retime', backend: Backend, file: File, reference: { field: 'epub' | 'subtitle'; file: File } | null, language: string, format: Format, token: string, onProgress: (e: ProgressEvent) => void, task: TranscriptionTask) {
  const jobId = await task.id;
  if (task.stopRequested) throw new DOMException('任务已终止', 'AbortError');
  const query = new URLSearchParams({ language, format, engine: backend.id, filename: file.name, jobId });
  let body: File | FormData = file;
  if (reference) { body = new FormData(); body.append(reference.field, reference.file); body.append('audio', file); }
  return readEvents(await fetch('v1/' + endpoint + '?' + query, { method: 'POST', body, headers: auth(token), signal: task.controller.signal }), onProgress);
}
export function download(result: Result, file: File, raw = false) {
  const url = URL.createObjectURL(new Blob([raw ? result.rawText! : result.text], { type: 'text/plain;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url;
  a.download = file.name.replace(/\.[^.]+$/, '') + '-' + result.engine + (raw ? '-raw' : result.retiming ? '-retimed' : result.alignment ? '-aligned' : '') + '.' + result.format;
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
