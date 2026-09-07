import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readEvents, TranscriptionTask, retime, transcribe } from './api.ts';
function response(text: string) {
  const bytes = new TextEncoder().encode(text);
  return new Response(new ReadableStream({ start(c) { for (const byte of bytes) c.enqueue(new Uint8Array([byte])); c.close(); } }));
}
test('cancelled stream is never mistaken for a result', async () => {
  await assert.rejects(readEvents(response('{"phase":"cancelled"}'), () => {}), { name: 'AbortError' });
});
test('stop aborts upload but waits for backend acknowledgement; failures can retry', async () => {
  const original = globalThis.fetch;
  let attempts = 0, acknowledge: ((r: Response) => void) | undefined;
  globalThis.fetch = (async (url: string) => {
    if (url === 'v1/jobs') return Response.json({ jobId: 'id' });
    attempts++;
    if (attempts === 1) return new Response('', { status: 503 });
    return new Promise<Response>(resolve => { acknowledge = resolve; });
  }) as typeof fetch;
  try {
    const task = new TranscriptionTask('token');
    await assert.rejects(task.stop(), /503/);
    assert.equal(task.controller.signal.aborted, true);
    let stopped = false; void task.stopped.then(() => { stopped = true; });
    const retry = task.stop(); await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(stopped, false);
    acknowledge!(Response.json({ status: 'cancelled' }));
    await retry; await task.stopped; assert.equal(stopped, true);
  } finally { globalThis.fetch = original; }
});
test('NDJSON parser handles split UTF-8 and final lines without newline', async () => {
  const phases: string[] = [];
  const result = await readEvents(response('{"phase":"transcribe","detail":"日本語"}\n{"phase":"result","text":"字幕"}'), e => phases.push(e.phase));
  assert.equal(result.text, '字幕'); assert.deepEqual(phases, ['transcribe']);
});
test('error, incomplete and HTTP failure never reuse a previous result', async () => {
  await readEvents(response('{"phase":"result","text":"previous"}'), () => {});
  await assert.rejects(readEvents(response('{"phase":"error","error":"failed"}'), () => {}), /failed/);
  await assert.rejects(readEvents(response('{"phase":"done"}'), () => {}), /没有收到结果/);
  await assert.rejects(readEvents(new Response('denied', { status: 401 }), () => {}), /401/);
});
test('retiming submits the original subtitle and media to its own cancellable endpoint', async () => {
  const original = globalThis.fetch;
  const media = new File(['audio'], 'clip.mp4'), subtitle = new File(['subtitle'], 'old.SRT');
  let submitted = false;
  globalThis.fetch = (async (url: string, options: RequestInit) => {
    if (url === 'v1/jobs') return Response.json({ jobId: 'retiming-job' });
    const request = new URL(url, 'http://localhost');
    assert.equal(request.pathname, '/v1/retime');
    assert.equal(request.searchParams.get('jobId'), 'retiming-job');
    assert.equal(request.searchParams.get('filename'), 'clip.mp4');
    assert.equal(request.searchParams.get('format'), 'vtt');
    assert.equal(request.searchParams.get('language'), 'ja');
    assert.equal(request.searchParams.get('engine'), 'default');
    assert.deepEqual(options.headers, { Authorization: 'Bearer secret' });
    assert.ok(options.signal instanceof AbortSignal);
    assert.ok(options.body instanceof FormData);
    const body = options.body as FormData;
    assert.deepEqual([...body.keys()].sort(), ['audio', 'subtitle']);
    assert.equal(await (body.get('subtitle') as File).text(), 'subtitle');
    assert.equal((body.get('audio') as File).name, 'clip.mp4');
    submitted = true;
    return response('{"phase":"result","text":"retimed"}');
  }) as typeof fetch;
  try {
    const result = await retime({ id: 'default', name: 'Default', description: '', available: true, languages: ['ja'] }, media, subtitle, 'ja', 'vtt', 'secret', () => {}, new TranscriptionTask('secret'));
    assert.ok(submitted); assert.equal(result.text, 'retimed');
  } finally { globalThis.fetch = original; }
});
test('generation retains raw audio and EPUB multipart upload contracts', async () => {
  const original = globalThis.fetch, bodies: (BodyInit | null | undefined)[] = [];
  globalThis.fetch = (async (url: string, options: RequestInit) => {
    if (url === 'v1/jobs') return Response.json({ jobId: 'generation-job' });
    assert.ok(url.startsWith('v1/transcribe?')); bodies.push(options.body);
    return response('{"phase":"result","text":"generated"}');
  }) as typeof fetch;
  try {
    const backend = { id: 'default', name: 'Default', description: '', available: true, languages: ['ja'] };
    const media = new File(['audio'], 'clip.wav'), book = new File(['book'], 'book.epub');
    await transcribe(backend, media, null, 'ja', 'srt', '', () => {}, new TranscriptionTask(''));
    await transcribe(backend, media, book, 'ja', 'srt', '', () => {}, new TranscriptionTask(''));
    assert.equal(bodies[0], media);
    assert.ok(bodies[1] instanceof FormData);
    assert.deepEqual([...(bodies[1] as FormData).keys()].sort(), ['audio', 'epub']);
  } finally { globalThis.fetch = original; }
});
