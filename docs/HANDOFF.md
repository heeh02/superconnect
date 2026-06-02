# Superconnect — Handoff / Onboarding

Last updated: 2026-06-02. This is the "start here" for anyone taking over. It points at the
authoritative docs, states what's built, what's risky, and what's left.

---

## 1. What this project is

Turn a **Huawei HarmonyOS tablet into an extended display for a Mac**, with touch / M‑Pencil /
trackpad / keyboard input flowing back to the Mac. The Mac is the **host** (captures + encodes +
streams its screen, injects the tablet's input); the tablet is the **receiver** (decodes + renders +
captures input). Wired-first (USB/hdc), now also **wireless (Wi‑Fi LAN)**. Personal-use project
(private macOS APIs are OK; no App Store constraints).

- **macOS side** (`mac/`, Swift/SwiftPM): private **CGVirtualDisplay** → **ScreenCaptureKit** capture
  → **VideoToolbox** H.264/HEVC encode → TCP. Input injection via **CGEvent**.
- **Tablet side** (`harmony/`, ArkTS + C++ NDK): **OH_VideoDecoder** (surface mode) → XComponent
  render; input captured via ArkUI events.
- **Wire** (`proto/`): a framed TCP protocol (FrameCodec; CONTROL / VIDEO / INPUT channels; a v2
  hello/hello_ack handshake). Locked by golden vectors + a 3‑language conformance harness.

---

## 2. Read these docs first (in order)

1. **`README.md`** — product overview + download/run.
2. **`docs/ARCHITECTURE.md`** — THE living code-structure contract: the layers, the vocabulary
   (Peer/Device, Role, TransportKind/Endpoint, Discovery, Connection/Session/Transport), "where new
   code goes," the multi-device strategy (§5), the v2 handshake (§6), and how to build each side (§7).
3. **`docs/WIRELESS.md`** — the v0.2.1 Wi‑Fi feature: usage, the TOFU pairing/security model, the
   module map, and the **known beta security limitation** (plaintext transport).
4. **`docs/ROADMAP.md`** — versions: v0 (wired) ✅, v0.2.1 (wireless) ✅(dev), v1 (cross-platform, to‑do),
   plus the open-source-readiness notes.
5. **`docs/ONDEVICE.md`** — on-device runbook (deploy + grant permissions).
6. **`docs/PROJECT-STATUS.md`** — periodic status snapshots.
7. **`docs/DESIGN.md`** — FROZEN v0.1 design log. Historical context only; §8 (ChannelMux/Display/
   Capture) describes things never built. `ARCHITECTURE.md` supersedes it for current structure.
8. **`docs/PRESSURE-DRIVERKIT.md`** — why true cross-app pen pressure currently works via CGEvent
   tablet-proximity, and the (shelved) DriverKit route.
9. **`proto/`** — `protocol.md` + `vectors.json` (golden frames) + the conformance harness.

---

## 3. Repo layout

```
mac/      Swift host. Sources/{SuperconnectCore (FrameCodec/Transport/Session/InputCodec),
          SuperconnectProducer (VirtualDisplay/ScreenCapture/VideoEncoder/InputInjector),
          superconnect-app (the GUI app: App/ Models/ Services/ ViewModels/ Views/)}.
          build-app.sh → ~/Desktop/Superconnect.app. superconnect-probe = display/HDR diagnostics.
harmony/  HarmonyOS receiver. A COMPLETE DevEco project (scaffolding + media + source). Mirrors the
          Mac structure: entry/src/main/ets/{app,models,services,services/connection,services/wireless,
          services/discovery,input,session,transport,protocol,ui,components,pages}.
proto/    Wire spec + golden vectors + conformance harness (Swift/C++/ArkTS).
shared/   Portable C++ frame codec + tests (byte-identical to Swift/ArkTS).
tools/    check-protocol.sh (conformance), build/deploy/permission helpers, sc-loop.sh.
docs/     (see §2)
```

