import { useEffect, useRef, useState } from 'react';
import { CaptionsIcon, SquareIcon, ChevronRightIcon } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Checkbox } from '@/components/ui/checkbox';
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Field, FieldGroup, FieldLabel } from '@/components/ui/field';
import { Empty, EmptyHeader, EmptyMedia, EmptyTitle, EmptyDescription } from '@/components/ui/empty';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible';
import { FileDrop } from '@/components/file-drop';
import { ResultCard } from '@/components/result-card';
import { ProgressPanel, phaseName, type Batch } from '@/components/progress-panel';
import { Section, SiteFooter, SiteNav, ToTop } from '@/components/site-chrome';
import { useT } from '@/lib/i18n-react';
import type { Key } from '@/lib/i18n';
import { auth, transcribe, retime, TranscriptionTask } from '@/lib/api';
import { engineDescription, engineLabel } from '@/lib/engine-label';
import { ModelStatusPanel } from '@/components/model-status';
import { progressDetail } from '@/lib/progress-detail';
import type { Backend, Clock, Format, Language, ProgressEvent, SavedResult, WorkspaceMode } from '@/lib/types';
import '../progress.js';

/** 状态行存的是键而不是成品句子：换界面语言时它要跟着变，不能停在上一种语言。 */
type Status = { key: Key; params?: Record<string, string | number>; phase?: string };

