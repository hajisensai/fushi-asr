// Pure, monotonic-clock model: no synthetic progress and no learning across engines.
(function (root) {
  'use strict';
  const duration = ms => {
    if (!Number.isFinite(ms) || ms < 0) return '—';
    const seconds = Math.floor(ms / 1000);
    const pad = n => String(n).padStart(2, '0');
    return seconds >= 3600
      ? `${pad(Math.floor(seconds / 3600))}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`
      : `${pad(Math.floor(seconds / 60))}:${pad(seconds % 60)}`;
  };
  class ProgressClock {
    constructor(now = () => performance.now()) { this.now = now; this.reset(); }
    reset() {
      this.start = null; this.stageStart = null; this.stage = 'idle';
      this.asrStart = null; this.asrElapsed = 0; this.processed = 0; this.total = 0;
      this.lastProgressAt = null; this.finish = null; this.result = null;
    }
    begin() { this.reset(); this.start = this.now(); this.stageStart = this.start; this.stage = 'upload'; }
    event(ev) {
      if (this.finish !== null) return;
      const now = this.now();
      // Backend 'done' means ASR has ended, not that EPUB alignment has ended.
      const stage = ev.phase === 'done' ? 'finalize' : ev.phase;
      if (stage !== this.stage) {
        if (this.stage === 'transcribe') this.asrElapsed += now - this.asrStart;
        this.stage = stage; this.stageStart = now;
        if (stage === 'transcribe') this.asrStart = now;
      }
      if (stage === 'transcribe' && Number.isFinite(ev.totalMs) && ev.totalMs > 0) {
        this.total = ev.totalMs;
        const value = Math.min(this.total, Math.max(0, ev.processedMs || 0));
        if (value > this.processed) { this.processed = value; this.lastProgressAt = now; }
      }
    }
    end(result = null) {
      if (this.finish !== null) return;
      this.finish = this.now(); this.result = result;
      if (this.stage === 'transcribe') this.asrElapsed += this.finish - this.asrStart;
      this.stage = result ? 'complete' : 'error';
    }
    cancel() { this.end(); this.stage = 'cancelled'; }
    snapshot() {
      if (this.start === null) return { elapsed: 0, stageElapsed: 0, speed: null, remaining: null, fraction: null, stage: 'idle' };
      const now = this.finish ?? this.now();
      const asrMs = this.asrElapsed + (this.stage === 'transcribe' ? now - this.asrStart : 0);
      const speed = this.result
        ? (this.result.transcribeMs > 0 ? this.result.audioMs / this.result.transcribeMs : null)
        : (asrMs >= 500 && this.processed > 0 ? this.processed / asrMs : null);
      // ETA covers ASR only. Unknown upload/load/alignment durations are never guessed.
      // A stalled stream invalidates ETA rather than counting down to a fake completion.
      const fresh = this.lastProgressAt !== null && now - this.lastProgressAt < 30000;
      const remaining = this.stage === 'transcribe' && asrMs >= 1000 && speed > 0 && fresh && this.processed < this.total
        ? (this.total - this.processed) / speed : null;
      return {
        elapsed: now - this.start, stageElapsed: now - this.stageStart,
        speed, remaining, stage: this.stage,
        fraction: this.result ? 1 : this.stage === 'transcribe' && this.total > 0 ? this.processed / this.total : null,
        processed: this.result?.audioMs ?? this.processed, total: this.result?.audioMs ?? this.total,
      };
    }
  }
  root.FushiProgress = { ProgressClock, duration };
  if (typeof module !== 'undefined') module.exports = root.FushiProgress;
})(globalThis);
