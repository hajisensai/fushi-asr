import { useEffect, useState } from 'react';
import { Progress } from '@/components/ui/progress';
import { cn } from '@/lib/utils';
import type { Clock } from '@/lib/types';
export const phaseNames: Record<string, string> = { idle: '准备就绪', upload: '上传文件', queued: '等待任务队列', book: '解析 EPUB 正文', subtitle: '解析已有字幕', download: '下载模型', load: '加载模型 / 解码音频', transcribe: '转录中', finalize: '整理转录结果', align: '正文对齐', retime: '校准字幕时间轴', complete: '处理完成', error: '处理失败', stopping: '正在终止任务', cancelled: '任务已终止' };
export type Batch = { name: string; index: number; count: number; start: number; end?: number };
export function ProgressPanel({ clock, busy, batch, audioOnly, retiming = false }: { clock: Clock; busy: boolean; batch: Batch | null; audioOnly: boolean; retiming?: boolean }) {
  const [, tick] = useState(0);
  // Keep the high-frequency clock local: large subtitle previews never rerender.
  useEffect(() => { if (!busy) return; const t = setInterval(() => tick(n => n + 1), 250); return () => clearInterval(t); }, [busy]);
  const s = clock.snapshot(), { duration } = FushiProgress;
  const remaining = s.stage === 'complete' ? '已完成' : ['error', 'cancelled'].includes(s.stage) ? '已停止' : s.stage === 'stopping' ? '停止中' : s.remaining !== null ? '约 ' + duration(Math.max(1000, s.remaining)) : s.stage === 'transcribe' && (s.total || 0) > 0 && (s.processed || 0) >= (s.total || 0) ? '收尾中' : s.stage === 'idle' ? '—' : '估算中';
  const step = ({ upload: 0, queued: 0, book: 1, subtitle: 1, download: 2, load: 2, transcribe: 2, finalize: 2, align: 3, retime: 3, complete: 4 } as Record<string, number>)[s.stage] ?? -1;
  let note = '开始后显示实时进度，剩余时间根据实际转录进度估算。';
  if (s.stage === 'complete') note = '已用时间含上传与排队；平均倍速 = 音频时长 ÷ 转录用时（含模型准备）。阶段明细见结果。';
  else if (s.stage === 'error') note = '计时已停止。本次未生成完整结果，可检查错误后重试。';
  else if (s.stage === 'cancelled') note = '后端已停止，计时已冻结；已完成的字幕仍可下载。';
  else if (s.stage === 'stopping') note = '正在释放资源。Reazon 会完成当前推理批次后停止；不会继续下一方案。';
  else if (s.stage === 'transcribe') note = ((s.total || 0) > 0 ? `已处理音频 ${duration(s.processed || 0)} / ${duration(s.total || 0)}` : '正在等待首批转录进度') + (s.remaining !== null ? ' · 预计 ' + new Date(Date.now() + s.remaining).toLocaleTimeString('zh-CN', { hour12: false }) + ' 结束转录' : '') + '。估计不含后续对齐；倍速按已处理音频 / 转录时间计算。';
  else if (s.stage !== 'idle') note = '已用时间包含上传与排队；此阶段暂无可靠剩余时间，不计入转录倍速。';
  return <section aria-label="处理进度">
    <div className="flex flex-wrap justify-between items-center gap-2"><h2 className="section-title" id="phaseTitle">{phaseNames[s.stage] || s.stage}</h2><span className="note" id="runLabel">{batch ? batch.name + (batch.count > 1 ? ` · ${batch.index}/${batch.count} · 比较总用时 ${duration((batch.end ?? performance.now()) - batch.start)}` : '') : ''}</span></div>
    <ol className="steps" aria-label="处理阶段">{['上传', retiming ? '解析字幕' : '解析正文', '转录', retiming ? '对轴' : '对齐', '完成'].map((label, i) => <li key={label} className={cn(i === step && 'current', i < step && 'finished', audioOnly && [1, 3].includes(i) && 'skipped')}>{label}</li>)}</ol>
    <div className="flex items-center gap-4"><Progress id="bar" aria-label="当前阶段进度" value={s.fraction !== null ? s.fraction * 100 : ['idle', 'error', 'cancelled'].includes(s.stage) ? 0 : null} /><span id="percent" className="note min-w-10 shrink-0 whitespace-nowrap text-right tabular-nums">{s.fraction !== null ? (s.fraction * 100).toFixed(0) + '%' : s.stage === 'idle' ? '0%' : '—'}</span></div>
    <dl className="grid grid-cols-2 sm:grid-cols-4 gap-5 mt-6">
      {[
        ['已用时间', duration(s.elapsed), 'elapsed'],
        [['complete', 'error', 'cancelled'].includes(s.stage) ? '末阶段用时' : '当前阶段用时', duration(s.stageElapsed), 'stageElapsed'],
        [s.stage === 'transcribe' ? '转录预计剩余' : '预计剩余', remaining, 'remaining'],
        [s.stage === 'complete' ? '转录平均倍速' : '转录倍速', s.speed !== null && Number.isFinite(s.speed) ? s.speed.toFixed(1) + '×' : '—', 'speed'],
      ].map(([label, value, id]) => <div key={id}><dt className="note">{label}</dt><dd className="metric-value" id={id}>{value}</dd></div>)}
    </dl>
    <p className="note mt-4" id="timingNote">{note}</p>
  </section>;
}
