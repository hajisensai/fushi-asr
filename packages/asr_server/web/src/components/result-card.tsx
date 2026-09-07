import { memo } from 'react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Separator } from '@/components/ui/separator';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { download } from '@/lib/api';
import type { SavedResult } from '@/lib/types';
export const ResultCard = memo(function ResultCard({ saved }: { saved: SavedResult }) {
  const { result: r, file, book, subtitle, wallMs } = saved, a = r.alignment, t = r.retiming;
  function downloadOriginal() {
    if (!subtitle) return;
    const url = URL.createObjectURL(subtitle), anchor = document.createElement('a');
    anchor.href = url; anchor.download = subtitle.name; document.body.append(anchor); anchor.click(); anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  return <section className="result min-w-0 scroll-mt-20" id={`result-${saved.id}`}>
    <Separator className="mb-4" /><h3 className="font-semibold">{r.engineName}{t ? ' · 字幕对轴' : ''}</h3>
    <p className="note mt-1 break-all">{file.name}{subtitle ? ' ＋ ' + subtitle.name : book ? ' ＋ ' + book.name : '（仅音视频）'}</p>
    <dl className="flex flex-wrap gap-x-6 gap-y-3 my-4">
      {[['总处理用时', (r.elapsedMs / 1000).toFixed(2) + ' s'], ['转录平均倍速', r.transcribeMs > 0 ? (r.audioMs / r.transcribeMs).toFixed(1) + '×' : '—'], ['字幕条数', r.cueCount]].map(([label, value]) => <div key={label}><dt className="note">{label}</dt><dd className="text-xl font-medium tabular-nums">{value}</dd></div>)}
    </dl>
    <p className="note mb-3">转录 {(r.transcribeMs / 1000).toFixed(2)} 秒{t ? ` · 对轴 ${(t.elapsedMs / 1000).toFixed(2)} 秒` : a ? ` · 正文解析 ${(r.bookReadMs / 1000).toFixed(2)} 秒 · 对齐 ${(a.elapsedMs / 1000).toFixed(2)} 秒` : ''}</p>
    {t ? <><p className="mb-2">时间校准 {t.inputCues - t.unchangedCues}/{t.inputCues} 条{t.clock ? ` · 依据 ${t.clock.acceptedCueCount} 条对白的语音边界` : ''}</p><p className="note mb-2">整句匹配 {t.matchedCues} 条 · 估算 {t.interpolatedCues} 条 · 保留原轴 {t.unchangedCues} 条</p><p className="note mb-3">时间偏移中位数 {t.medianShiftMs > 0 ? '+' : ''}{(t.medianShiftMs / 1000).toFixed(2)} 秒（正值为延后） · 原字幕文字与条数已保留。校准条数不代表时间轴准确率。</p>{t.warnings.length ? <Alert className="mb-4"><AlertTitle>需要复核</AlertTitle><AlertDescription>{t.warnings.map((warning, i) => <p key={i}>{warning}</p>)}</AlertDescription></Alert> : null}</> : null}
    {a ? <><p className="alignment note mb-2">正文匹配 {a.matchedCues}/{a.inputCues}（{(a.matchRate * 100).toFixed(1)}%） · 未匹配 {a.unmatchedCues} 条保留原文 · 句界新增 {a.boundariesAdded} / 合并 {a.boundariesRemoved}</p><p className="note mb-3">匹配率不是准确率。{a.warnings.join(' ')}</p></> : null}
    <Textarea readOnly spellCheck={false} value={r.text} aria-label={`${r.engineName} 字幕`} className="min-h-60" />
    <div className="flex flex-wrap gap-2 mt-3"><Button variant="outline" size="sm" onClick={() => download(r, file)}>下载{t ? '对轴字幕 ' : a ? '对齐字幕 ' : ' '}{r.format.toUpperCase()}</Button>{r.rawText !== undefined ? <Button variant="outline" size="sm" onClick={() => download(r, file, true)}>下载原始转录</Button> : null}{subtitle ? <Button variant="outline" size="sm" onClick={downloadOriginal}>下载原字幕</Button> : null}</div>
    <p className="note mt-3">音频 {FushiProgress.duration(r.audioMs)} · 含上传/排队 {(wallMs / 1000).toFixed(2)} 秒 · {r.provider}{r.fellBack ? '（已回退 CPU）' : ''}</p>
  </section>;
});
