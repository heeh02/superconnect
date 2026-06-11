# Free / Paid division & cross‑platform parity

Authoritative reference for **how versions are split (free vs paid)** and **what the free tier
must contain on every platform**. Open‑core: the free tier is fully usable on its own; paid is a
decoupled overlay. Update this doc whenever a feature crosses the boundary or a parity gap closes.

## 1. Open‑core boundary

| | Lives on | Contents |
|---|---|---|
| **Free** | `dev` / `main` (public `origin`) | Everything below in §2. Self‑contained: builds & runs with **no** entitlement code. |
| **Paid** | `private` / `auto_claude` (private remote) | Branches **from** `dev`, adds gated capabilities, **never merges back**. |

**Paid capabilities today** (code is private‑only): low‑latency **UDP video channel**
(`UdpVideo*`), the **entitlement / tier system** (`EntitlementProvider`, `Entitlements`,
`TierBadge`), **HDR10** (currently gated off). Tier structure (Free / Supporter / higher tiers) and
pricing live in the **private monetization plan**, not here.

**Rule:** a paid feature is reachable ONLY through `EntitlementProvider`. The free build wires
`FreeEntitlementProvider` (all paid off); a paid build wires the real provider (Huawei IAP later).
No `#if`‑style price checks scattered in feature code — one decoupled gate.

## 2. Free feature parity (cross‑platform)

Product = **Mac host** (free) + **receivers** (HarmonyOS = mature reference; Android = generic).
Free must be aligned across receivers. `✓` present · `△` partial · `✗` missing.

| Free capability | HarmonyOS | Android | Mac host |
|---|:--:|:--:|:--:|
| Wired connect | hdc | adb | both ✓ |
| Wireless mDNS (same subnet) | ✓ | ✓ | ✓ |
| Wireless BLE (cross‑subnet bootstrap) | ✓ | ✗ | ✓ |
| TOFU pairing | ✓ | ✓ | — |
| Manual IP | ✓ | ✓ | ✓ |
| H.264 / HEVC | ✓ | ✓ (device‑accurate advertise) | ✓ |
| Bitrate / codec control | (Mac) | (Mac) | ✓ (+force H.264) |
| Touch: tap/drag/2‑finger/pinch | ✓ | ✓ | injects ✓ |
| Pen / handwriting + palm‑reject | ✓ | ✓ (+finger‑as‑pen) | ✓ |
| Trackpad (relative cursor) | ✓ | ✗ (mouse→finger stopgap) | ✓ |
| Keyboard (physical + IME) | ✓ | ✓ | ✓ |
| Floating ball + control panel | ✓ | ✓ | (Mac UI) |
| Windowed mode (window ↔ fullscreen) | ✓ | ✗ (fullscreen only) | — |
| Polished states (idle / paused / exit‑fullscreen / restore handle) | ✓ | △ | — |

### Android free parity gaps (tracked)
1. **BLE advertiser** — cross‑subnet wireless auto‑discovery. _P1/P2_ (manual IP is the fallback).
2. **TrackpadHandler** — relative‑cursor for tablets w/ integrated trackpad. _P1_ (portable).
3. **Windowed mode** — small window vs fullscreen. _P2_ (OEM multi‑window dependent).
4. **Polished status UI** — idle page / paused banner / exit‑fullscreen toast / restore handle. _P2_.

Mac host free tier is well‑aligned (serves all receivers; wired hdc+adb, wireless mDNS+BLE+manual; no
paid leakage).

## 3. Versioning rule (free/paid)

- **Branches:** free → `dev`/`main` (public); paid → `private`/`auto_claude`. Paid is rebased on `dev`.
- **Gating:** all paid behind `EntitlementProvider`; free build = all‑off provider.
- **Releases:** each release = *free baseline* + *(optional) paid overlay*. Release notes state
  explicitly: “Free includes X · Paid (Supporter+) adds Y”.
- **Adding a feature:** decide free vs paid FIRST. Free → land on `dev`, update §2. Paid → land on
  `private` behind the gate, never touch `dev`’s feature code path.
- **One free version number across all three platforms**, bumped in lockstep (mac `Info.plist` ·
  harmony `AppScope/app.json5` · android `app/build.gradle.kts`). Packaging steps: `RELEASING.md`.
  Current free release: **0.2.0**.

## 4. Cross‑device installability (Android free)

The Android receiver must install & run on arbitrary Android 7+ devices, not just the dev phone:
- **Universal APK** — `minSdk 24`, **no native libs** → architecture‑independent (one APK, all ABIs).
- **Device‑accurate codecs** — advertise only decoders `MediaCodecList` reports → no HEVC black‑screen.
- **Stable release signing** — a fixed keystore (not the per‑machine debug key) so the APK is properly
  installable, updatable in place, and distributable. See `android/sign-release.md`.
- **App icon + label** — a real launcher icon (no generic default).
- OEM install guards (e.g. vivo’s “外部来源” confirm) are per‑device and unavoidable for sideload.
