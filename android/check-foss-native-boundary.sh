#!/usr/bin/env bash
set -euo pipefail

ANDROID_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ANDROID_ROOT/.." && pwd)"
APP="$ANDROID_ROOT/app/src/main/kotlin/com/superconnect/receiver"
CMAKE="$ANDROID_ROOT/core-wire/CMakeLists.txt"

fail() {
  printf 'foss_native_boundary_failed: %s\n' "$1" >&2
  exit 1
}

# The local review checkout has a separate pre-push blocker. It is not a build prerequisite
# for public contributors; this command neither pushes nor changes Git configuration.

grep -Fq 'applicationId = "com.superconnect.receiver.foss"' "$ANDROID_ROOT/app/build.gradle.kts" \
  || fail "FOSS package identity missing"
grep -Fq 'versionCode = 4' "$ANDROID_ROOT/app/build.gradle.kts" \
  || fail "v0.2.2 versionCode is not 4"
grep -Fq 'versionName = "0.2.2"' "$ANDROID_ROOT/app/build.gradle.kts" \
  || fail "v0.2.2 versionName missing"
grep -Fq 'implementation(project(":core-wire"))' "$ANDROID_ROOT/app/build.gradle.kts" \
  || fail "app does not consume receiver JNI module"
grep -Fq -- '--dependency-verification=strict' "$ANDROID_ROOT/build-apk.sh" \
  || fail "Android build does not require strict dependency verification"
grep -Fq 'android_build_requires_temurin_17' "$ANDROID_ROOT/build-apk.sh" \
  || fail "Android build does not enforce Temurin 17"
[[ -f "$ANDROID_ROOT/gradle/verification-metadata.xml" ]] \
  || fail "free-only dependency verification metadata missing"
[[ "$(shasum -a 256 "$ANDROID_ROOT/gradle/verification-metadata.xml" | awk '{print $1}')" == \
  "b2f3dea272364b03b00c2d4bc50a2f8e6a3c68309cb2789a7e3c1a49c79957a4" ]] \
  || fail "free-only dependency verification metadata drifted"
if grep -Eiq 'huawei|appgallery|paddle|commercial' \
    "$ANDROID_ROOT/gradle/verification-metadata.xml"; then
  fail "commercial/Store dependency entered free verification metadata"
fi
grep -Fq 'include(":protocol", ":core-wire", ":app")' "$ANDROID_ROOT/settings.gradle.kts" \
  || fail "core-wire module is not included"
grep -Fq 'set(SC_CORE_FFI_VARIANT "full")' "$CMAKE" \
  || fail "canonical full Core ABI is not selected"
grep -Fq '0x0a1945305a446457L' "$APP/SessionNative.kt" \
  || fail "Android FOSS ABI identity is not pinned"
grep -Fq 'SessionNative_nativeCoreAbiIdentity' "$ANDROID_ROOT/core-wire/src/AndroidSessionJni.cpp" \
  || fail "JNI does not expose Core ABI identity to the Session owner"
grep -Fq 'SC_CORE_ABI_ID_AARCH64_LINUX_ANDROID_FULL_V1 UINT64_C(0x0a1945305a446457)' \
  "$REPO_ROOT/core/include/superconnect_core_abi_identity_v1.h" \
  || fail "Core header FOSS ABI identity drifted"
[[ "$(wc -l < "$REPO_ROOT/qa/baselines/product-symbols/core-abi.txt" | tr -d ' ')" == "95" ]] \
  || fail "FOSS Core export baseline is not 95 symbols"
[[ "$(sed -n '/set(SC_FOSS_RECEIVER_SOURCES/,/)/p' "$CMAKE" | grep -c 'src/')" == "16" ]] \
  || fail "receiver JNI source list is not the 16-source closure with canonical input encoding"

for forbidden in Commercial StandardSource InputOwnership MediaRecovery; do
  if grep -Fq "$forbidden" "$CMAKE"; then
    fail "forbidden JNI source in free CMake graph: $forbidden"
  fi
done

grep -Fq 'trustedLocal = false' "$APP/Session.kt" \
  || fail "Session is not forced to mutual-auth origin"
if grep -Eq 'ListenerOrigin\.Wired|TrustDecision\.Exempt|isLocalhost' \
    "$APP/Session.kt" "$APP/WirelessService.kt"; then
  fail "loopback/Wired authentication exemption remains"
fi
grep -Fq 'if (!reducer.snapshot().recordsActive)' "$APP/Session.kt" \
  || fail "capability transition is not gated by active records"
grep -Fq 'SessionNative.nativePush(handle, bytes)' "$APP/SessionReducer.kt" \
  || fail "socket ingress does not enter canonical secure connection"
grep -Fq 'reducer.push(input)' "$APP/SessionInboundPump.kt" \
  || fail "inbound transition barrier is not wired"
grep -Fq 'sc_secure_connection_push_v1' "$ANDROID_ROOT/core-wire/src/AndroidSessionBridge.cpp" \
  || fail "JNI bridge does not call secure connection push"
grep -Fq 'sc_secure_connection_next_inbound_v1' "$ANDROID_ROOT/core-wire/src/AndroidSessionBridge.cpp" \
  || fail "JNI bridge does not open one authenticated inbound at a time"
