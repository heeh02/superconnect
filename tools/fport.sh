#!/usr/bin/env bash
# Set up TCP-over-USB port forwarding: Mac localhost:$PORT  ->  tablet :$PORT.
# This is the wired transport. Run once per session (after replugging USB).
#   PORT=8888 tools/fport.sh            # add forward
#   PORT=8888 tools/fport.sh rm         # remove forward
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$DIR/_common.sh"

if [[ "${1:-}" == "rm" ]]; then
  echo "Removing forward tcp:$PORT -> tcp:$PORT"
  "$HDC" fport rm "tcp:$PORT" "tcp:$PORT" || true
else
  echo "Adding forward: Mac localhost:$PORT -> tablet :$PORT (over USB)"
  "$HDC" fport "tcp:$PORT" "tcp:$PORT"
fi

echo "---- hdc fport ls ----"
"$HDC" fport ls
