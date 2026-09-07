#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DART_VERSION="3.13.3"
DART_SHA256="c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc"
DART_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/$DART_VERSION/sdk/dartsdk-macos-arm64-release.zip"
DART_SDK="$ROOT_DIR/.tools/dart-sdk"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This bootstrap currently supports Apple Silicon macOS only." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi

if ! brew list --versions ffmpeg >/dev/null 2>&1; then
  brew install --force-bottle ffmpeg
fi
if ! brew list --versions onnxruntime >/dev/null 2>&1; then
  brew install --force-bottle onnxruntime
fi

if [[ ! -x "$DART_SDK/bin/dart" ]]; then
  SDK_TMP="$(mktemp -d)"
  trap 'rm -rf "$SDK_TMP"' EXIT
  curl -fL "$DART_URL" -o "$SDK_TMP/dart.zip"
  printf '%s  %s\n' "$DART_SHA256" "$SDK_TMP/dart.zip" | shasum -a 256 -c -
  mkdir -p "$ROOT_DIR/.tools"
  unzip -q "$SDK_TMP/dart.zip" -d "$ROOT_DIR/.tools"
fi

source "$ROOT_DIR/script/env.sh"
cd "$ROOT_DIR"
dart pub get
dart run tool/ort_smoke.dart

echo "macOS development environment is ready."
echo "Run: source ./script/env.sh"
