#!/usr/bin/env bash

# Source this file from the repository root to use the project-local toolchain.
ASR_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASR_DART_SDK="$ASR_PROJECT_ROOT/.tools/dart-sdk"

if [[ -x "$ASR_DART_SDK/bin/dart" ]]; then
  export PATH="$ASR_DART_SDK/bin:$PATH"
elif ! command -v dart >/dev/null 2>&1; then
  echo "Dart SDK not found. Run ./script/bootstrap_macos.sh first." >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "${ASR_ONNXRUNTIME_LIB:-}" ]] && command -v brew >/dev/null 2>&1; then
  ASR_ORT_PREFIX="$(brew --prefix onnxruntime 2>/dev/null || true)"
  if [[ -n "$ASR_ORT_PREFIX" && -f "$ASR_ORT_PREFIX/lib/libonnxruntime.dylib" ]]; then
    export ASR_ONNXRUNTIME_LIB="$ASR_ORT_PREFIX/lib/libonnxruntime.dylib"
  fi
fi

if [[ -z "${ASR_FFMPEG:-}" ]] && command -v ffmpeg >/dev/null 2>&1; then
  export ASR_FFMPEG="$(command -v ffmpeg)"
fi

unset ASR_ORT_PREFIX

export ASR_APPLE_TRANSCRIBE="${ASR_APPLE_TRANSCRIBE:-$ASR_PROJECT_ROOT/build/apple_transcribe}"
