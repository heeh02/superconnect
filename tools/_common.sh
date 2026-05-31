#!/usr/bin/env bash
# Common helpers for the Superconnect dev scripts.
# Locates `hdc` (HarmonyOS Device Connector) and exposes $HDC.
set -euo pipefail

# Allow override: HDC=/path/to/hdc tools/check-device.sh
if [[ -n "${HDC:-}" ]]; then
  :
elif command -v hdc >/dev/null 2>&1; then
  HDC="$(command -v hdc)"
else
  # Common DevEco Command Line Tools locations on macOS.
  for cand in \
    "$HOME/command-line-tools/sdk/default/openharmony/toolchains/hdc" \
    "$HOME/Library/Huawei/Sdk"/*/openharmony/toolchains/hdc \
    "$HOME/Library/OpenHarmony/Sdk"/*/toolchains/hdc \
    "/Applications/DevEco-Studio.app/Contents/sdk"/*/openharmony/toolchains/hdc ; do
    if [[ -x "$cand" ]]; then HDC="$cand"; break; fi
  done
fi

if [[ -z "${HDC:-}" || ! -x "${HDC}" ]]; then
  cat >&2 <<'EOF'
ERROR: `hdc` not found.

Install HarmonyOS "Command Line Tools" (ships with DevEco Studio) and either:
  • add its  .../openharmony/toolchains  dir to your PATH, or
  • run with an explicit path:  HDC=/path/to/hdc tools/<script>.sh

Download: https://developer.huawei.com/consumer/en/download/  (DevEco Studio / Command Line Tools)
EOF
  exit 127
fi

export HDC
PORT="${PORT:-8888}"
export PORT
