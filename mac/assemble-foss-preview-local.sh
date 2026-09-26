#!/bin/zsh
# Assemble and Apple-Development-sign one local FOSS-P1 app for install-readiness checks.
# This script never creates a zip, notarizes, publishes, or accepts self-signed/ad-hoc identity.
set -euo pipefail

HERE="${0:A:h}"
REPOSITORY_ROOT="${HERE:h}"
DEVELOPER_DIR_VALUE="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CORE_LIBRARY_PATH="${SC_MAC_CORE_FFI_LIBRARY_PATH:-$REPOSITORY_ROOT/.build/core-ffi/aarch64-apple-darwin/ffi-release}"
CORE_ARCHIVE="$CORE_LIBRARY_PATH/libsuperconnect_core.a"
CORE_RECEIPT="$CORE_LIBRARY_PATH/core-ffi-receipt-v1.json"
SIGN_IDENTITY="${SC_FOSS_MAC_LOCAL_SIGN_IDENTITY:?set SC_FOSS_MAC_LOCAL_SIGN_IDENTITY to an Apple Development identity}"
OUTPUT="${SC_FOSS_MAC_APP_PATH:-$REPOSITORY_ROOT/.build/foss-preview-local/Superconnect FOSS Preview.app}"
RECEIPT_OUTPUT="${SC_FOSS_MAC_APP_RECEIPT_PATH:-${OUTPUT:h}/mac-local-app-receipt-v1.json}"
INFO_TEMPLATE="$HERE/app/Info.plist"
PRODUCT_NAME='superconnect-app-foss-preview'
APP_NAME='Superconnect FOSS Preview'
BUNDLE_ID='com.superconnect.foss.preview'
SHORT_VERSION='0.2.1'
BUILD_VERSION='3'

fail() { print -u2 -- "$1"; exit 1; }

[[ "$SIGN_IDENTITY" == 'Apple Development: '* && "$SIGN_IDENTITY" != *$'\n'* ]] || fail foss_local_apple_development_identity_required
[[ -d "$DEVELOPER_DIR_VALUE" && ! -L "$DEVELOPER_DIR_VALUE" ]] || fail foss_local_xcode_missing_or_unsafe
[[ -f "$CORE_ARCHIVE" && ! -L "$CORE_ARCHIVE" ]] || fail foss_local_core_archive_missing
[[ -f "$CORE_RECEIPT" && ! -L "$CORE_RECEIPT" ]] || fail foss_local_core_receipt_missing
[[ -f "$INFO_TEMPLATE" && ! -L "$INFO_TEMPLATE" ]] || fail foss_local_info_missing
[[ -z "$(/usr/bin/git -C "$REPOSITORY_ROOT" status --porcelain=v1 --untracked-files=all)" ]] || fail foss_local_source_must_be_clean
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail foss_local_output_must_be_new
[[ ! -e "$RECEIPT_OUTPUT" && ! -L "$RECEIPT_OUTPUT" ]] || fail foss_local_receipt_must_be_new

HEAD_SHA="$(/usr/bin/git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
TREE_SHA="$(/usr/bin/git -C "$REPOSITORY_ROOT" rev-parse 'HEAD^{tree}')"
CORE_SHA="$(/usr/bin/shasum -a 256 "$CORE_ARCHIVE" | /usr/bin/awk '{print $1}')"
CORE_RECEIPT_SHA="$(/usr/bin/shasum -a 256 "$CORE_RECEIPT" | /usr/bin/awk '{print $1}')"

/usr/bin/python3 - "$CORE_RECEIPT" "$HEAD_SHA" "$TREE_SHA" "$CORE_SHA" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if document.get("contract") != {"name": "superconnect.core-ffi-receipt", "version": 1}:
    raise SystemExit("foss_local_core_receipt_contract_invalid")
artifact = document.get("artifact", {})
binding = artifact.get("abiBinding", {})
source = document.get("source", {})
if source.get("dirty") is not False:
    raise SystemExit("foss_local_core_receipt_dirty")
if source.get("gitSha") != sys.argv[2] or source.get("gitTree") != sys.argv[3]:
    raise SystemExit("foss_local_core_receipt_source_mismatch")
if binding.get("sourceGitSha") != sys.argv[2] or binding.get("sourceTreeSha") != sys.argv[3]:
    raise SystemExit("foss_local_core_binding_source_mismatch")
if artifact.get("sha256") != sys.argv[4]:
    raise SystemExit("foss_local_core_archive_hash_mismatch")
if document.get("build") != {
    "profile": "ffi-release",
    "rustVersion": "1.97.1",
    "target": "aarch64-apple-darwin",
    "variant": "full",
}:
    raise SystemExit("foss_local_core_build_identity_mismatch")
if artifact.get("architecture", {}).get("status") != "VERIFIED":
    raise SystemExit("foss_local_core_architecture_unverified")
if artifact.get("symbols", {}).get("status") != "VERIFIED":
    raise SystemExit("foss_local_core_symbols_unverified")