---

## 4. Build & run

### Mac host
- `cd mac && swift build` — compile-check (debug). Fast.
- `cd mac && ./build-app.sh` — universal (arm64 + x86_64) release → `~/Desktop/Superconnect.app`,
  signed with a **stable self-signed cert** (bootstrapped into a dedicated keychain) so Screen
  Recording / Accessibility grants persist across rebuilds. Bundles `hdc` + `libusb` under
  `Resources/hdc/<arch>/` so the app is self-contained (no DevEco needed on Apple Silicon).
- First launch: grant **Screen Recording + Accessibility** once. For **wireless**, macOS will prompt
  for **Local Network** access on the first LAN connect — must Allow.

### Tablet receiver (the painful part — signing)
- The repo `harmony/` is a complete DevEco project, BUT a **release-signed HAP cannot be hdc-sideloaded**
  on commercial HarmonyOS. Sideloading needs a **debug** signingConfig (lists the device UDID), which
  only DevEco's "Automatically generate signature" (Huawei login) can produce. The signing material is
  **not in the repo** (by design) and is **not recoverable from the CLI**.
- **Two project copies exist and can diverge**:
  - `Desktop/superconnect/harmony` = the git source of truth (bundle `com.superconnect.pad`).
  - `~/DevEcoStudioProjects/superconnect` = the buildable/signable copy (has the debug+release signing
    configs). **You must `rsync` the repo's `entry/src/main/ets/` + `module.json5` into it before building.**
