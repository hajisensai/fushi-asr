#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT_DIR/build/asr"
PID_FILE="$ROOT_DIR/build/asr-server.pid"
LOG_FILE="$ROOT_DIR/build/asr-server.log"

source "$ROOT_DIR/script/env.sh"
cd "$ROOT_DIR"

stop_existing_server() {
  if [[ -f "$PID_FILE" ]]; then
    local pid command_line
    pid="$(cat "$PID_FILE")"
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == "$APP_BINARY serve"* ]]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

start_background_server() {
  "$APP_BINARY" serve >"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
}

start_detached_server() {
  nohup "$APP_BINARY" serve </dev/null >"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
}

stop_existing_server
dart pub get
mkdir -p "$ROOT_DIR/build"
dart compile exe packages/asr_cli/bin/asr.dart -o "$APP_BINARY"
if [[ "$(uname -s)" == Darwin ]] && [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]]; then
  xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos26.0" \
    tool/apple_transcribe.swift -o "$ASR_APPLE_TRANSCRIBE"
  "$ASR_APPLE_TRANSCRIBE" --install
fi

case "$MODE" in
  run)
    echo "$$" >"$PID_FILE"
    exec "$APP_BINARY" serve
    ;;
  --debug|debug)
    exec lldb -- "$APP_BINARY" serve
    ;;
  --logs|logs)
    start_background_server
    exec tail -f "$LOG_FILE"
    ;;
  --telemetry|telemetry)
    ASR_TRACE_SHUTDOWN=1 "$APP_BINARY" serve >"$LOG_FILE" 2>&1 &
    echo "$!" >"$PID_FILE"
    exec tail -f "$LOG_FILE"
    ;;
  --verify|verify)
    start_detached_server
    for _ in {1..30}; do
      if curl --fail --silent http://127.0.0.1:8642/v1/health >/dev/null; then
        echo "ASR server is healthy at http://127.0.0.1:8642"
        exit 0
      fi
      sleep 0.2
    done
    echo "ASR server did not become healthy. See $LOG_FILE" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
