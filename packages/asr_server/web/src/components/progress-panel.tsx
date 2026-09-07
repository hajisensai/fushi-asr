import { useEffect, useState } from 'react';
import { Progress } from '@/components/ui/progress';
import { cn } from '@/lib/utils';
import { useLanguage, useT } from '@/lib/i18n-react';
import type { Key, Translate } from '@/lib/i18n';
import type { Clock } from '@/lib/types';

const phaseKeys = ['idle', 'upload', 'queued', 'book', 'subtitle', 'download', 'load', 'transcribe', 'finalize', 'align', 'retime', 'complete', 'error', 'stopping', 'cancelled'] as const;
/** 后端阶段名 → 本地化名字。认不出的阶段原样显示，不吞掉。 */
export function phaseName(t: Translate, phase: string): string {
  return (phaseKeys as readonly string[]).includes(phase) ? t(`phase.${phase}` as Key) : phase;
}
export type Batch = { name: string; index: number; count: number; start: number; end?: number };
export function ProgressPanel({ clock, busy, batch, audioOnly, retiming = false }: { clock: Clock; busy: boolean; batch: Batch | null; audioOnly: boolean; retiming?: boolean }) {
  const t = useT(), lang = useLanguage();
  const [, tick] = useState(0);
  // Keep the high-frequency clock local: large subtitle previews never rerender.
  useEffect(() => { if (!busy) return; const timer = setInterval(() => tick(n => n + 1), 250); return () => clearInterval(timer); }, [busy]);
  const s = clock.snapshot(), { duration } = FushiProgress;
  const remaining = s.stage === 'complete' ? t('remaining.complete') : ['error', 'cancelled'].includes(s.stage) ? t('remaining.stopped') : s.stage === 'stopping' ? t('remaining.stopping') : s.remaining !== null ? t('remaining.about', { time: duration(Math.max(1000, s.remaining)) }) : s.stage === 'transcribe' && (s.total || 0) > 0 && (s.processed || 0) >= (s.total || 0) ? t('remaining.finishing') : s.stage === 'idle' ? t('remaining.unknown') : t('remaining.estimating');
  const step = ({ upload: 0, queued: 0, book: 1, subtitle: 1, download: 2, load: 2, transcribe: 2, finalize: 2, align: 3, retime: 3, complete: 4 } as Record<string, number>)[s.stage] ?? -1;
  let note = t('timing.idle');
  if (s.stage === 'complete') note = t('timing.complete');
  else if (s.stage === 'error') note = t('timing.error');
  else if (s.stage === 'cancelled') note = t('timing.cancelled');
  else if (s.stage === 'stopping') note = t('timing.stopping');
  else if (s.stage === 'transcribe') note = ((s.total || 0) > 0 ? t('timing.transcribeProcessed', { done: duration(s.processed || 0), total: duration(s.total || 0) }) : t('timing.transcribeWaiting'))
    + (s.remaining !== null ? t('timing.transcribeEta', { time: new Date(Date.now() + s.remaining).toLocaleTimeString(lang, { hour12: false }) }) : '')
    + t('timing.transcribeTail');
  else if (s.stage !== 'idle') note = t('timing.other');
  const steps: [string, boolean][] = [
    [t('step.upload'), false],
    [retiming ? t('step.subtitle') : t('step.book'), audioOnly],
    [t('step.transcribe'), false],
    [retiming ? t('step.retime') : t('step.align'), audioOnly],
    [t('step.done'), false],
  ];
  return <section aria-label={t('progress.section')}>
    <div className="flex flex-wrap justify-between items-baseline gap-x-4 gap-y-1">
      <h2 className="h-section">{t('progress.section')}</h2>
      <p className="h-sub" id="phaseTitle">{phaseName(t, s.stage)}</p>
    </div>
    {batch ? <p className="note mt-1" id="runLabel">{batch.count > 1 ? t('progress.batch', { name: batch.name, index: batch.index, count: batch.count, elapsed: duration((batch.end ?? performance.now()) - batch.start) }) : batch.name}</p> : null}
    <ol className="steps" aria-label={t('progress.stages')}>{steps.map(([label, skipped], i) => <li key={label + i} className={cn(i === step && 'current', i < step && 'finished', skipped && 'skipped')}>{label}</li>)}</ol>
    <div className="flex items-center gap-4"><Progress id="bar" aria-label={t('progress.bar')} value={s.fraction !== null ? s.fraction * 100 : ['idle', 'error', 'cancelled'].includes(s.stage) ? 0 : null} /><span id="percent" className="note min-w-10 shrink-0 whitespace-nowrap text-end tabular-nums">{s.fraction !== null ? (s.fraction * 100).toFixed(0) + '%' : s.stage === 'idle' ? '0%' : '—'}</span></div>
    <dl className="grid grid-cols-2 sm:grid-cols-4 gap-5 mt-6">
      {[
        [t('metric.elapsed'), duration(s.elapsed), 'elapsed'],
        [['complete', 'error', 'cancelled'].includes(s.stage) ? t('metric.stageFinal') : t('metric.stage'), duration(s.stageElapsed), 'stageElapsed'],
        [s.stage === 'transcribe' ? t('metric.remainingTranscribe') : t('metric.remaining'), remaining, 'remaining'],
        [s.stage === 'complete' ? t('metric.speedAverage') : t('metric.speed'), s.speed !== null && Number.isFinite(s.speed) ? s.speed.toFixed(1) + '×' : '—', 'speed'],
      ].map(([label, value, id]) => <div key={id}><dt className="note">{label}</dt><dd className="metric-value" id={id}>{value}</dd></div>)}
    </dl>
    <p className="note mt-4" id="timingNote">{note}</p>
  </section>;
}
