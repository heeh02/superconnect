#!/usr/bin/env bash
# Open the two macOS permission panes the host needs.
#   - Screen & System Audio Recording  (for ScreenCaptureKit capture)
#   - Accessibility                     (for CGEvent input injection)
# Grant them to the TERMINAL APP that launches `swift run superconnect-mac`,
# then restart that terminal so the grant takes effect.
set -euo pipefail

echo "Opening: Screen & System Audio Recording …"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
sleep 1
echo "Opening: Accessibility …"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true

cat <<'EOF'

Enable your terminal app (Terminal / iTerm / the app running Claude Code) in BOTH lists.
TCC attributes a CLI started via `swift run` to its parent terminal, so the terminal —
not the unsigned binary — is what must be allowed. Restart the terminal after toggling.
EOF
