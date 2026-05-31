#!/usr/bin/env bash
# One-shot wired bring-up:
#   1. check device   2. set up hdc fport   3. run the Mac host.
# Default runs the PRODUCER (--produce: extended display → capture → encode →
# stream + receive input). Pass 'ping' to just test connectivity/handshake.
# Prereq: the HarmonyOS app is installed & running on the tablet
# (status: listening 127.0.0.1:$PORT). See docs/ONDEVICE.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
# shellcheck source=_common.sh
source "$DIR/_common.sh"

MODE="${1:-produce}"

echo "==> 1/3 device"
"$HDC" list targets

echo "==> 2/3 fport tcp:$PORT"
"$HDC" fport "tcp:$PORT" "tcp:$PORT" || true
"$HDC" fport ls

if [[ "$MODE" == "ping" ]]; then
  echo "==> 3/3 mac client (ping)"
  swift run --package-path "$REPO/mac" superconnect-mac --host 127.0.0.1 --port "$PORT"
else
  echo "==> 3/3 mac host (produce) — needs Screen Recording + Accessibility (tools/grant-permissions.sh)"
  swift run --package-path "$REPO/mac" superconnect-mac --produce --host 127.0.0.1 --port "$PORT"
fi

