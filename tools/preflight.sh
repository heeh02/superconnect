#!/usr/bin/env bash
# Preflight for the wired on-device test. Soft-checks every prerequisite and
# prints a PASS/WARN summary instead of failing on the first problem.
#   PORT=8888 tools/preflight.sh
set -uo pipefail
PORT="${PORT:-8888}"
ok()   { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
warn() { printf "  \033[33mWARN\033[0m %s\n" "$1"; }

echo "== Superconnect on-device preflight (port $PORT) =="

# 1) hdc present?
HDC=""
if [[ -n "${HDC_BIN:-}" && -x "${HDC_BIN}" ]]; then HDC="$HDC_BIN"
elif command -v hdc >/dev/null 2>&1; then HDC="$(command -v hdc)"
else
  for c in "$HOME/command-line-tools/sdk/default/openharmony/toolchains/hdc" \
           "$HOME/Library/Huawei/Sdk"/*/openharmony/toolchains/hdc \
           "$HOME/Library/OpenHarmony/Sdk"/*/toolchains/hdc \
           "/Applications/DevEco-Studio.app/Contents/sdk"/*/openharmony/toolchains/hdc; do
    [[ -x "$c" ]] && { HDC="$c"; break; }
  done
fi
if [[ -n "$HDC" ]]; then ok "hdc: $HDC"; else
  warn "hdc not found — install HarmonyOS Command Line Tools / DevEco and add toolchains/ to PATH (or set HDC_BIN)."
fi

# 2) device connected + authorized?
if [[ -n "$HDC" ]]; then
  TARGETS="$("$HDC" list targets 2>/dev/null || true)"
  if [[ -n "$TARGETS" && "$TARGETS" != *"Empty"* && "$TARGETS" != *"[empty]"* ]]; then
    ok "device(s): $(echo "$TARGETS" | tr '\n' ' ')"
  else
    warn "no device from 'hdc list targets' — enable Developer Mode + USB debugging on the tablet, replug USB, accept the on-device authorization."
  fi

  # 3) fport mapping?
  if "$HDC" fport ls 2>/dev/null | grep -q "tcp:$PORT"; then
    ok "fport tcp:$PORT already mapped"
  else
    warn "fport not set — run: tools/fport.sh   (hdc fport tcp:$PORT tcp:$PORT)"
  fi
fi

# 4) Swift toolchain?
if command -v swift >/dev/null 2>&1; then ok "swift: $(swift --version 2>/dev/null | head -1)"; else warn "swift not found (need Xcode CLT to run the host)."; fi

# 5) Permissions (cannot read TCC reliably; remind).
warn "verify macOS permissions for your terminal: Screen Recording + Accessibility (run tools/grant-permissions.sh)."

cat <<EOF

Next:
  1. Tablet: build & Run the app in DevEco (status shows 'listening 127.0.0.1:$PORT').
  2. Mac:    tools/fport.sh && swift run --package-path mac superconnect-mac --produce
  (or simply: tools/dev-up.sh — but that runs ping mode; use --produce for video.)
EOF
