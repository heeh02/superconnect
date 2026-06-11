# Releasing the FREE edition (mac + harmony + android)

How to cut a free-edition release from `dev` — three installable packages, one version number.
Scope is **strictly free** (see `FREE_PAID_MATRIX.md` §1): no entitlement code, no UDP video, no
paid overlay ever lands here. Build **artifacts are never committed** (all gitignored); only
source + this process live on GitHub.

## One version, three places (bump together)

| Platform | File | Fields |
|---|---|---|
| macOS | `mac/app/Info.plist` | `CFBundleShortVersionString` (e.g. `0.2.0`) + `CFBundleVersion` (int, +1) |
| HarmonyOS | `harmony/AppScope/app.json5` | `versionName` + `versionCode` (+1, never decrease) + `buildVersion` |
| Android | `android/app/build.gradle.kts` | `versionName` + `versionCode` (+1, never decrease) |

Current free release: **0.2.0** (mac build 2 · harmony 1000001 · android 2).

## 1. macOS — `superconnect_free.app`

```bash
mac/build-free-app.sh --dist
# → ~/Desktop/superconnect_free.app  +  superconnect_free.app.zip (shareable)
```

Universal (arm64 + x86_64), bundle id `com.superconnect.free`, signed with the stable self-signed
cert (TCC grants survive rebuilds). Bundles `hdc` + `adb` when found on the build machine, so the
app is self-contained for wired connections. First open on another Mac: right-click → 打开, or
`xattr -dr com.apple.quarantine`.

## 2. Android — release APK

One-time keystore bootstrap: `android/sign-release.md` (the keystore + `keystore.properties` are
gitignored secrets — each maintainer holds their own; without them release falls back to the
debug signature so a fresh clone still builds).

```bash
cd android && gradle --no-daemon :protocol:test :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk   (universal: no native libs, minSdk 24)
apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk   # expect the stable CN
```

Sideload on any Android 7+ device. In-place updates work release→release (same key); a device
with a debug-signed install must uninstall once.

## 3. HarmonyOS — HAP

The repo `harmony/` is the source of truth but holds **no signing** (`signingConfigs: []`).
Packaging goes through a DevEco project copy that owns the signing configs:

```bash
harmony/sync-to-deveco.sh                 # mirrors entry/src into ~/DevEcoStudioProjects/superconnect
cp harmony/AppScope/app.json5 ~/DevEcoStudioProjects/superconnect/AppScope/app.json5   # carry the version bump
cd ~/DevEcoStudioProjects/superconnect
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$PATH"
hvigorw --no-daemon assembleHap -p product=default -p buildMode=release
# → entry/build/default/outputs/default/entry-default-signed.hap (+ -unsigned.hap)
```

The *unsigned* hap is the distribution-neutral artifact (anyone re-signs with their own Huawei
identity / DevEco automatic signing); the *signed* one installs only on devices provisioned for
the signing profile. AppGallery distribution later uses a release certificate in DevEco.

## 4. Pre-release checklist

- [ ] `dev` contains **zero** paid code: `grep -rn "EntitlementProvider\|UdpVideo" mac/Sources android harmony/entry/src` → no hits.
- [ ] Versions bumped in lockstep (table above) + `FREE_PAID_MATRIX.md` §2 parity table still accurate.
- [ ] Protocol conformance green: `bash tools/check-protocol.sh` (Swift + C++ + ArkTS vs `proto/vectors.json`).
- [ ] No artifacts/secrets staged: `git status` shows no `.apk` / `.hap` / `.app` / keystore files.
- [ ] On-device smoke test per platform, then push `dev` → PR/merge to `main`, tag `free-vX.Y.Z`.
