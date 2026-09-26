#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! pmset -g batt | grep -Fq "Now drawing from 'AC Power'"; then
    printf '%s\n' "android_build_mac_requires_ac_power" >&2
    exit 1
  fi
fi

if [[ ! -x "$ROOT/gradlew" ]]; then
  printf '%s\n' "android_build_missing_pinned_gradle_wrapper" >&2
  exit 1
fi

check_sha256() {
  local path="$1" expected="$2" code="$3"
  if [[ ! -f "$path" ]] || [[ "$(shasum -a 256 "$path" | awk '{print $1}')" != "$expected" ]]; then
    printf '%s\n' "$code" >&2
    exit 1
  fi
}

check_sha256 \
  "$ROOT/gradle/wrapper/gradle-wrapper.jar" \
  "498495120a03b9a6ab5d155f5de3c8f0d986a449153702fb80fc80e134484f17" \
  "android_build_missing_or_wrong_wrapper_jar"
check_sha256 \
  "$ROOT/gradle/verification-metadata.xml" \
  "b2f3dea272364b03b00c2d4bc50a2f8e6a3c68309cb2789a7e3c1a49c79957a4" \
  "android_build_missing_or_wrong_dependency_verification"

if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
  printf '%s\n' "android_build_missing_temurin_17" >&2
  exit 1
fi
java_facts="$($JAVA_HOME/bin/java -XshowSettings:properties -version 2>&1)"
if ! grep -Fq 'java.vendor = Eclipse Adoptium' <<<"$java_facts" ||
   ! grep -Eq 'java.version = 17([.]|$)' <<<"$java_facts"; then
  printf '%s\n' "android_build_requires_temurin_17" >&2
  exit 1
fi

exec "$ROOT/gradlew" --no-daemon --dependency-verification=strict -p "$ROOT" :app:assembleDebug
