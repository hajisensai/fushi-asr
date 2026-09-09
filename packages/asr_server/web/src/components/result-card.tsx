import { memo } from 'react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { download } from '@/lib/api';
import { useT } from '@/lib/i18n-react';
import { resultEngineLabel } from '@/lib/engine-label';
import type { SavedResult } from '@/lib/types';
export const ResultCard = memo(function ResultCard({ saved }: { saved: SavedResult }) {
  const t = useT();
  const { result: r, file, book, subtitle, wallMs } = saved, a = r.alignment, m = r.retiming;
  const seconds = (ms: number) => (ms / 1000).toFixed(2);
  function downloadOriginal() {
    if (!subtitle) return;
    const url = URL.createObjectURL(subtitle), anchor = document.createElement('a');
    anchor.href = url; anchor.download = subtitle.name; document.body.append(anchor); anchor.click(); anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  const format = r.format.toUpperCase();
  return <section className="result panel min-w-0 scroll-mt-20" id={`result-${saved.id}`}>
    <h3 className="font-semibold">{resultEngineLabel(r)}{m ? t('result.retimeSuffix') : ''}</h3>
    <p className="note mt-1 break-all">{file.name}{subtitle ? ' ＋ ' + subtitle.name : book ? ' ＋ ' + book.name : t('result.audioOnly')}</p>
    <dl className="flex flex-wrap gap-x-6 gap-y-3 my-4">
      {[
        [t('result.metric.total'), t('result.seconds', { value: seconds(r.elapsedMs) })],
        [t('metric.speedAverage'), r.transcribeMs > 0 ? (r.audioMs / r.transcribeMs).toFixed(1) + '×' : '—'],
        [t('result.metric.cues'), r.cueCount],
      ].map(([label, value]) => <div key={label}><dt className="note">{label}</dt><dd className="text-xl font-medium tabular-nums">{value}</dd></div>)}
    </dl>
    <p className="note mb-3">{m
      ? t('result.breakdownRetime', { transcribe: seconds(r.transcribeMs), retime: seconds(m.elapsedMs) })
      : a
        ? t('result.breakdownAlign', { transcribe: seconds(r.transcribeMs), book: seconds(r.bookReadMs), align: seconds(a.elapsedMs) })
        : t('result.breakdown', { transcribe: seconds(r.transcribeMs) })}</p>
    {m ? <>
      <p className="mb-2">{t('retime.calibrated', { changed: m.inputCues - m.unchangedCues, total: m.inputCues })}{m.clock ? t('retime.clock', { count: m.clock.acceptedCueCount }) : ''}</p>
      <p className="note mb-2">{t('retime.counts', { matched: m.matchedCues, interpolated: m.interpolatedCues, unchanged: m.unchangedCues })}</p>
      <p className="note mb-3">{t('retime.shift', { shift: (m.medianShiftMs > 0 ? '+' : '') + (m.medianShiftMs / 1000).toFixed(2) })}</p>
      {m.warnings.length ? <Alert className="mb-4"><AlertTitle>{t('retime.reviewTitle')}</AlertTitle><AlertDescription>{m.warnings.map((warning, i) => <p key={i}>{warning}</p>)}</AlertDescription></Alert> : null}
    </> : null}
    {a ? <>
      <p className="alignment note mb-2">{t('align.summary', { matched: a.matchedCues, total: a.inputCues, rate: (a.matchRate * 100).toFixed(1), unmatched: a.unmatchedCues, added: a.boundariesAdded, removed: a.boundariesRemoved })}</p>
      <p className="note mb-3">{t('align.note', { warnings: a.warnings.join(' ') })}</p>
    </> : null}
    <Textarea readOnly spellCheck={false} value={r.text} aria-label={t('result.subtitleLabel', { engine: resultEngineLabel(r) })} className="min-h-60" />
    <div className="flex flex-wrap gap-2 mt-3">
      <Button variant="outline" size="sm" onClick={() => download(r, file)}>{m ? t('result.downloadRetimed', { format }) : a ? t('result.downloadAligned', { format }) : t('result.download', { format })}</Button>
      {r.rawText !== undefined ? <Button variant="outline" size="sm" onClick={() => download(r, file, true)}>{t('result.downloadRaw')}</Button> : null}
      {subtitle ? <Button variant="outline" size="sm" onClick={downloadOriginal}>{t('result.downloadOriginal')}</Button> : null}
    </div>
    <p className="note mt-3">{t('result.footer', { duration: FushiProgress.duration(r.audioMs), wall: seconds(wallMs), provider: r.provider })}{r.fellBack ? t('result.fellBack') : ''}</p>
  </section>;
});
