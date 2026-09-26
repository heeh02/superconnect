#!/bin/zsh
# Local FOSS-P1 compilation only. This creates no .app bundle, signature, notarization or release
# artifact; formal distribution remains a separate guarded workflow.
set -euo pipefail

HERE="${0:A:h}"
REPOSITORY_ROOT="${HERE:h}"
case "$(uname -m)" in
  arm64) CORE_TARGET=aarch64-apple-darwin ;;
  x86_64) CORE_TARGET=x86_64-apple-darwin ;;
  *) print -u2 -- "unsupported Mac architecture"; exit 65 ;;
esac
CORE_LIBRARY_PATH="${SC_MAC_CORE_FFI_LIBRARY_PATH:-$REPOSITORY_ROOT/.build/core-ffi/$CORE_TARGET/dev-ffi}"
[[ -f "$CORE_LIBRARY_PATH/libsuperconnect_core.a" ]] || {
  print -u2 -- "missing canonical Core archive: $CORE_LIBRARY_PATH/libsuperconnect_core.a"
  exit 1
}

cd "$HERE"
exec env SC_MAC_CORE_FFI_LIBRARY_PATH="$CORE_LIBRARY_PATH" \
  swift build --product superconnect-app-foss-preview "$@"
