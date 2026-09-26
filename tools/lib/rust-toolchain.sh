#!/usr/bin/env bash

sc_load_rust_toolchain() {
  local root="$1"
  local manifest="$root/rust-toolchain.toml"
  local version
  [[ -f "$manifest" ]] || {
    printf 'rust_toolchain_manifest_missing: %s\n' "$manifest" >&2
    return 1
  }
  version="$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$manifest")"
  [[ -n "$version" && "$version" != *$'\n'* ]] || {
    printf 'rust_toolchain_manifest_invalid\n' >&2
    return 1
  }
  SC_RUST_TOOLCHAIN_VERSION="$version"
  export SC_RUST_TOOLCHAIN_VERSION
}
