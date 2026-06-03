# Superconnect — Android receiver (generic)

The Android tablet as a macOS extended screen, mirroring the HarmonyOS receiver. **Free tier: 1 pad ↔
1 mac, wired (via `adb forward`) + wireless.** Built generic first; brand-specific niceties (Huawei
etc.) layer on later behind the same seams. **Paid features never live on `dev`** — only the free,
generic base does; the private branch optimizes a paid Android build on top of `dev`.

## Modules
- **`:protocol`** — pure Kotlin/JVM. The wire protocol (`FrameCodec`, `InputCodec`), the **4th
  cross-language conformance target** (Swift / C++ / ArkTS / Kotlin) against `../proto/vectors.json`.
  No Android deps → testable off-device.
- **`:app`** — the Android receiver app (depends on `:protocol`).

## Build & test (Android Studio installed)
```bash
# from android/ — first sync in Android Studio generates the Gradle wrapper jar, or:
gradle wrapper        # if you have a system Gradle, to create ./gradlew

# wire-protocol conformance (pure JVM, no device/emulator needed):
./gradlew :protocol:test

# build the app:
./gradlew :app:assembleDebug
```
Open `android/` in Android Studio → let it sync (it provisions the Gradle wrapper + Android SDK path
in `local.properties`, which is git-ignored). `:protocol:test` must be green — it proves the Android
wire format matches the Mac host byte-for-byte.

## Status / roadmap
- [x] Project scaffold + `:protocol` wire codec (FrameCodec, InputCodec) + conformance test.
- [x] TCP server transport (mirror `TcpServerTransport.ets`, single-active) + hello/handshake `Session`
      (advertises screen caps + name + role; handles `video_config`/`ping`). Mac can now connect wired.
- [x] MediaCodec H.264/HEVC decode → `SurfaceView` render (newest-wins, low-latency, keyframe-gated).
- [ ] Input capture: `MotionEvent` (touch + stylus pressure/tilt) + `KeyEvent` → INPUT frames.
- [ ] Discovery advertise (NSD/mDNS) + TOFU pairing + 0.0.0.0 bind for the wireless path.
- [ ] Wired bring-up over `adb forward` (Mac side already done: `AdbFportTunnel` / `AndroidWiredDiscovery`).

## First connect test (wired)
1. Enable **USB debugging** on the tablet; plug in; accept the RSA prompt.
2. Install + run this app (Android Studio Run, or `./gradlew :app:installDebug`).
3. `adb forward tcp:8888 tcp:8888` (the Mac app's `AdbFportTunnel` does this automatically once the
   tablet shows up under the wired card).
4. Connect from the Superconnect Mac app → the tablet shows **已连接 · 投屏中** and then **收到视频配置 W×H**
   (pixels render once the MediaCodec decoder lands).

## Wired path note
The Mac host already supports Android over `adb` (`AdbTool` / `AdbFportTunnel` / `AndroidWiredDiscovery`).
On the device, enable **USB debugging** and accept the RSA prompt, then `adb forward` reaches the
receiver's `127.0.0.1:8888` — the exact analogue of HarmonyOS `hdc fport`.
