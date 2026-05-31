#!/usr/bin/env bash
# Superconnect host supervisor: keeps a `--produce` host running, auto-reconnecting
# through USB/TCP blips. Re-establishes the `hdc fport` tunnel each cycle (any USB
# reconnect/reboot clears it). Ctrl-C to stop. Logs to /tmp/sc-host.log.
#
#   tools/sc-loop.sh
#   HDC=/path/to/hdc PORT=8888 tools/sc-loop.sh   # explicit hdc / port
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_common.sh"            # exports $HDC and $PORT (with sensible discovery)
MAC_DIR="$(cd "$HERE/../mac" && pwd)"
LOG="${SC_LOG:-/tmp/sc-host.log}"

cd "$MAC_DIR"
# Resolve the built host binary (debug by default; override with SC_BIN).
BIN="${SC_BIN:-$MAC_DIR/.build/$(uname -m)-apple-macosx/debug/superconnect-mac}"
if [[ ! -x "$BIN" ]]; then
  echo "host binary not found at $BIN — run 'cd mac && swift build' first" >&2
  exit 1
fi

echo "[loop] supervising $BIN (port $PORT) — logging to $LOG"
while true; do
  "$HDC" fport "tcp:$PORT" "tcp:$PORT" >> "$LOG" 2>&1 || true
  echo "[loop] $(date +%H:%M:%S) launching host" >> "$LOG"
  "$BIN" --produce >> "$LOG" 2>&1 || true
  echo "[loop] host exited, reconnecting in 2s" >> "$LOG"
  sleep 2
done
