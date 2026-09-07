# macOS development

日语实际有声书的 Apple SpeechTranscriber / ReazonSpeech 速度对比及复现方法：
[MACOS_ASR_BENCHMARK.md](MACOS_ASR_BENCHMARK.md)。
CoreML 的显式启用方式及实测结果见 [MACOS_COREML.md](MACOS_COREML.md)。

The repository currently provides a Dart CLI and HTTP server, not a native
macOS application. The Dart core is intentionally independent of Flutter and
FFI; the ONNX implementation is injected through `OnnxSessionFactory`. This is
a useful boundary for a future macOS host.

## Local setup (Apple Silicon)

```bash
./script/bootstrap_macos.sh
source ./script/env.sh
./script/check.sh
```

The bootstrap installs Homebrew's FFmpeg and ONNX Runtime bottles when needed,
and downloads a checksum-pinned Dart SDK into `.tools/dart-sdk`. Keeping Dart
project-local avoids depending on the host's global SDK version.

To build the CLI and start the local web UI:

```bash
./script/build_and_run.sh
```

The service listens at <http://127.0.0.1:8642>. Use `--verify` for a background
launch plus health check, `--logs` to follow its log, or `--debug` for LLDB.

## Current native dependencies

- Dart SDK 3.6 or newer (the bootstrap pins 3.13.3)
- FFmpeg and optional FFprobe
- ONNX Runtime 1.22 or newer; `script/env.sh` exports the Homebrew dylib path
- Xcode/Command Line Tools matching the installed macOS SDK for a future app

On the current macOS 27 development host, Command Line Tools 27 are installed,
but the full Xcode application is 26.6. Upgrade full Xcode to 27 before adding
or building an AppKit/SwiftUI application target.

## Recommended adaptation boundary

1. Keep transcription, model management, alignment, and subtitle formatting in
   the existing Dart packages.
2. Add a macOS host as a separate package/application instead of importing UI
   concerns into `asr_core`.
3. For a Flutter macOS host, inject the platform ONNX backend through the
   existing `OnnxSessionFactory` interface and bundle both ONNX Runtime and
   FFmpeg in the application.
4. Add microphone/file permissions, sandbox entitlements, signing, and
   notarization only in the host target.
5. Validate both `arm64` and `x86_64` artifacts before shipping a universal app.
