#!/bin/zsh
# Cross-language wire-protocol conformance harness (ROADMAP §3 / Phase 2).
#
# Every implementation — Swift (mac), C++ (shared/cpp), ArkTS (harmony) — must encode AND decode
# the golden vectors in proto/vectors.json byte-identically. This runs all three suites and exits
# non-zero on ANY drift, so a change to one language's codec can't silently diverge from the others.
#
#   tools/check-protocol.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "── Swift (mac/Tests) ──"
( cd "$ROOT/mac" && swift test --filter Codec ) || { echo "  ✗ Swift conformance failed"; fail=1; }

echo "── C++ (shared/cpp/tests) ──"
( cd "$ROOT/shared/cpp/tests" && make test ) || { echo "  ✗ C++ conformance failed"; fail=1; }

echo "── ArkTS (harmony, headless via Node) ──"
NODE="$(command -v node)"
if [ -z "$NODE" ]; then
  echo "  ✗ node not found — install Node >= 22.7 to validate the ArkTS codecs"; fail=1
else
  "$NODE" --experimental-transform-types --no-warnings "$ROOT/proto/conformance/arkts-conformance.mjs" \
    || { echo "  ✗ ArkTS conformance failed (Node must be >= 22.7 for --experimental-transform-types)"; fail=1; }
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ all three implementations conform to proto/vectors.json"
else
  echo "✗ protocol conformance FAILED — see above"; exit 1
fi
