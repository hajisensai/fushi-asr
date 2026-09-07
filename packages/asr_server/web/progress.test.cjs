const { test } = require('node:test');
const assert = require('node:assert/strict');
const { ProgressClock, duration } = require('./progress.js');
test('stopping hides ETA and cancellation freezes time without reporting completion', () => {
  let now = 0; const clock = new ProgressClock(() => now); clock.begin();
  clock.event({ phase: 'transcribe', processedMs: 10000, totalMs: 60000 });
  now = 1000; clock.event({ phase: 'stopping' });
  assert.equal(clock.snapshot().remaining, null);
  now = 2000; clock.cancel(); now = 5000;
  assert.equal(clock.snapshot().elapsed, 2000);
  assert.equal(clock.snapshot().stage, 'cancelled');
  assert.equal(clock.snapshot().fraction, null);
});
test('elapsed ticks while upload or loading has no events; ETA is unknown', () => {
  let now = 0; const c = new ProgressClock(() => now); c.begin(); now = 5000;
  assert.equal(c.snapshot().elapsed, 5000); assert.equal(c.snapshot().remaining, null);
  c.event({ phase: 'load' }); now = 7000;
  assert.equal(c.snapshot().stageElapsed, 2000); assert.equal(c.snapshot().elapsed, 7000);
});
test('speed and ASR ETA use real audio progress, excluding load and alignment', () => {
  let now = 0; const c = new ProgressClock(() => now); c.begin(); now = 15000;
  c.event({ phase: 'transcribe' }); now = 20000;
  c.event({ phase: 'transcribe', processedMs: 30000, totalMs: 60000 });
  assert.equal(c.snapshot().speed, 6); assert.equal(c.snapshot().remaining, 5000);
  c.event({ phase: 'align' }); now = 21000;
  assert.equal(c.snapshot().remaining, null); assert.equal(c.snapshot().speed, 6);
});
test('stalled streams invalidate ETA; progress never invents completion', () => {
  let now = 0; const c = new ProgressClock(() => now); c.begin(); c.event({ phase: 'transcribe' });
  now = 2000; c.event({ phase: 'transcribe', processedMs: 30000, totalMs: 60000 });
  now = 35000; assert.equal(c.snapshot().remaining, null); assert.equal(c.snapshot().fraction, .5);
});
test('completion freezes clocks and reports server measured speed; new engine resets', () => {
  let now = 0; const c = new ProgressClock(() => now); c.begin(); now = 2500;
  c.end({ audioMs: 60000, transcribeMs: 2000 }); now = 10000;
  assert.equal(c.snapshot().elapsed, 2500); assert.equal(c.snapshot().speed, 30);
  c.begin(); assert.equal(c.snapshot().elapsed, 0); assert.equal(c.snapshot().speed, null);
});
test('failure freezes and never reports success', () => {
  let now = 0; const c = new ProgressClock(() => now); c.begin(); now = 1300; c.end(); now = 5000;
  assert.equal(c.snapshot().stage, 'error'); assert.equal(c.snapshot().fraction, null);
  assert.equal(c.snapshot().elapsed, 1300);
});
test('long durations have unbounded hours and do not wrap', () => {
  assert.equal(duration(65000), '01:05'); assert.equal(duration(90061000), '25:01:01');
  assert.equal(duration(null), '—');
});
