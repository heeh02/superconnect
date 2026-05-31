#!/usr/bin/env bash
# Install a built .hap onto the connected HarmonyOS device via hdc.
#   tools/install-hap.sh path/to/entry-default-signed.hap
# (DevEco normally installs on Run; use this for CLI installs of a signed .hap.)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$DIR/_common.sh"

HAP="${1:-}"
if [[ -z "$HAP" || ! -f "$HAP" ]]; then
  echo "usage: tools/install-hap.sh <path-to-signed.hap>" >&2
  exit 2
fi

echo "Installing $HAP …"
"$HDC" install "$HAP"
echo "Done. Launch the app on the tablet (it must be foreground to listen)."