function Options({ id, label, value, onChange, disabled, placeholder, options }: { id: string; label: string; value: string; onChange: (v: string) => void; disabled: boolean; placeholder: string; options: { value: string; label: string; disabled?: boolean }[] }) {
  return <Field data-disabled={disabled || undefined}><FieldLabel htmlFor={id}>{label}</FieldLabel><Select value={value} onValueChange={onChange} disabled={disabled}><SelectTrigger id={id} className="w-full min-w-0"><SelectValue placeholder={placeholder} /></SelectTrigger><SelectContent position="popper"><SelectGroup>{options.map(o => <SelectItem key={o.value} value={o.value} disabled={o.disabled}>{o.label}</SelectItem>)}</SelectGroup></SelectContent></Select></Field>;
}
export default function App() {
  const t = useT();
  const [file, setFile] = useState<File | null>(null), [book, setBook] = useState<File | null>(null), [audioOnly, setAudioOnly] = useState(false);
  const [mode, setMode] = useState<WorkspaceMode>('generate'), [subtitle, setSubtitle] = useState<File | null>(null);
  const isRetiming = mode === 'retime';
  const [languages, setLanguages] = useState<Language[]>([]), [backends, setBackends] = useState<Backend[]>([]);
  const [language, setLanguage] = useState('ja'), [engine, setEngine] = useState(''), [format, setFormat] = useState<Format>('srt');
  const [token, setToken] = useState(''), [draftToken, setDraftToken] = useState('');
  const [busy, setBusy] = useState(false), [results, setResults] = useState<SavedResult[]>([]), [batch, setBatch] = useState<Batch | null>(null);
  const [status, setStatus] = useState<Status>({ key: 'status.loading' }), [error, setError] = useState(''), [stopping, setStopping] = useState(false);
  const activeTask = useRef<TranscriptionTask | null>(null), stopRequested = useRef(false);
  const [resetKey, setResetKey] = useState(0);
  const [dark, setDark] = useState(() => { try { return localStorage.getItem('fushi-theme') === 'dark'; } catch { return false; } });
  const lock = useRef(false), serial = useRef(0), clockRef = useRef<Clock | null>(null);
  // The engine list is fetched per token, not per mode; a ref keeps that effect off the mode's dependency list.
  const modeRef = useRef(mode); modeRef.current = mode;
  const readyStatus = (): Status => ({ key: modeRef.current === 'retime' ? 'status.readyRetime' : 'status.ready' });
  if (!clockRef.current) clockRef.current = new FushiProgress.ProgressClock();
  const clock = clockRef.current;
  useEffect(() => { document.documentElement.classList.toggle('dark', dark); try { localStorage.setItem('fushi-theme', dark ? 'dark' : 'light'); } catch { /* private browsing */ } }, [dark]);
  useEffect(() => {
    const controller = new AbortController();
    setStatus({ key: 'status.loading' });
    Promise.all(['v1/models', 'v1/backends'].map(async url => { const r = await fetch(url, { headers: auth(token), signal: controller.signal }); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); }))
      .then(([models, data]) => { setLanguages(models.languages); setBackends(data.backends); setStatus(readyStatus()); setError(''); })
      .catch(e => { if (!controller.signal.aborted) { setBackends([]); setError(t('error.config', { message: e.message })); } });
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
  function newTask() { if (lock.current) return; setFile(null); setBook(null); setSubtitle(null); setResetKey(n => n + 1); clock.reset(); setBatch(null); setError(''); setStatus({ key: 'status.newTask' }); document.getElementById('workspace')?.scrollIntoView(); }
  function changeMode(next: WorkspaceMode) {
    if (lock.current || next === mode) return;
    setMode(next); clock.reset(); setBatch(null); setError('');
    setStatus({ key: next === 'retime' ? 'status.readyRetime' : 'status.ready' });
  }
  function stop() {
    const task = activeTask.current; if (!task) return;
    stopRequested.current = true; setStopping(true); setError('');
    clock.event({ phase: 'stopping' });
    setStatus({ key: 'status.stopping' });
    void task.stop().catch(e => {
      setStopping(false);
      setError(t('error.stop', { message: e.message }));
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
        const backend = list[i]; clock.begin(); setBatch({ name: engineLabel(backend), count: list.length, index: i + 1, start }); setStatus({ key: 'status.uploading', params: { name: engineLabel(backend) } });
        try {
          const onProgress = (ev: ProgressEvent) => {
            if (task.stopRequested) return;
            clock.event(ev);
            const detail = progressDetail(ev, t);
            setStatus({ key: detail ? 'status.phaseDetail' : 'status.phase', params: { name: engineLabel(backend), detail }, phase: ev.phase });
          };
          const result = jobSubtitle
            ? await retime(backend, jobFile, jobSubtitle, language, format, token, onProgress, task)
            : await transcribe(backend, jobFile, jobBook, language, format, token, onProgress, task);
          if (task.stopRequested) { await task.stopped; clock.cancel(); break; }
          clock.end(result); const saved = { id: ++serial.current, result, file: jobFile, book: jobBook, subtitle: jobSubtitle, wallMs: clock.snapshot().elapsed };
          setResults(prev => [...prev, saved].slice(-6));
        } catch (e) {
          if (task.stopRequested) { await task.stopped; clock.cancel(); break; }
          clock.end(); errors.push(t('error.job', { name: engineLabel(backend), message: e instanceof Error ? e.message : String(e) }));
        }
      }
      setError(errors.join('\n'));
      const names = list.map(b => b.name).join(t('status.separator'));
      setStatus(stopRequested.current ? { key: 'status.cancelled' } : errors.length ? { key: 'status.partial' } : { key: jobSubtitle ? 'status.doneRetime' : jobBook ? 'status.doneAligned' : 'status.doneAudio', params: { names } });
    } finally { activeTask.current = null; setBatch(prev => prev ? { ...prev, end: performance.now() } : null); lock.current = false; setStopping(false); setBusy(false); }
  }
  return <>
    <a className="skip-link" href="#workspace">{t('nav.skip')}</a>
    <SiteNav mode={mode} busy={busy} dark={dark} onMode={changeMode} onTheme={() => setDark(v => !v)} onNewTask={newTask} />
    <main id="workspace">
      <div className="shell hero">
        <p className="eyebrow">{t(isRetiming ? 'hero.eyebrow.retime' : 'hero.eyebrow.generate')}</p>
        <h1 className="h-page mt-3">{t(isRetiming ? 'hero.title.retime' : 'hero.title.generate')}</h1>
        <p className="copy copy-2 mt-5 max-w-[600px]">{t(isRetiming ? 'hero.copy.retime' : 'hero.copy.generate')}</p>
      </div>

      <Section band label={t(isRetiming ? 'source.settingsRetime' : 'source.settingsGenerate')}>
        <div className="flex justify-between items-center gap-4 mb-5"><h2 className="h-section">{t('source.title')}</h2>{!isRetiming ? <Field orientation="horizontal" className="w-auto" data-disabled={busy || undefined}><Checkbox id="audioOnly" disabled={busy} checked={audioOnly} onCheckedChange={v => setAudioOnly(v === true)} /><FieldLabel htmlFor="audioOnly">{t('source.audioOnly')}</FieldLabel></Field> : null}</div>
        <FieldGroup className="grid sm:grid-cols-2 gap-4">{isRetiming ? <FileDrop key={'subtitle-' + resetKey} kind="subtitle" file={subtitle} disabled={busy} onChange={setSubtitle} /> : <FileDrop key={'book-' + resetKey} kind="epub" file={book} disabled={busy || audioOnly} onChange={setBook} />}<FileDrop key={'audio-' + resetKey} kind="audio" file={file} disabled={busy} onChange={setFile} /></FieldGroup>
        {isRetiming ? <p className="note mt-4">{t('source.retimeNote')}</p> : null}
        <FieldGroup className="grid sm:grid-cols-[2fr_1fr_1fr] gap-4 mt-6">
          <Options id="engine" label={t('options.engine')} placeholder={t('options.loading')} value={selected?.id || ''} onChange={setEngine} disabled={busy || !backends.length} options={backends.map(b => ({ value: b.id, label: engineLabel(b) + (!b.available ? t('options.unavailable') : !b.languages.includes(language) ? t('options.langUnsupported') : ''), disabled: !b.available || !b.languages.includes(language) }))} />
          <Options id="lang" label={t('options.language')} placeholder={t('options.loading')} value={language} onChange={setLanguage} disabled={busy || !languages.length} options={languages.map(l => ({ value: l.tag, label: l.nativeName + ' (' + l.tag + ')' }))} />
          <Options id="fmt" label={t('options.format')} placeholder={t('options.loading')} value={format} onChange={v => setFormat(v as Format)} disabled={busy} options={[{ value: 'srt', label: 'SRT' }, { value: 'vtt', label: 'WebVTT' }, { value: 'json', label: 'JSON' }]} />
        </FieldGroup>
        <p className="note mt-3" id="engineNote">{selected ? engineDescription(selected) : t('options.noEngine')}</p>
        <ModelStatusPanel language={language} engine={selected?.id ?? ''} token={token} disabled={busy} />
        <Collapsible className="mt-3"><CollapsibleTrigger asChild><Button variant="ghost" size="sm"><ChevronRightIcon data-icon="inline-start" />{t('connection.title')}</Button></CollapsibleTrigger><CollapsibleContent><FieldGroup className="max-w-sm mt-3"><Field data-disabled={busy || undefined}><FieldLabel htmlFor="token">{t('connection.token')}</FieldLabel><Input id="token" type="password" autoComplete="off" placeholder={t('connection.tokenHint')} disabled={busy} value={draftToken} onChange={e => setDraftToken(e.target.value)} /></Field><Button variant="outline" disabled={busy} onClick={() => setToken(draftToken)}>{t('connection.apply')}</Button></FieldGroup></CollapsibleContent></Collapsible>
        <div className="flex flex-wrap items-center gap-3 mt-7"><button type="button" id="go" className="btn" disabled={!canRun} onClick={() => run(false)}>{busy ? t('action.busy') : t(isRetiming ? 'action.retime' : audioOnly ? 'action.generateAudio' : 'action.generate')}</button>{busy ? <Button id="stop" size="lg" variant="outline" disabled={stopping} onClick={stop}><SquareIcon data-icon="inline-start" />{stopping ? t('action.stopping') : t('action.stop')}</Button> : null}{comparison.length >= 2 ? <><Button id="compare" size="lg" variant="outline" disabled={!canRun} onClick={() => run(true)}>{t(isRetiming ? 'action.compareRetime' : 'action.compareGenerate')}</Button><span className="note">{t('action.compareNote', { a: 'Apple', b: t(reazonId === 'coreml' ? 'action.engineCoreml' : 'action.engineInt8') })}</span></> : null}</div>
      </Section>

      <Section label={t('progress.section')}>
        <ProgressPanel clock={clock} busy={busy} batch={batch} audioOnly={!isRetiming && audioOnly} retiming={isRetiming} />
        <p id="status" role="status" aria-live="polite" className="note mt-4">{t(status.key, status.phase ? { ...status.params, phase: phaseName(t, status.phase) } : status.params)}</p>
        {error ? <Alert variant="destructive" className="mt-3"><AlertTitle>{t('error.title')}</AlertTitle><AlertDescription><p className="whitespace-pre-wrap break-all">{error}</p></AlertDescription></Alert> : null}
      </Section>

      <Section band id="resultSection" label={t('results.title')}>
        <div className="flex items-center justify-between gap-4"><h2 className="h-section">{t('results.title')}</h2><Button id="clear" size="sm" variant="outline" disabled={busy || !results.length} onClick={() => setResults([])}>{t('results.clear')}</Button></div>
        {!results.length
          ? <Empty className="py-10"><EmptyHeader><EmptyMedia variant="icon"><CaptionsIcon /></EmptyMedia><EmptyTitle>{t(isRetiming ? 'results.empty.titleRetime' : 'results.empty.title')}</EmptyTitle><EmptyDescription>{t(isRetiming ? 'results.empty.descRetime' : 'results.empty.desc')}</EmptyDescription></EmptyHeader></Empty>
          : <div id="results" className="grid lg:grid-cols-2 gap-6 mt-4">{results.map(saved => <ResultCard key={saved.id} saved={saved} />)}</div>}
      </Section>
    </main>
    <SiteFooter />
    <ToTop />
  </>;
}
