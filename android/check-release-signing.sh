#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_FILE="$ROOT/app/build.gradle.kts"
SIGNING_DOC="$ROOT/sign-release.md"

fail() {
  printf 'release_signing_boundary_failed: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'signingConfig = signingConfigs.getByName("release")' "$BUILD_FILE" \
  || fail "release variant is not pinned to the release signing config"
if grep -Fq 'signingConfigs.getByName("debug")' "$BUILD_FILE"; then
  fail "release configuration still references debug signing"
fi

for key in storeFile storePassword keyAlias keyPassword; do
  grep -Fq "\"$key\"" "$BUILD_FILE" \
    || fail "required signing field is not validated: $key"
done

for marker in \
  'release_signing_properties_missing' \
  'release_signing_properties_incomplete' \
  'release_signing_keystore_missing' \
  'it.name.endsWith("ReleaseBuild")'; do
  grep -Fq "$marker" "$BUILD_FILE" || fail "missing release guard: $marker"
done

if grep -Fq 'falls back to the debug' "$SIGNING_DOC"; then
  fail "release documentation still promises debug fallback"
fi

printf '%s\n' 'Android release signing boundary: source checks passed'
