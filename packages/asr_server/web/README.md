# Local UI development

This is a React 19 + shadcn/ui (Radix Nova) + Tailwind CSS 4 UI. Components are
installed from the official shadcn registry and owned in `src/components/ui`. The
existing Dart ASR/EPUB backend is retained, with per-task cancellation added. The
production bundle includes React, the interface dictionaries and the logo: no
Python service, remote fonts, CDN, or external UI requests.

## Design source

The look comes from the Fushi website, `hajisensai/fushi.moe`. `styles.css` copies
that site's `public/chrome.css`: the same Apple-grammar tokens (`--ground`, `--ink`,
`--hairline`, `--link`, `--accent`), the same sticky blurred `.site-nav`, the same
pill `.btn`, `.site-nav-lang` menu, `.site-footer` and `.site-totop`, and the same
type scale. Those tokens are mapped onto the shadcn variable names, so registry
components inherit the site palette without being edited one by one. The markup
shapes live in `src/components/site-chrome.tsx`; when the website changes its
chrome, change both files. The workbench is not a page of that site — it runs on
the local server and ships as one offline HTML file — so the CSS is copied rather
than linked.

Three deliberate departures:

- The top bar carries the two working modes instead of the site's community links,
  and they are a segmented pill, not text links: this bar is the mode switch, so it
  has to read as "two choices, you are in one". Text links styled like the site's
  community entries got mistaken for decoration and the retiming mode went unfound.
  The pill is visible at every width - below 1000px it drops the labels and keeps
  the icons (the accessible name stays) instead of hiding behind a hamburger. It
  locks while a task runs.
- The dark toggle is kept, using the site's own dark-band tokens rather than a new
  set of greys.
- `scrollbar-gutter: stable` is deliberately *not* copied. The site needs it because
  its own scroll lock only sets `body { overflow: hidden }`; Radix, which powers the
  selects here, restores the width it takes away. Doing both compensates twice and
  the top bar's right edge jumps 15 px every time a dropdown opens.

## Interface language

17 languages, the same set and order as the website and the app. `src/lib/i18n.ts`
holds the store (`LANGS`, `matchTag`, `detect`, `initialLanguage`, `t`) and imports
nothing, so `node --test` can run it and everything downstream; `src/lib/i18n-react.ts`
is the React binding. `src/i18n/zh-CN.ts` is the source dictionary and its key set
*is* the `Dict` type, so a missing or stray key in any of the other 16 fails
`tsc`; `src/lib/i18n.test.ts` additionally checks that placeholders match and that
no translation is blank.

Dictionaries are bundled, not fetched: an offline single file may not download
anything at runtime. That also means there is no flash of the source language, so
the website's `i18n-pending` trick is unnecessary. Selection order follows the site:
`?lang=` → the remembered choice → `navigator.languages`, falling back to English.
The chosen language sets `<html lang>`/`dir` and the document title; Arabic renders
right-to-left. Any failure degrades to the source language, never to a blank page.

Status lines are stored as keys, not finished sentences, so switching language
re-renders them instead of leaving the previous language on screen. Error text that
embeds an exception message is translated when it is raised.

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
`progress.js`. Commit source and generated bundle together. `src/assets/fushi-icon.png`
is the site logo downscaled to 160 px and inlined as a data URI by esbuild; it is
both the brand mark and the tab icon, so no second request is made for either. Node and Tailwind
are development-only dependencies; Windows builds can use the same bundle.

`npm run dev` runs the Vite frontend with `/v1` proxied to the Dart server at
127.0.0.1:8642. Use `npx shadcn@latest add <component>` for more components.
The generated Progress component forwards `value` to the Radix root (ARIA fix).

Both file controls are drag-and-drop zones. They support click/keyboard file
selection through hidden inputs, replacement, and removal. Wrong type, empty,
oversized, or multiple files are rejected without replacing a valid selection.
Inputs are disabled while processing; EPUB is also disabled in audio-only mode.
The top bar's segmented control switches between subtitle generation and subtitle
retiming, at every screen width. File selections and previous results survive mode
changes; the switch is locked while a task is running. Language, theme and new task
live in the top bar.

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
[fushi.moe](https://github.com/hajisensai/fushi.moe) for the site chrome and the
language set.
