#!/usr/bin/env bash
# Show connected HarmonyOS devices. The tablet must have Developer Mode + USB
# debugging on, and you must have accepted the authorization prompt on-device.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$DIR/_common.sh"

echo "Using hdc: $HDC"
echo "---- hdc list targets ----"
"$HDC" list targets
echo "--------------------------"
echo "If you see an empty/[Empty] list: re-plug USB, enable Developer Mode +"
echo "USB debugging on the tablet, and accept the on-device authorization dialog."