PY

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_TEMPLATE"; }
[[ "$(read_plist CFBundleName)" == "$APP_NAME" ]] || fail foss_local_app_name_mismatch
[[ "$(read_plist CFBundleDisplayName)" == "$APP_NAME" ]] || fail foss_local_display_name_mismatch
[[ "$(read_plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail foss_local_bundle_id_mismatch
[[ "$(read_plist CFBundleExecutable)" == "$PRODUCT_NAME" ]] || fail foss_local_executable_mismatch
[[ "$(read_plist CFBundleShortVersionString)" == "$SHORT_VERSION" ]] || fail foss_local_short_version_mismatch
[[ "$(read_plist CFBundleVersion)" == "$BUILD_VERSION" ]] || fail foss_local_build_version_mismatch
[[ -n "$(read_plist NSScreenCaptureUsageDescription)" ]] || fail foss_local_screen_usage_missing
if /usr/bin/grep -Eqi 'accessibility|input injection|辅助功能' "$INFO_TEMPLATE"; then
  fail foss_local_info_contains_accessibility_request
fi

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
[[ "$IDENTITIES" == *\""$SIGN_IDENTITY"\"* ]] || fail foss_local_signing_identity_unavailable

/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" SC_MAC_CORE_FFI_LIBRARY_PATH="$CORE_LIBRARY_PATH" /usr/bin/xcrun swift build --package-path "$HERE" -c release --product "$PRODUCT_NAME"
BIN_DIR="$(/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_VALUE" SC_MAC_CORE_FFI_LIBRARY_PATH="$CORE_LIBRARY_PATH" /usr/bin/xcrun swift build --package-path "$HERE" -c release --show-bin-path)"
PRODUCT_BINARY="$BIN_DIR/$PRODUCT_NAME"
[[ -f "$PRODUCT_BINARY" && -x "$PRODUCT_BINARY" && ! -L "$PRODUCT_BINARY" ]] || fail foss_local_product_binary_missing

/bin/mkdir -p "${OUTPUT:h}" "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
/bin/cp "$PRODUCT_BINARY" "$OUTPUT/Contents/MacOS/$PRODUCT_NAME"
/bin/cp "$INFO_TEMPLATE" "$OUTPUT/Contents/Info.plist"
/bin/cp "$HERE/app/AppIcon.icns" "$OUTPUT/Contents/Resources/AppIcon.icns"
/bin/chmod 0755 "$OUTPUT/Contents/MacOS/$PRODUCT_NAME"
UNSIGNED_BINARY_SHA="$(/usr/bin/shasum -a 256 "$OUTPUT/Contents/MacOS/$PRODUCT_NAME" | /usr/bin/awk '{print $1}')"

/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$OUTPUT"
/usr/bin/codesign --verify --deep --strict "$OUTPUT"
SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$OUTPUT" 2>&1)"
IDENTIFIER="$(print -r -- "$SIGNATURE_DETAILS" | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}')"
TEAM_ID="$(print -r -- "$SIGNATURE_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CDHASH="$(print -r -- "$SIGNATURE_DETAILS" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
AUTHORITY="$(print -r -- "$SIGNATURE_DETAILS" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
[[ "$IDENTIFIER" == "$BUNDLE_ID" ]] || fail foss_local_signed_identifier_mismatch
[[ "$AUTHORITY" == "$SIGN_IDENTITY" ]] || fail foss_local_signed_authority_mismatch
[[ "$TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || fail foss_local_team_id_missing
[[ "$SIGNATURE_DETAILS" == *'(runtime)'* ]] || fail foss_local_hardened_runtime_missing

SIGNED_BINARY_SHA="$(/usr/bin/shasum -a 256 "$OUTPUT/Contents/MacOS/$PRODUCT_NAME" | /usr/bin/awk '{print $1}')"
INFO_SHA="$(/usr/bin/shasum -a 256 "$OUTPUT/Contents/Info.plist" | /usr/bin/awk '{print $1}')"
CODE_RESOURCES_SHA="$(/usr/bin/shasum -a 256 "$OUTPUT/Contents/_CodeSignature/CodeResources" | /usr/bin/awk '{print $1}')"

/usr/bin/python3 - "$RECEIPT_OUTPUT" "$HEAD_SHA" "$TREE_SHA" "$CORE_SHA" "$CORE_RECEIPT_SHA" "$OUTPUT" "$UNSIGNED_BINARY_SHA" "$SIGNED_BINARY_SHA" "$INFO_SHA" "$CODE_RESOURCES_SHA" "$IDENTIFIER" "$TEAM_ID" "$CDHASH" "$AUTHORITY" "$SHORT_VERSION" "$BUILD_VERSION" <<'PY'
import json
import sys
from pathlib import Path

keys = [
    "output", "sourceGitSha", "sourceTreeSha", "coreArchiveSha256",
    "coreReceiptSha256", "appPath", "unsignedBinarySha256", "signedBinarySha256",
    "infoPlistSha256", "codeResourcesSha256", "identifier", "teamIdentifier",
    "cdhash", "authority", "shortVersion", "buildVersion",
]
values = dict(zip(keys, sys.argv[1:]))
output = Path(values.pop("output"))
document = {
    "contract": "superconnect.foss-preview.mac-local-app-receipt.v1",
    "scope": "local-development-only-not-for-distribution",
    **values,
    "signing": {
        "kind": "APPLE_DEVELOPMENT",
        "hardenedRuntime": True,
        "notarized": False,
        "stapled": False,
    },
}
output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

print -- "foss_local_app_assembled=$OUTPUT"
print -- "foss_local_app_receipt=$RECEIPT_OUTPUT"
print -- "signed_binary_sha256=$SIGNED_BINARY_SHA"
print -- "identifier=$IDENTIFIER"
print -- "teamIdentifier=$TEAM_ID"
print -- "cdhash=$CDHASH"
