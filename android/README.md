# Superconnect FOSS-P1 Android Receiver — v0.2.2 preview

This public source builds one arm64 Android Receiver intended for Android and 卓易通. v0.2.2
restores consent-gated stylus and two-finger input production paths. The release page records
the exact artifact identity and physical acceptance separately from source and build checks.

## Composition

- Package: `com.superconnect.receiver.foss`, version `0.2.2` / code `4` (separate from old free,
  Standard and root apps; upgrading v0.2.1 in place requires the same signing certificate).
- Product role: Receiver/Sink only.
- Input policy: optional tablet touch, stylus/drawing mode, two-finger gestures and keyboard over
  authenticated INPUT; Mac consent and Accessibility are required for injection. The Mac successor
  must consume the existing secondary-button, scroll and zoom records. No Android Accessibility
  service or Android Source.
- Video codec: H.264 only. HEVC is not advertised until the canonical Android `video_config`
  consumer can accept and route it to the matching decoder without terminating the Session.
- Transport: reliable direct TCP. Loopback/forwarded sockets are not trusted-local: every route uses
  peer consent, SC-AUTH-v1 mutual proof and active SC-RECORD-v1 before capability/video delivery.
- `:protocol`: Kotlin projections for Auth, frame and video metadata.
- `:core-wire`: selected receiver JNI bridges linked to the generated **95-symbol FOSS preview** ABI,
  not the full commercial Android ABI.
- `:app`: pairing UI, ordered socket owner, encrypted Session, MediaCodec decoder and fullscreen/exit.

The first trial intentionally omits enhanced recovery anchors. Ordinary authenticated
`request_keyframe` and canonical `video_config` remain in the selected receiver path.

## Source checks

These checks do not build or read signing secrets and are safe on the editing Mac:

```bash
cd android
bash check-release-signing.sh
bash check-foss-native-boundary.sh
```

## Focused compile prerequisite

For this bounded v0.2.2 patch, the maintainer also permits a trusted AC-powered Apple-silicon Mac
when the owned execution server is offline. The pinned build requires Temurin 17,
the checked Gradle 8.9 wrapper and dependency-verification metadata, Android SDK 35/build-tools
35.0.0, NDK 27.2.12479018, CMake 3.22.1, Ninja, host Clang and Rust 1.97.1 with
`aarch64-linux-android` installed. The checkout must be clean so `tools/build-core-ffi.sh` can
bind the preview Core archive to the exact public source commit.

Once that host is available, run:

```bash
cd android
JAVA_HOME=/path/to/temurin-17 bash build-apk.sh
```

`build-apk.sh` checks the pinned wrapper, strict dependency metadata and Temurin 17
before Gradle starts. A successful compile/link is still not native behavior, device compatibility,
changing pixels, Stop/reconnect, signer, or release evidence.

The free-only dependency metadata was generated from `:protocol:testClasses` and
`:app:compileDebugKotlin`, then is enforced in strict mode. It contains no Huawei/AppGallery,
commercial or Paddle component; its SHA-256 is
`b2f3dea272364b03b00c2d4bc50a2f8e6a3c68309cb2789a7e3c1a49c79957a4`.

## Signing boundary

Debug compilation needs no release credentials. This v0.2.2 open-source prerelease explicitly
permits a debug-signed APK. The published asset must use the same certificate as public v0.2.1 for
the claimed in-place preview update; future signer changes may require uninstalling it and losing
app-local data. Stable release tasks remain bound to a dedicated signer and fail if
`keystore.properties`, a required field, or its keystore is missing. See `sign-release.md`.