- **CLI sideload recipe** (once the project's product `signingConfig` is `"debug"`):
  ```sh
  rsync -a harmony/entry/src/main/ets/ ~/DevEcoStudioProjects/superconnect/entry/src/main/ets/
  cp     harmony/entry/src/main/module.json5 ~/DevEcoStudioProjects/superconnect/entry/src/main/
  cd ~/DevEcoStudioProjects/superconnect
  export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
  export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
  export PATH=$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH
  hvigorw --no-daemon assembleHap -p product=default -p buildMode=debug   # (full path under tools/hvigor/bin)
  hdc -t <serial> install -r entry/build/default/outputs/default/entry-default-signed.hap
  hdc -t <serial> shell aa start -a EntryAbility -b com.superconnect.pad
  ```
  `hdc` lives at `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`.
  Or just hit **Run ▶** in DevEco. Switch the product back to the **release** signingConfig before any
  AppGallery upload.
- **No local ArkTS compile without DevEco** (the repo `harmony/` has no `ohpm`/`hvigor` deps installed).
  The DevEco-project `assembleHap` (`CompileArkTS`) is the real ArkTS type check.

### Conformance (run on every wire change)
- `bash tools/check-protocol.sh` — Swift + C++ + ArkTS all conform to `proto/vectors.json`. Must stay green.

---

## 5. Architecture (the seams that matter)

- The **Mac app is the reference architecture** (clean MVVM): `AppViewModel` is the only UI↔logic
  seam; `ConnectionCoordinator` is a **`[deviceID: ManagedConnection]` registry**; `DeviceDiscovery`
  sources feed a `DeviceStore`; `TunnelService` + `ConnectionEngine` (`HostConnection` real,
  `ReceiverConnection` stub) are injected via the composition root `App/AppEnvironment.swift`.
- The **tablet mirrors it file-for-file** (`app/AppEnvironment`, `services/ConnectionManager` ↔
  Coordinator, `services/connection/role/{Receiver,Host}Connection`, `input/`, `ui/`, `session/`,
  `transport/`).
- **Adding a transport** = a `Discovery` + a `TunnelService`/`Endpoint` case + one composition-root
  line. **Adding a role on a platform** = implement its `ConnectionEngine` + flip the `engineFor`
  factory. **A wire change** = edit `proto/` + all three codecs in the same commit (the harness enforces it).
- **Wireless module (v0.2.1)** is isolated: Mac `Services/Discovery/Wireless/{WirelessDiscovery,
  ManualDiscovery}.swift`; tablet `services/wireless/{WirelessService,PairingStore,MdnsAdvertiser}.ets`
  + `services/DeviceIdentity.ets`. It reuses the existing `DirectTunnel → TcpTransport → HostConnection`
  path. The wired path is byte-for-byte unchanged when wireless is off.

---

## 6. Status — what's DONE

- **v0.1.0 wired (on `main`, released):** full screencast Mac→tablet over USB/hdc; touch / pen
  (with real cross-app pressure via CGEvent tablet-proximity) / trackpad / physical+soft keyboard
  input; HiDPI; 120Hz; HEVC; rotation re-negotiation (#58); double-click; self-contained app +
  HAP. Caps-negotiated adaptation to any Huawei tablet.
- **#51 Phase 6 / Layer A — multi-device registry (on `main`, code-complete):** the Mac can host N
  tablets at once; per-device connect/disconnect; 3 shared-global hazards fixed (per-device hdc
  fport, process-global `DisplaySerial`, refcounted `DisplayModeGuard`). Zero wire change. **Not yet
  verified on-device with ≥2 tablets.**
- **Protocol (#49/#50):** conformance harness + backward-compatible v2 handshake.
- **v0.2.1 wireless (on `dev`, built + on-device smoke-tested, NOT on `main`):** Wi‑Fi LAN as an
  isolated module — tablet 无线模式 toggle (binds 0.0.0.0 + mDNS-advertises after listen succeeds),
  Mac auto-discovery (Bonjour) + manual-IP fallback, **TOFU pairing** (tap-to-allow, localhost/USB
  exempt, prompt bound to a monotonic promptId + clientId owner), Intel dual-dir hdc structure, real
  **device name** (deviceInfo.marketName) over mDNS + hello_ack, and **dynamic listen port** (prefer
  8888, fall back if occupied; advertised + shown). Two adversarial-review rounds applied. **On-device
  confirmed:** Mac connects wirelessly; Bonjour shows "HUAWEI MatePad Pro"; listens on the actual port.

---

## 7. Branch / release state

- **`main`** = `ecb87df` (verified, codex-reviewed). The released v0.1.0 + #51 Layer A live here.
- **`dev`** = `c9bcc59`, **9 commits ahead** of `main` — the entire v0.2.1 wireless feature + the
  name/dynamic-port additions. **Not pushed to `main` yet.**
- **Workflow rule (important):** do work on `dev` → **user verifies on-device** → only THEN advance
  `main` → codex reviews `main`. Do NOT advance `main` without explicit user verification.
- GitHub repo is public (`github.com/heeh02/superconnect`). `github.com:443` push is **flaky on this
  Mac** (likely GFW) — `.git/config` already has HTTP/1.1 + large postBuffer; retry loop usually works.

---

## 8. Known issues & risks

| # | Issue | Severity | Notes |
|---|-------|----------|-------|
| 1 | **Wireless transport is plaintext TCP**; TOFU trusts a cleartext `peerId` → a LAN sniffer could replay a trusted peerId. | Med (by design for beta) | TOFU still blocks *unapproved* devices. Real crypto (TLS / challenge-response) is **Phase 2**. `docs/WIRELESS.md` says "trusted Wi‑Fi only." |
| 2 | **#51 multi-device not verified on ≥2 tablets.** | Med | Code-complete on main. Verify: 2 independent extended displays, independent connect/disconnect, perf caption at 3, rotate-isolation, no display leak. Easier now with wired+wireless mix. |
| 3 | **Wired card shows serial, not the real name.** Real name shows only on the wireless (mDNS) path. | Low | Follow-up: capture `hello_ack` deviceName on the Mac and update `Device.name` for wired. |
| 4 | **Wired + dynamic port:** if 8888 is occupied on the tablet, the tablet falls back to another port but the Mac's wired (hdc) path assumes 8888 → wired fails (degrades to wireless). | Low | Acceptable corner; wireless carries the actual port via mDNS. |
| 5 | **USB hdc link is flaky** — drops between sessions; needs a data-cable replug. | Operational | Not our bug; HarmonyOS/USB. |
| 6 | **HDR shelved.** Full HDR transport is built+gated but `CGVirtualDisplay` can't be a real HDR source → gated OFF (SDR). | Known | Re-enable needs a DriverKit HDR virtual display (paid Apple acct). |
| 7 | **Intel self-containment incomplete:** `Resources/hdc/x86_64/` is empty (no x86_64 hdc binary). Intel falls back to system hdc or wireless. | Low | Drop an x86_64/universal hdc into `hdc/x86_64/` to finish. |

---

## 9. Pending / to-do

- **Push `dev` → `main`** once the user signs off on the wireless verification (then codex reviews).
- **#54 — trackpad usability defects** (P2): needs on-device repro/tuning.
- **#59 — v1 cross-platform host/receiver** (large endgame): per-platform Host/Receiver engines; the
  seams (`ConnectionEngine` + `Role` + 1-line factory) are already in place.
- **Wireless Phase 2** (deferred, documented): low-latency video channel (VIDEO over UDP/QUIC,
  CONTROL+INPUT over TCP) + adaptive bitrate + **real transport security** (fixes risk #1).
- **Multi-device Layer B** (reserved): `sessionId` mux on one byte stream (8-byte header, feature-gated
  by a `muxSessions` capability). Frame-flag bits intentionally NOT burned on it.
- Optional polish: wired-card real name (risk #3); finish Intel hdc (risk #7).

---

## 10. Critical operational gotchas

- **NEVER `pkill` a running Mac host / `Superconnect.app`** — SIGKILL skips `applicationWillTerminate`
  → the **CGVirtualDisplay LEAKS** in WindowServer (not reclaimed; needs logout/reboot). Always quit
  cleanly: `osascript -e 'quit app "Superconnect"'`, or let it exit via dropped connection.
- **Don't `aa start` / reinstall the tablet app against a LIVE session** unless deliberately deploying —
  it forces a Mac reconnect storm. Quit the Mac app first, then redeploy the tablet, then reopen.
- **Sync before building the tablet** — edit in the repo, then `rsync` ets + `module.json5` into the
  DevEco project (the two copies diverge silently otherwise).
- **`swift build` does NOT rebuild `Superconnect.app`** — only `build-app.sh` does. A stale running app
  won't have your changes until you rebuild + relaunch.
- **Secrets / PII must never be committed:** no signing keystore passwords, no Huawei account / real
  name / email / phone, no device serial. Signing material lives outside the repo; the repo's
  `signingConfigs` are intentionally empty (contributors use DevEco auto-sign). `.gitignore` covers
  signing material + build artifacts. (History was already PII-scrubbed once — keep it clean.)

---

## 11. Wireless verification checklist (gates the `main` push)

1. **Wired regression first:** USB connect → streams, and the tablet shows **no** pairing prompt.
2. **Manual IP:** tablet 无线模式 on → shows `ip:port` → Mac add-IP → connect → tablet prompts 允许 →
   allow → streams; reconnect is silent.
3. **mDNS auto:** tablet appears on the Mac by its **real name** with no manual entry → connect.
4. **Reject:** forget the peer (控制面板 → 已配对设备 → 移除) → reconnect → 拒绝 → Mac shows failed, **no**
   retry loop, tablet not re-prompted.
5. **Toggle off:** wireless off → tablet disappears from the Mac and is back to `127.0.0.1` only.
6. **(covers #51) Multi-device:** one wired + one wireless tablet simultaneously → two independent
   extended displays; disconnect one, the other is unaffected; `system_profiler SPDisplaysDataType |
   grep -c Resolution:` returns to built-in-only after disconnect-all (no leak).
