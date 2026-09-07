#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/env.sh"
cd "$ROOT_DIR"
if [[ $# -eq 0 ]]; then
  echo "usage: $0 <audio-file> [--offset 120] [--durations 60 300] [--runs 3]" >&2
  exit 64
fi
mkdir -p build
dart pub get
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 tool/apple_transcribe.swift -o build/apple_transcribe
dart compile exe tool/reazon_benchmark.dart -o build/reazon_benchmark
echo "Preparing Japanese models (outside timing)..."
build/apple_transcribe --install
dart run packages/asr_cli/bin/asr.dart models pull -l ja --variant int8
if [[ " $* " == *" coreml "* ]]; then
  dart run packages/asr_cli/bin/asr.dart models pull -l ja --variant fp32
fi
python3 tool/benchmark_macos.py "$@"
