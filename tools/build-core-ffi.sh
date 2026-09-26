#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tools/lib/rust-toolchain.sh"
sc_load_rust_toolchain "$ROOT"
TOOLCHAIN_LOCK="$ROOT/release/TOOLCHAINS.lock.json"
[[ -f "$TOOLCHAIN_LOCK" && ! -L "$TOOLCHAIN_LOCK" ]] || {
  printf '%s\n' "core_ffi_toolchain_lock_missing_or_unsafe" >&2
  exit 1
}
ABI_MANIFEST_TOOL="$ROOT/tools/core_abi_manifest.py"
BUILD_INPUT_TOOL="$ROOT/tools/core_ffi_build_inputs.py"
SOURCE_ROOT="$ROOT"
SOURCE_SNAPSHOT=""

cleanup_source_snapshot() {
  if [[ -n "$SOURCE_SNAPSHOT" && -d "$SOURCE_SNAPSHOT" ]]; then
    rm -rf -- "$SOURCE_SNAPSHOT"
  fi
}
trap cleanup_source_snapshot EXIT

usage() {
  printf '%s\n' \
    "usage: build-core-ffi.sh --target <triple> --profile <dev-ffi|ffi-release> [--variant <full|minimal>]" \
    "       build-core-ffi.sh --verify-archive <path> --target <triple> --profile <dev-ffi|ffi-release> [--variant <full|minimal>]" >&2
  exit 64
}

target=""
profile=""
verify_archive=""
variant="full"
while (( $# > 0 )); do
  case "$1" in
    --target)
      (( $# >= 2 )) || usage
      target="$2"
      shift 2
      ;;
    --profile)
      (( $# >= 2 )) || usage
      profile="$2"
      shift 2
      ;;
    --verify-archive)
      (( $# >= 2 )) || usage
      verify_archive="$2"
      shift 2
      ;;
    --variant)
      (( $# >= 2 )) || usage
      variant="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$target" && -n "$profile" ]] || usage
case "$profile" in
  dev-ffi|ffi-release) ;;
  *)
    printf 'core_ffi_invalid_profile: %s\n' "$profile" >&2
    exit 65
    ;;
esac

case "$variant" in
  full|minimal) ;;
  *)
    printf 'core_ffi_unknown_variant: %s\n' "$variant" >&2
    exit 65
    ;;
esac

if [[ "$variant" == "full" ]]; then
  OUTPUT_ROOT="${SC_CORE_FFI_OUTPUT_ROOT:-$ROOT/.build/core-ffi}"
  CARGO_TARGET_DIR="${SC_CORE_CARGO_TARGET_DIR:-$ROOT/.build/core-ffi-cargo-target}"
else
  OUTPUT_ROOT="${SC_CORE_FFI_OUTPUT_ROOT:-$ROOT/.build/core-ffi/$variant}"
  CARGO_TARGET_DIR="${SC_CORE_CARGO_TARGET_DIR:-$ROOT/.build/core-ffi-cargo-target/$variant}"
