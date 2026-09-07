export type Backend = { id: string; name: string; description: string; available: boolean; languages: string[]; unavailableReason?: string };
export type Language = { tag: string; nativeName: string };
export type Format = 'srt' | 'vtt' | 'json';
export type WorkspaceMode = 'generate' | 'retime';
export type ProgressEvent = { phase: string; processedMs?: number; totalMs?: number; detail?: string; error?: string };
export type Alignment = { matchedCues: number; inputCues: number; matchRate: number; unmatchedCues: number; boundariesAdded: number; boundariesRemoved: number; elapsedMs: number; warnings: string[] };
export type Retiming = { inputCues: number; matchedCues: number; interpolatedCues: number; unchangedCues: number; matchRate: number; medianShiftMs: number; elapsedMs: number; warnings: string[]; clock?: { acceptedCueCount: number; rejectedCueCount: number; regionCount: number } };
export type Result = ProgressEvent & { engine: string; engineName: string; audioMs: number; transcribeMs: number; bookReadMs: number; subtitleReadMs?: number; elapsedMs: number; cueCount: number; format: Format; text: string; rawText?: string; provider: string; fellBack?: boolean; alignment?: Alignment; retiming?: Retiming };
export type SavedResult = { id: number; result: Result; file: File; book: File | null; subtitle?: File | null; wallMs: number };
export type ClockSnapshot = { elapsed: number; stageElapsed: number; speed: number | null; remaining: number | null; fraction: number | null; stage: string; processed?: number; total?: number };
export interface Clock { begin(): void; reset(): void; event(event: ProgressEvent): void; end(result?: Result): void; cancel(): void; snapshot(): ClockSnapshot; }
declare global {
  var FushiProgress: { ProgressClock: new () => Clock; duration: (ms: number | null) => string };
}