grep -Fq 'const RECORD_MAGIC: [u8; 4] = *b"SCR1"' "$REPO_ROOT/core/src/record_v1.rs" \
  || fail "canonical SCR1 record magic missing"
grep -Fq 'mediaRecoveryVersion = null' "$APP/SessionControlWriter.kt" \
  || fail "optional recovery is still advertised"
if grep -Eq 'MediaRecoveryNative|SessionRecoveryCallbacks|MediaRecoveryIdentity' \
    "$APP/Session.kt" "$APP/SessionControlWriter.kt" \
    "$APP/SessionFrameRouter.kt" "$APP/ReceiverSessionHost.kt"; then
  fail "optional recovery consumer remains"
fi

grep -Fq 'inputPolicyBits = IntentV2Bits.INPUT_REMOTE_CONTROL' "$APP/FossProductPolicy.kt" \
  || fail "explicit optional control product profile missing"
grep -Fq 'sc_input_encode_v1' "$ANDROID_ROOT/core-wire/src/AndroidPointerJni.cpp" \
  || fail "input encoding must use Rust"
grep -Fq 'PointerInputNative_encodeExtended' "$ANDROID_ROOT/core-wire/src/AndroidPointerJni.cpp" \
  || fail "successor gesture records have no canonical JNI adapter"
grep -Fq 'GestureController(::emitGesture)' "$APP/PointerInputController.kt" \
  || fail "successor native touch does not use the reviewed gesture policy"
[[ -f "$APP/GestureController.kt" ]] \
  || fail "successor finger gesture policy missing"
grep -Fq 'seal(Channel.INPUT.value, 0, payload)' "$APP/SessionInputWriter.kt" \
  || fail "input must use the authenticated record writer"
grep -Fq 'generationFence::isActive' "$APP/MainActivity.kt" \
  || fail "decoder is not bound to the active session generation"
grep -Fq 'advertisedCodecs: List<String> = listOf("h264")' "$APP/VideoConfigWireNative.kt" \
  || fail "FOSS receiver advertises a codec outside its canonical video_config consumer"
if grep -Eq 'MIMETYPE_VIDEO_HEVC|advertisedCodecs.*hevc' "$APP/DeviceInfo.kt"; then
  fail "FOSS receiver still advertises HEVC from hardware presence alone"
fi
grep -Fq 'config.codec,' "$APP/SessionFrameRouter.kt" \
  || fail "video_config route does not preserve the accepted codec"
grep -Fq 'ownershipLock = lifecycleLock' "$APP/MainActivity.kt" \
  || fail "generation transition and decoder ownership do not share the lifecycle lock"
grep -Fq 'val complete = synchronized(ownershipLock)' "$APP/ReceiverGenerationFence.kt" \
  || fail "media ownership transition is not atomic with resource capture"
grep -Fq 'terminalMediaBridge.revokeFor(effect.type)' "$APP/Session.kt" \
  || fail "CloseTransport does not revoke media authorization at the terminal effect"
grep -Fq 'terminalMediaBridge.requestTransportCloseAfterEffects()' "$APP/Session.kt" \
  || fail "transport drain is not sequenced after terminal media revocation"
grep -Fq 'terminalMediaBridge.revokeFor(SessionReducer.EFFECT_NOTIFY_FATAL)' "$APP/Session.kt" \
  || fail "Record fatal does not use the production media terminal callback"
grep -Fq 'c.releaseOutputBuffer(outIdx, render)' "$APP/VideoDecoder.kt" \
  || fail "MediaCodec output is not generation-fenced before render"
grep -Fq 'frames.wipe()' "$APP/VideoDecoder.kt" \
  || fail "decoder terminal path does not wipe queued access units"
grep -Fq 'KeyGenParameterSpec.Builder' "$APP/FossDeviceIdentity.kt" \
  || fail "AndroidKeyStore device identity missing"
if grep -R -n -E --include='*.kt' \
    'InputSender|InputRouter|InputOwnershipNative|AccessibilityService' \
    "$APP" >/dev/null; then
  fail "legacy input transport or unrelated accessibility service remains"
fi

for removed in \
  ControlPanel.kt FloatingBall.kt \
  InputRouter.kt InputSender.kt PairingStore.kt; do
  [[ ! -e "$APP/$removed" ]] || fail "legacy input/TOFU source remains: $removed"
done
[[ ! -e "$ANDROID_ROOT/protocol/src/main/kotlin/com/superconnect/protocol/InputCodec.kt" ]] \
  || fail "Kotlin INPUT codec remains"
if grep -R -n -E --include='*.kt' 'nativeEncodeInput|nativeDecodeInput|InputEvent|InputType' \
    "$ANDROID_ROOT/protocol/src" >/dev/null; then
  fail "Kotlin protocol INPUT surface remains"
fi

grep -Fq 'android:allowBackup="false"' "$ANDROID_ROOT/app/src/main/AndroidManifest.xml" \
  || fail "pairing data backup is not disabled"
bash "$ANDROID_ROOT/check-release-signing.sh" >/dev/null

printf '%s\n' "FOSS Android native source boundary: checks passed"