fi
case "$OUTPUT_ROOT" in /*) ;; *) OUTPUT_ROOT="$ROOT/$OUTPUT_ROOT" ;; esac
case "$CARGO_TARGET_DIR" in /*) ;; *) CARGO_TARGET_DIR="$ROOT/$CARGO_TARGET_DIR" ;; esac

case "$target" in
  aarch64-apple-darwin|x86_64-apple-darwin|aarch64-apple-ios|aarch64-apple-ios-sim|\
  x86_64-apple-ios|aarch64-linux-android|aarch64-unknown-linux-ohos|\
  x86_64-pc-windows-msvc|aarch64-pc-windows-msvc|x86_64-unknown-linux-gnu) ;;
  *)
    printf 'core_ffi_unknown_target: %s\n' "$target" >&2
    exit 65
    ;;
esac

reject_ambient_release_build_controls() {
  local name value
  while IFS='=' read -r name value; do
    case "$name" in
      RUSTFLAGS|CARGO_ENCODED_RUSTFLAGS|RUSTDOCFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|\
      CARGO_BUILD_RUSTFLAGS|CARGO_BUILD_RUSTC|CARGO_BUILD_RUSTDOC|\
      CARGO_BUILD_RUSTC_WRAPPER|CARGO_BUILD_TARGET|CARGO_INCREMENTAL|RUSTC_BOOTSTRAP|\
      CARGO_PROFILE_*|CARGO_TARGET_*_RUSTFLAGS|CARGO_TARGET_*_LINKER|CARGO_TARGET_*_RUNNER|\
      SC_CORE_CARGO_BIN|SC_CORE_RUSTC_BIN|SC_CORE_RUSTDOC_BIN|SC_CORE_AR_BIN|\
      SC_CORE_FILE_BIN|SC_CORE_OBJDUMP_BIN)
        printf 'core_ffi_ambient_build_control_forbidden: %s\n' "$name" >&2
        return 1
        ;;
    esac
  done < <(env)
}

release_build_input_sha256="unbound"
release_source_clean=0
if [[ -z "$verify_archive" && "$profile" == "ffi-release" ]]; then
  reject_ambient_release_build_controls
  release_build_input_sha256="$(PYTHONDONTWRITEBYTECODE=1 python3 \
    "$BUILD_INPUT_TOOL" identity --require-clean)"
  [[ "$release_build_input_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf '%s\n' "core_ffi_build_input_identity_invalid" >&2
    exit 1
  }
  SOURCE_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/sc-core-ffi-source.XXXXXX")"
  git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$SOURCE_SNAPSHOT"
  SOURCE_ROOT="$SOURCE_SNAPSHOT"
  release_source_clean=1
fi

MANIFEST="$SOURCE_ROOT/core/Cargo.toml"
ABI_MANIFEST_TOOL_FOR_BUILD="$SOURCE_ROOT/tools/core_abi_manifest.py"
# Recompute every target surface from the exact source tree that will be built. Archive-only
# verification and diagnostic builds use the current tree; release builds use the clean HEAD
# snapshot above so a concurrent edit/revert of the working tree cannot affect compiler inputs.
PYTHONDONTWRITEBYTECODE=1 python3 "$ABI_MANIFEST_TOOL_FOR_BUILD" \
  generate-set --check >/dev/null

resolve_ar() {
  if [[ -n "${SC_CORE_AR_BIN:-}" ]]; then
    printf '%s\n' "$SC_CORE_AR_BIN"
  elif command -v llvm-ar >/dev/null 2>&1; then
    command -v llvm-ar
  elif command -v ar >/dev/null 2>&1; then
    command -v ar
  else
    printf '%s\n' "core_ffi_missing_tool: ar" >&2
    return 1
  fi
}

resolve_file() {
  if [[ -n "${SC_CORE_FILE_BIN:-}" ]]; then
    printf '%s\n' "$SC_CORE_FILE_BIN"
  elif command -v file >/dev/null 2>&1; then
    command -v file
  else
    printf '%s\n' "core_ffi_missing_tool: file" >&2
    return 1
  fi
}

resolve_objdump() {
  local candidate
  if [[ -n "${SC_CORE_OBJDUMP_BIN:-}" ]]; then
    printf '%s\n' "$SC_CORE_OBJDUMP_BIN"
  elif command -v llvm-objdump >/dev/null 2>&1; then
    command -v llvm-objdump
  elif command -v xcrun >/dev/null 2>&1 \
    && candidate="$(xcrun --find llvm-objdump 2>/dev/null)" \
    && [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
  elif command -v objdump >/dev/null 2>&1; then
    command -v objdump
  else
    return 1
  fi
}

description_matches_target() {
  local triple="$1"
  local description_lower="$2"
  case "$triple" in
    aarch64-apple-darwin|aarch64-apple-ios|aarch64-apple-ios-sim)
      [[ "$description_lower" == *"mach-o"* && "$description_lower" == *"arm64"* ]]
      ;;
    x86_64-apple-darwin|x86_64-apple-ios)
      [[ "$description_lower" == *"mach-o"* && "$description_lower" == *"x86_64"* ]]
      ;;
    aarch64-linux-android|aarch64-unknown-linux-ohos)
      [[ "$description_lower" == *"elf"* \
        && ( "$description_lower" == *"aarch64"* || "$description_lower" == *"arm64"* ) ]]
      ;;
    x86_64-unknown-linux-gnu)
      [[ "$description_lower" == *"elf"* \
        && ( "$description_lower" == *"x86-64"* || "$description_lower" == *"x86_64"* ) ]]
      ;;
    x86_64-pc-windows-msvc)
      [[ "$description_lower" == *"coff"* \
        && ( "$description_lower" == *"x86-64"* || "$description_lower" == *"x86_64"* \
          || "$description_lower" == *"amd64"* ) ]]
      ;;
    aarch64-pc-windows-msvc)
      [[ "$description_lower" == *"coff"* \
        && ( "$description_lower" == *"aarch64"* || "$description_lower" == *"arm64"* ) ]]
      ;;
  esac
}

is_apple_target() {
  case "$1" in
    aarch64-apple-darwin|x86_64-apple-darwin|aarch64-apple-ios|\
    aarch64-apple-ios-sim|x86_64-apple-ios) return 0 ;;
    *) return 1 ;;
  esac
}

apple_object_matches_target() {
  local triple="$1" object="$2" objdump_bin="$3" expected platform load_commands
  case "$triple" in
    aarch64-apple-darwin|x86_64-apple-darwin) expected=1 ;;
    aarch64-apple-ios) expected=2 ;;
    aarch64-apple-ios-sim|x86_64-apple-ios) expected=7 ;;
    *) return 1 ;;
  esac
  if command -v otool >/dev/null 2>&1; then
    load_commands="$(otool -l "$object" 2>/dev/null)" || return 1
  elif [[ -n "$objdump_bin" ]]; then
    # LLVM can inspect Apple load commands on a non-Apple build host. CPU identity alone
    # cannot distinguish an arm64 macOS archive from an iOS device or simulator archive.
    load_commands="$("$objdump_bin" --macho --private-headers "$object" 2>/dev/null)" \
      || return 1
  else
    printf 'core_ffi_missing_tool: otool or LLVM Mach-O objdump\n' >&2
    return 1
  fi
  platform="$(printf '%s\n' "$load_commands" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found=1; next }
    found && $1 == "platform" { print tolower($2); exit }
  ')"
  case "$platform" in
    macos) platform=1 ;;
    ios) platform=2 ;;
    iossimulator) platform=7 ;;
  esac
  if [[ -n "$platform" ]]; then
    [[ "$platform" == "$expected" ]]
    return
  fi
  case "$triple:$load_commands" in
    *-apple-darwin:*LC_VERSION_MIN_MACOSX*) return 0 ;;
    aarch64-apple-ios:*LC_VERSION_MIN_IPHONEOS*) return 0 ;;
    x86_64-apple-ios:*LC_VERSION_MIN_IPHONEOS*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_archive_architecture() {
  local archive="$1"
  local triple="$2"
  local ar_bin file_bin objdump_bin objdump_output members extract_dir member candidate
  local description description_lower apple_objects=0

  [[ -f "$archive" ]] || {
    printf 'core_ffi_archive_missing: %s\n' "$archive" >&2
    return 1
  }
  archive="$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")"
  objdump_bin="$(resolve_objdump || true)"
  if [[ -n "$objdump_bin" ]] && ! is_apple_target "$triple"; then
    objdump_output="$($objdump_bin -f "$archive" 2>&1 || true)"
    description_lower="$(printf '%s' "$objdump_output" | tr '[:upper:]' '[:lower:]')"
    if [[ "$description_lower" == *"file format"* ]]; then
      # New LLVM/GNU objdump versions may print a generic `elf64-little` format and put the
      # actual machine on a separate `architecture:` line. Validate the complete report instead
      # of rejecting the first format line before its architecture fact is read.
      if description_matches_target "$triple" "$description_lower"; then
        description="$(printf '%s\n' "$objdump_output" | awk '
          /file format/ && !format { format=$0 }
          /architecture:/ && !arch { arch=$0 }
          END { print format (arch ? "; " arch : "") }
        ')"
        printf 'ok: archive target %s (%s)\n' "$triple" "$description"
        return 0
      fi
      description="$(printf '%s\n' "$objdump_output" | awk '/file format|architecture:/ { print; if (++n == 2) exit }')"
      printf 'core_ffi_wrong_arch: %s: %s\n' "$triple" "$description" >&2
      return 1
    fi
  fi

  ar_bin="$(resolve_ar)"
  if ! members="$("$ar_bin" -t "$archive" 2>/dev/null)"; then
    printf 'core_ffi_invalid_archive: %s\n' "$archive" >&2
    return 1
  fi
  [[ -n "$members" ]] || {
    printf 'core_ffi_invalid_archive: %s\n' "$archive" >&2
    return 1
  }
  file_bin="$(resolve_file)"

  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/sc-core-archive.XXXXXX")"
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    case "$member" in
      __.SYMDEF|__.SYMDEF\ SORTED|/|//) continue ;;
    esac
    if ! (cd "$extract_dir" && "$ar_bin" -x "$archive" "$member" 2>/dev/null); then
      continue
    fi
    candidate="$extract_dir/$member"
    [[ -f "$candidate" ]] || candidate="$extract_dir/$(basename "$member")"
    [[ -f "$candidate" ]] || continue
    description="$($file_bin -b "$candidate" 2>/dev/null || true)"
    description_lower="$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')"
    if [[ "$description_lower" != *"mach-o"* && "$description_lower" != *"elf"* \
      && "$description_lower" != *"coff"* ]]; then
      continue
    fi
    if description_matches_target "$triple" "$description_lower"; then
      if is_apple_target "$triple"; then
        if ! apple_object_matches_target "$triple" "$candidate" "$objdump_bin"; then
          printf 'core_ffi_wrong_apple_platform: %s: %s\n' "$triple" "$description" >&2
          rm -rf -- "$extract_dir"
          return 1
        fi
        apple_objects=$((apple_objects + 1))
        continue
      fi
      printf 'ok: archive target %s (%s)\n' "$triple" "$description"
      rm -rf -- "$extract_dir"
      return 0
    fi
    printf 'core_ffi_wrong_arch: %s: %s\n' "$triple" "$description" >&2
    rm -rf -- "$extract_dir"
    return 1
  done <<< "$members"

  if (( apple_objects > 0 )); then
    printf 'ok: archive target %s (%s Apple objects)\n' "$triple" "$apple_objects"
    rm -rf -- "$extract_dir"
    return 0
  fi

  printf 'core_ffi_archive_no_object: %s\n' "$archive" >&2
  rm -rf -- "$extract_dir"
  return 1
}

if [[ -n "$verify_archive" ]]; then
  verify_archive_architecture "$verify_archive" "$target"
  exit 0
fi

resolve_cargo_command() {
  local cargo_bin rustc_bin rustdoc_bin rustup_bin
  rustup_bin="$(command -v rustup 2>/dev/null || true)"
  if [[ -n "${SC_CORE_CARGO_BIN:-}${SC_CORE_RUSTC_BIN:-}${SC_CORE_RUSTDOC_BIN:-}" ]]; then
    [[ -n "${SC_CORE_CARGO_BIN:-}" && -n "${SC_CORE_RUSTC_BIN:-}" &&
       -n "${SC_CORE_RUSTDOC_BIN:-}" ]] || {
      printf '%s\n' "core_ffi_partial_toolchain_override_forbidden" >&2
      return 1
    }
    cargo_bin="$SC_CORE_CARGO_BIN"
    rustc_bin="$SC_CORE_RUSTC_BIN"
    rustdoc_bin="$SC_CORE_RUSTDOC_BIN"
  elif [[ -n "$rustup_bin" ]]; then
    cargo_bin="$($rustup_bin which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" cargo)"
    rustc_bin="$($rustup_bin which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" rustc)"
    rustdoc_bin="$($rustup_bin which --toolchain "$SC_RUST_TOOLCHAIN_VERSION" rustdoc)"
  else
    printf '%s\n' "core_ffi_missing_pinned_toolchain: rustup or complete trusted override" >&2
    return 1
  fi
  [[ -x "$cargo_bin" && -x "$rustc_bin" && -x "$rustdoc_bin" ]] || {
    printf '%s\n' "core_ffi_pinned_tool_not_executable" >&2
    return 1
  }
  [[ "$($cargo_bin --version)" == cargo\ "$SC_RUST_TOOLCHAIN_VERSION"\ * &&
     "$($rustc_bin --version)" == rustc\ "$SC_RUST_TOOLCHAIN_VERSION"\ * &&
     "$($rustdoc_bin --version)" == rustdoc\ "$SC_RUST_TOOLCHAIN_VERSION"\ * ]] || {
    printf '%s\n' "core_ffi_toolchain_version_mismatch: expected $SC_RUST_TOOLCHAIN_VERSION" >&2
    return 1
  }
  cargo_command=(env "RUSTC=$rustc_bin" "RUSTDOC=$rustdoc_bin" "$cargo_bin")
}

declare -a cargo_command
resolve_cargo_command
source_git_sha="$(git -C "$ROOT" rev-parse HEAD)"
source_tree_sha="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
[[ "$source_git_sha" =~ ^[0-9a-f]{40}$ &&
   "$source_tree_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' "core_ffi_invalid_source_identity" >&2
  exit 1
}
declare -a build_args
build_args=(
  build
  --locked
  --manifest-path "$MANIFEST"
  --target "$target"
  --profile "$profile"
)
case "$variant" in
  full) ;;
  minimal) build_args+=(--no-default-features) ;;
esac
build_args+=(--target-dir "$CARGO_TARGET_DIR")
(
  cd "$SOURCE_ROOT"
  SC_CORE_FFI_SOURCE_GIT_SHA="$source_git_sha" \
  SC_CORE_FFI_SOURCE_TREE_SHA="$source_tree_sha" \
  SC_CORE_FFI_BUILD_INPUT_SHA256="$release_build_input_sha256" \
  SC_CORE_FFI_SOURCE_CLEAN="$release_source_clean" \
  SC_CORE_FFI_PROFILE="$profile" \
    "${cargo_command[@]}" "${build_args[@]}"
)

verify_release_source_unchanged() {
  local current
  [[ "$profile" == "ffi-release" ]] || return 0
  current="$(PYTHONDONTWRITEBYTECODE=1 python3 \
    "$BUILD_INPUT_TOOL" identity --require-clean)" || return 1
  [[ "$current" == "$release_build_input_sha256" ]] || {
    printf 'core_ffi_source_changed_during_build: before=%s after=%s\n' \
      "$release_build_input_sha256" "$current" >&2
    return 1
  }
}
verify_release_source_unchanged

if [[ "$target" == *-windows-msvc ]]; then
  source_archive="$CARGO_TARGET_DIR/$target/$profile/superconnect_core.lib"
  archive_name="superconnect_core.lib"
else
  source_archive="$CARGO_TARGET_DIR/$target/$profile/libsuperconnect_core.a"
  archive_name="libsuperconnect_core.a"
fi
[[ -f "$source_archive" ]] || {
  printf 'core_ffi_archive_missing: %s\n' "$source_archive" >&2
  exit 1
}

destination_dir="$OUTPUT_ROOT/$target/$profile"
mkdir -p "$destination_dir"
cp "$source_archive" "$destination_dir/$archive_name"
abi_manifest="$destination_dir/core-abi-manifest-v1.json"
PYTHONDONTWRITEBYTECODE=1 python3 "$ABI_MANIFEST_TOOL_FOR_BUILD" materialize \
  --target "$target" --variant "$variant" \
  --output "$abi_manifest" >/dev/null
verify_archive_architecture "$destination_dir/$archive_name" "$target"
receipt_path="$destination_dir/core-ffi-receipt-v1.json"
if [[ "$profile" == "ffi-release" ]]; then
  verify_release_source_unchanged
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tools/core_ffi_receipt.py" create \
    --archive "$destination_dir/$archive_name" \
    --abi-manifest "$abi_manifest" \
    --target "$target" --profile "$profile" --variant "$variant" \
    --output "$receipt_path" --replace >/dev/null
  if ! verify_release_source_unchanged; then
    rm -f -- "$receipt_path"
    exit 1
  fi
  if [[ "$variant" == "full" ]]; then
    printf 'core_ffi_built: %s/%s/%s\n' "$target" "$profile" "$archive_name"
  else
    printf 'core_ffi_built: %s/%s/%s (%s)\n' "$target" "$profile" "$archive_name" "$variant"
  fi
else
  # This is a builder-owned fixed output location.  Remove any receipt left by an older builder so
  # a dev archive (which may contain debug/test hooks) can never be mistaken for canonical input.
  if [[ -e "$receipt_path" || -L "$receipt_path" ]]; then
    rm -f -- "$receipt_path"
  fi
  [[ ! -e "$receipt_path" && ! -L "$receipt_path" ]] || {
    printf 'core_ffi_diagnostic_receipt_cleanup_failed: %s\n' "$receipt_path" >&2
    exit 1
  }
  printf 'core_ffi_diagnostic_built_no_receipt: %s/%s/%s (%s)\n' \
    "$target" "$profile" "$archive_name" "$variant"
fi
