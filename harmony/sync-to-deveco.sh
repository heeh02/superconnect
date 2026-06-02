#!/usr/bin/env bash
#
# sync-to-deveco.sh — push this repo's HarmonyOS source into the separate DevEco Studio
# project that DevEco's Run ▶ actually builds.
#
# WHY THIS EXISTS: DevEco builds its OWN project copy (default ~/DevEcoStudioProjects/superconnect),
# NOT this git repo (harmony/). The two drift, so Run kept building STALE code (missing the
# single-active guard, the status-coupling fix, peerId persistence, …) — and a hand-copy once left
# a stray ',o' in Index.ets that broke the ArkTS compile. This script makes the repo the single
# source of truth: it mirrors ONLY source (entry/src), and never the signing / build-profile /
# local.properties the DevEco copy owns (so device signing keeps working).
#
# USAGE:   ./sync-to-deveco.sh [dest-project-root]
#   dest-project-root defaults to ~/DevEcoStudioProjects/superconnect
#
# After it runs, click Run ▶ in DevEco. To verify the synced code compiles WITHOUT DevEco, run
# the assembleHap one-liner in the repo (see README / prior build commands).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"                 # .../harmony
DEST="${1:-$HOME/DevEcoStudioProjects/superconnect}"
SRC="$REPO_DIR/entry/src/"
DST="$DEST/entry/src/"

if [ ! -d "$DST" ]; then
  echo "✗ DevEco project source not found at: $DST"
  echo "  Pass the DevEco project root explicitly:  ./sync-to-deveco.sh /path/to/DevEcoProject"
  exit 1
fi

echo "Mirroring HarmonyOS source (entry/src only — signing/build config left untouched):"
echo "  from: $SRC"
echo "  to:   $DST"
rsync -a --delete "$SRC" "$DST"
echo "✓ synced. Now click Run ▶ in DevEco."
