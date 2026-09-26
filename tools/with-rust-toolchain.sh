#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tools/lib/rust-toolchain.sh"
sc_load_rust_toolchain "$ROOT"

if ! command -v rustup >/dev/null 2>&1; then
  printf 'pinned_rustup_missing\n' >&2
  exit 73
fi

SC_RUST_TOOLCHAIN_BIN="$(dirname "$(rustup which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" cargo)")"
[[ -x "$SC_RUST_TOOLCHAIN_BIN/cargo" ]] || {
  printf 'pinned_cargo_missing: %s\n' "$SC_RUST_TOOLCHAIN_BIN/cargo" >&2
  exit 73
}
export PATH="$SC_RUST_TOOLCHAIN_BIN:$PATH"
export RUSTC="$(rustup which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" rustc)"
export RUSTDOC="$(rustup which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" rustdoc)"
exec rustup run "$SC_RUST_TOOLCHAIN_VERSION" "$@"
