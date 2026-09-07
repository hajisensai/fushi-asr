# Local UI development

This is a React 19 + shadcn/ui (Radix Nova) + Tailwind CSS 4 UI inspired by
OpenWebUI's layout, not an OpenWebUI server integration. Components are installed
from the official shadcn registry and owned in `src/components/ui`. The existing
Dart ASR/EPUB backend is retained, with per-task cancellation added. The production bundle includes React and all
UI code: no Python service, remote fonts, CDN, or external UI requests.

With Node.js 24+ (tests use native TypeScript stripping):

```sh
cd packages/asr_server/web
npm ci
npm test
npm run typecheck
npm run build
```

Then run `./script/build_and_run.sh` from the repository root. The Run action
builds the Dart/Swift server with the checked-in `lib/src/web_ui.g.dart` bundle.
Rebuild that bundle after editing `index.html`, `styles.css`, `src/`, or
`progress.js`. Commit source and generated bundle together. Node and Tailwind
are development-only dependencies; Windows builds can use the same bundle.

`npm run dev` runs the Vite frontend with `/v1` proxied to the Dart server at
127.0.0.1:8642. Use `npx shadcn@latest add <component>` for more components.
The generated Progress component forwards `value` to the Radix root (ARIA fix).

Both file controls are drag-and-drop zones. They support click/keyboard file
selection through hidden inputs, replacement, and removal. Wrong type, empty,
oversized, or multiple files are rejected without replacing a valid selection.
Inputs are disabled while processing; EPUB is also disabled in audio-only mode.
The sidebar switches between subtitle generation and subtitle retiming. On narrow
screens the top-bar navigation button opens a Sheet. File selections and previous
results survive mode changes; navigation is locked while a task is running.
New task and theme controls live in the top bar.

Retiming accepts an existing UTF-8 SRT/WebVTT file (up to 8 MiB) plus audio/video,
and submits `subtitle` + `audio` multipart to `/v1/retime`. The original subtitle
text, line breaks and cue count are retained; WebVTT layout/style settings are
not retained. Result cards distinguish matched, estimated and unchanged cues,
show review warnings, and download corrected subtitles, the original uploaded
subtitle file, or the ASR transcript. Matching expects the same spoken language;
it is based on ASR text/timestamps and is not phoneme forced alignment.
Japanese broadcast speaker/effect labels are excluded from matching only.
Independent speech boundaries can estimate a local subtitle clock when ASR
merges several original captions. Result cards show calibrated cue coverage
separately from whole-cue matching and estimated timing counts.

## Stopping a task

`TranscriptionTask` reserves a server job ID before uploading. Stop aborts the
upload/response and sends an authenticated cancellation request; the UI stays
busy until the server acknowledges resource cleanup. Failed stop requests can
be retried without unlocking controls or falsely reporting success. Cancellation
also prevents starting the next comparison engine and preserves prior results.
Reazon waits for native loading / an in-flight inference batch to return safely.
Pure Dart book work and Apple's task-local helper processes are also cancellable.

On macOS the default is the original INT8 CPU path. Comparison pairs Apple with
that path, or with CoreML when CoreML is selected. The pair is labelled beside
the button; no backend is silently relabelled as CoreML.

## Timing semantics

- **已用时间**: monotonic client wall time for the current engine, including
  upload, queue, book parsing, model preparation, transcription, and alignment.
- **当前阶段用时**: resets only when the stage changes; ticks without new events.
- **转录预计剩余**: processed audio / ASR wall time extrapolation. It excludes
  future alignment. It is unknown before real progress, during other stages,
  for a stalled stream (>30 seconds), or during finishing. No fake countdown.
- **转录倍速**: live processed audio duration / active ASR wall time. Apple sends
  finalized segment times; Reazon reports chunk progress (the first chunk may
  take a while). These are estimates, not a model benchmark.
- **转录平均倍速**: final audio duration / server `transcribeMs`, including model
  download/load/decoding in that stage. Result cards also show total pipeline,
  book parse, transcription, and alignment durations separately.
- Comparison is serial. Clocks reset for each engine; comparison total wall
  time is shown separately. Completion/error/cancellation freezes clocks. Page refresh loses
  in-memory results; download anything you want to keep.

Source references: [Tailwind CLI](https://tailwindcss.com/docs/installation/tailwind-cli),
[OpenWebUI](https://github.com/open-webui/open-webui). No OpenWebUI source copied.
