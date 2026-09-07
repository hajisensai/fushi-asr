import { useEffect, useRef, useState } from 'react';
import { CaptionsIcon, PlusIcon, SquareIcon, SunIcon, MoonIcon, ChevronRightIcon } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Checkbox } from '@/components/ui/checkbox';
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Field, FieldGroup, FieldLabel } from '@/components/ui/field';
import { Separator } from '@/components/ui/separator';
import { Empty, EmptyHeader, EmptyMedia, EmptyTitle, EmptyDescription } from '@/components/ui/empty';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible';
import { FileDrop } from '@/components/file-drop';
import { ResultCard } from '@/components/result-card';
import { ProgressPanel, phaseNames, type Batch } from '@/components/progress-panel';
import { DesktopNavigation, MobileNavigation } from '@/components/workspace-nav';
import { auth, transcribe, retime, TranscriptionTask } from '@/lib/api';
import type { Backend, Clock, Format, Language, ProgressEvent, SavedResult, WorkspaceMode } from '@/lib/types';
import '../progress.js';

function Options({ id, label, value, onChange, disabled, options }: { id: string; label: string; value: string; onChange: (v: string) => void; disabled: boolean; options: { value: string; label: string; disabled?: boolean }[] }) {
  return <Field data-disabled={disabled || undefined}><FieldLabel htmlFor={id}>{label}</FieldLabel><Select value={value} onValueChange={onChange} disabled={disabled}><SelectTrigger id={id} className="w-full min-w-0"><SelectValue placeholder="加载中…" /></SelectTrigger><SelectContent position="popper"><SelectGroup>{options.map(o => <SelectItem key={o.value} value={o.value} disabled={o.disabled}>{o.label}</SelectItem>)}</SelectGroup></SelectContent></Select></Field>;
}
export default function App() {
  const [file, setFile] = useState<File | null>(null), [book, setBook] = useState<File | null>(null), [audioOnly, setAudioOnly] = useState(false);
  const [mode, setMode] = useState<WorkspaceMode>('generate'), [subtitle, setSubtitle] = useState<File | null>(null);
  const isRetiming = mode === 'retime';
  const [languages, setLanguages] = useState<Language[]>([]), [backends, setBackends] = useState<Backend[]>([]);
  const [language, setLanguage] = useState('ja'), [engine, setEngine] = useState(''), [format, setFormat] = useState<Format>('srt');
  const [token, setToken] = useState(''), [draftToken, setDraftToken] = useState('');
  const [busy, setBusy] = useState(false), [results, setResults] = useState<SavedResult[]>([]), [batch, setBatch] = useState<Batch | null>(null);
  const [status, setStatus] = useState('正在读取可用方案…'), [error, setError] = useState(''), [stopping, setStopping] = useState(false);
  const activeTask = useRef<TranscriptionTask | null>(null), stopRequested = useRef(false);
  const [resetKey, setResetKey] = useState(0);
  const [dark, setDark] = useState(() => { try { return localStorage.getItem('fushi-theme') === 'dark'; } catch { return false; } });
  const lock = useRef(false), serial = useRef(0), clockRef = useRef<Clock | null>(null);
  if (!clockRef.current) clockRef.current = new FushiProgress.ProgressClock();
  const clock = clockRef.current;
  useEffect(() => { document.documentElement.classList.toggle('dark', dark); try { localStorage.setItem('fushi-theme', dark ? 'dark' : 'light'); } catch { /* private browsing */ } }, [dark]);
  useEffect(() => {
    const controller = new AbortController();
    Promise.all(['v1/models', 'v1/backends'].map(async url => { const r = await fetch(url, { headers: auth(token), signal: controller.signal }); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); }))
      .then(([models, data]) => { setLanguages(models.languages); setBackends(data.backends); setStatus('选择文件后即可生成字幕。'); setError(''); })
      .catch(e => { if (!controller.signal.aborted) { setBackends([]); setError('读取配置失败：' + e.message + '。如需令牌，请在连接设置中填写。'); } });
    return () => controller.abort();
  }, [token]);
  // Use the selected compatible backend, but never filter out language options.
  const selected = backends.find(b => b.id === engine && b.available && b.languages.includes(language)) ?? backends.find(b => b.available && b.languages.includes(language));
  const reazonId = selected?.id === 'coreml' ? 'coreml' : 'default';
  const comparison = ['apple', reazonId].flatMap(id => backends.filter(b => b.id === id && b.available && b.languages.includes(language)));
  const canRun = !busy && !!file && (isRetiming ? !!subtitle : audioOnly || !!book) && !!selected;
  useEffect(() => { if (!busy) return; const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; }; window.addEventListener('beforeunload', warn); return () => window.removeEventListener('beforeunload', warn); }, [busy]);
  // A file accidentally dropped outside a target must not navigate away and lose results.
  useEffect(() => { const prevent = (e: DragEvent) => { if (e.dataTransfer?.types.includes('Files')) e.preventDefault(); }; window.addEventListener('dragover', prevent); window.addEventListener('drop', prevent); return () => { window.removeEventListener('dragover', prevent); window.removeEventListener('drop', prevent); }; }, []);
  function newTask() { if (lock.current) return; setFile(null); setBook(null); setSubtitle(null); setResetKey(n => n + 1); clock.reset(); setBatch(null); setError(''); setStatus('新任务已准备好；已有结果仍保留在下方。'); document.getElementById('workspace')?.scrollIntoView(); }
  function changeMode(next: WorkspaceMode) {
    if (lock.current || next === mode) return;
    setMode(next); clock.reset(); setBatch(null); setError('');
    setStatus(next === 'retime' ? '导入已有字幕和对应媒体，即可校准时间轴。' : '选择文件后即可生成字幕。');
  }
  function stop() {
    const task = activeTask.current; if (!task) return;
    stopRequested.current = true; setStopping(true); setError('');
    clock.event({ phase: 'stopping' });
    setStatus('正在终止任务，等待后端释放运算资源；不会继续运行下一方案。');
    void task.stop().catch(e => {
      setStopping(false);
      setError('尚未确认后端停止：' + e.message + '。请点击终止任务重试。');
    });
  }
  async function run(compare: boolean) {
    if (!canRun || lock.current || !file || !selected) return;
    const list = compare ? comparison : [selected]; if (!list.length) return;
    const jobFile = file, jobSubtitle = isRetiming ? subtitle : null, jobBook = isRetiming || audioOnly ? null : book, start = performance.now();
    lock.current = true; stopRequested.current = false; setStopping(false); setBusy(true); setError(''); const errors: string[] = [];
    try {
      for (let i = 0; i < list.length; i++) {
        if (stopRequested.current) break;
        const task = new TranscriptionTask(token); activeTask.current = task;
        const backend = list[i]; clock.begin(); setBatch({ name: backend.name, count: list.length, index: i + 1, start }); setStatus(backend.name + '：上传中…');
        try {
          const onProgress = (ev: ProgressEvent) => { if (task.stopRequested) return; clock.event(ev); setStatus(backend.name + '：' + (phaseNames[ev.phase] || ev.phase) + (ev.detail ? ' · ' + ev.detail : '')); };
          const result = jobSubtitle
            ? await retime(backend, jobFile, jobSubtitle, language, format, token, onProgress, task)
            : await transcribe(backend, jobFile, jobBook, language, format, token, onProgress, task);
          if (task.stopRequested) { await task.stopped; clock.cancel(); break; }
          clock.end(result); const saved = { id: ++serial.current, result, file: jobFile, book: jobBook, subtitle: jobSubtitle, wallMs: clock.snapshot().elapsed };
          setResults(prev => [...prev, saved].slice(-6));
        } catch (e) {
          if (task.stopRequested) { await task.stopped; clock.cancel(); break; }
          clock.end(); errors.push(backend.name + '：' + (e instanceof Error ? e.message : String(e)));
        }
      }
      setError(errors.join('\n')); setStatus(stopRequested.current ? '任务已终止。已完成的结果仍保留，可重新运行。' : errors.length ? '部分或全部处理失败；已完成的结果仍保留。' : '完成：' + list.map(b => b.name).join('、') + '。' + (jobSubtitle ? '请查看对轴统计和提示，再下载校准后的字幕。' : jobBook ? 'EPUB 对齐字幕及原始转录均可下载。' : '字幕已保留，可下载。'));
    } finally { activeTask.current = null; setBatch(prev => prev ? { ...prev, end: performance.now() } : null); lock.current = false; setStopping(false); setBusy(false); }
  }
  return <>
    <a className="skip-link" href="#workspace">跳到工作台</a>
    <div><header className="topbar"><div className="flex items-center gap-2 min-w-0"><MobileNavigation mode={mode} disabled={busy} onChange={changeMode} /><a href="#workspace" className="font-medium whitespace-nowrap">Fushi · 字幕工作台</a></div><div className="flex items-center gap-2"><Button variant="ghost" size="sm" disabled={busy} onClick={newTask}><PlusIcon data-icon="inline-start" />新建任务</Button><Button id="theme" variant="ghost" size="icon" aria-label={dark ? '切换为浅色外观' : '切换为深色外观'} onClick={() => setDark(v => !v)}>{dark ? <MoonIcon /> : <SunIcon />}</Button></div></header>
      <div className="workspace-layout"><DesktopNavigation mode={mode} disabled={busy} onChange={changeMode} />
      <main className="workspace" id="workspace"><h1 className="text-[28px] sm:text-[32px] font-semibold tracking-tight">{isRetiming ? '把字幕，调回正确的时间。' : '让声音，与文字对齐。'}</h1><p className="mt-2 text-muted-foreground">{isRetiming ? '导入已有字幕与音视频，保留文字，校准时间轴。' : '导入书籍与音视频，生成贴合原文的字幕。'}</p>
        <section className="mt-8" aria-label={isRetiming ? '对轴设置' : '转录设置'}><div className="flex justify-between items-center gap-4 mb-4"><h2 className="section-title">源文件</h2>{!isRetiming ? <Field orientation="horizontal" className="w-auto" data-disabled={busy || undefined}><Checkbox id="audioOnly" disabled={busy} checked={audioOnly} onCheckedChange={v => setAudioOnly(v === true)} /><FieldLabel htmlFor="audioOnly">仅转录音频</FieldLabel></Field> : null}</div>
          <FieldGroup className="grid sm:grid-cols-2 gap-4">{isRetiming ? <FileDrop key={'subtitle-' + resetKey} kind="subtitle" file={subtitle} disabled={busy} onChange={setSubtitle} /> : <FileDrop key={'book-' + resetKey} kind="epub" file={book} disabled={busy || audioOnly} onChange={setBook} />}<FileDrop key={'audio-' + resetKey} kind="audio" file={file} disabled={busy} onChange={setFile} /></FieldGroup>
          {isRetiming ? <p className="note mt-4">字幕应与媒体中的对白使用同一种语言。根据语音识别结果匹配时间，保留原字幕文字、分行和条数；无法可靠匹配的部分会标为估算或保留原轴。WebVTT 的位置和样式设置不保留。</p> : null}
          <FieldGroup className="grid sm:grid-cols-[2fr_1fr_1fr] gap-4 mt-6">
            <Options id="engine" label="转录方案" value={selected?.id || ''} onChange={setEngine} disabled={busy || !backends.length} options={backends.map(b => ({ value: b.id, label: b.name + (!b.available ? '（不可用）' : !b.languages.includes(language) ? '（不支持所选语言）' : ''), disabled: !b.available || !b.languages.includes(language) }))} />
            <Options id="lang" label="语言" value={language} onChange={setLanguage} disabled={busy || !languages.length} options={languages.map(l => ({ value: l.tag, label: l.nativeName + ' (' + l.tag + ')' }))} />
            <Options id="fmt" label="字幕格式" value={format} onChange={v => setFormat(v as Format)} disabled={busy} options={[{ value: 'srt', label: 'SRT' }, { value: 'vtt', label: 'WebVTT' }, { value: 'json', label: 'JSON' }]} />
          </FieldGroup>
          <p className="note mt-3" id="engineNote">{selected?.description || '没有可用方案，请检查模型资源或所选语言。'}</p>
          <Collapsible className="mt-3"><CollapsibleTrigger asChild><Button variant="ghost" size="sm"><ChevronRightIcon data-icon="inline-start" />连接设置</Button></CollapsibleTrigger><CollapsibleContent><FieldGroup className="max-w-sm mt-3"><Field data-disabled={busy || undefined}><FieldLabel htmlFor="token">令牌（服务器启用鉴权时填写）</FieldLabel><Input id="token" type="password" autoComplete="off" placeholder="本机可留空" disabled={busy} value={draftToken} onChange={e => setDraftToken(e.target.value)} /></Field><Button variant="outline" disabled={busy} onClick={() => setToken(draftToken)}>应用连接设置</Button></FieldGroup></CollapsibleContent></Collapsible>
          <div className="flex flex-wrap items-center gap-3 mt-5"><Button id="go" size="lg" disabled={!canRun} onClick={() => run(false)}>{busy ? '处理中…' : isRetiming ? '开始对轴' : audioOnly ? '生成原始字幕' : '生成对齐字幕'}</Button>{busy ? <Button id="stop" size="lg" variant="outline" disabled={stopping} onClick={stop}><SquareIcon data-icon="inline-start" />{stopping ? '正在停止…' : '终止任务'}</Button> : null}{comparison.length >= 2 ? <><Button id="compare" size="lg" variant="outline" disabled={!canRun} onClick={() => run(true)}>{isRetiming ? '两种方案各对轴一次' : '两种方案各生成一次'}</Button><span className="note">Apple / {reazonId === 'coreml' ? 'CoreML' : '原版 INT8'} · 顺序运行，分别保留。</span></> : null}</div>
        </section>
        <Separator className="my-6" /><ProgressPanel clock={clock} busy={busy} batch={batch} audioOnly={!isRetiming && audioOnly} retiming={isRetiming} />
        <p id="status" role="status" aria-live="polite" className="note mt-3">{status}</p>{error ? <Alert variant="destructive" className="mt-3"><AlertTitle>任务未完成</AlertTitle><AlertDescription><p className="whitespace-pre-wrap break-all">{error}</p></AlertDescription></Alert> : null}
        <Separator className="my-6" /><section id="resultSection" className="scroll-mt-20"><div className="flex items-center justify-between"><h2 className="section-title">处理结果</h2><Button id="clear" size="sm" variant="outline" disabled={busy || !results.length} onClick={() => setResults([])}>清空</Button></div>
          {!results.length ? <Empty className="py-10"><EmptyHeader><EmptyMedia variant="icon"><CaptionsIcon /></EmptyMedia><EmptyTitle>{isRetiming ? '校准后的字幕将在这里呈现' : '字幕将在这里呈现'}</EmptyTitle><EmptyDescription>{isRetiming ? '对轴后可查看匹配统计，预览并下载字幕。' : '生成后可预览、比较并下载字幕。'}</EmptyDescription></EmptyHeader></Empty> : <div id="results" className="grid lg:grid-cols-2 gap-6 mt-4">{results.map(saved => <ResultCard key={saved.id} saved={saved} />)}</div>}
        </section>
      </main>
      </div>
    </div>
  </>;
}
