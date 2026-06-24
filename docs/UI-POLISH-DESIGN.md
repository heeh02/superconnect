# Superconnect UI-Polish Plan — Three Platforms, Strictly View-Layer

**Decoupling contract (verified against real code):** Every Mac View binds only to `AppViewModel`, which exposes zero service types (`AppViewModel.swift:9-21`, confirmed: no `Transport`/`Session`/`Producer`/`Process` in its surface). Every Harmony screen is a `@Component` fed props by `Index.ets`, which talks to services only via `ConnectionManager`/`AppEnvironment` (`Index.ets:77-140`). Android mirrors this in `MainActivity.kt`. **No change in this plan edits `Transport/`, `FrameCodec/`, `Session/`, `ConnectionCoordinator`, `ConnectionManager`, any `*Connection` engine, `WirelessService`, `InputRouter`/`PenHandler`/`KeyboardHandler`, or any discovery source.** The only non-View additions allowed are **read-only derived/`@Published` properties on the VM seam** (Mac `AppViewModel`, Harmony already keeps state in `Index.ets`), and these read existing data only — no new service calls.

---

## 1. Shared Visual Language (one spec, three native dialects)

A single token set, expressed in each platform's idiom. No new asset pipeline — all values are literals/SF Symbols/Material attrs.

### 1.1 Color — semantic, state-driven (single source of truth: `ConnectionState`)

The bug-prone part today is **color is duplicated**: `StatusDot.swift:7-15` and `TransportBadge` each map state→color independently. Unify into one helper so a state's color is defined once.

| Semantic role | Mac (SwiftUI) | Harmony (ArkUI) | Android (Material) |
|---|---|---|---|
| Connected / streaming | `.green` | `#34C759` | `colorPrimary` green tint |
| Connecting / transitional | `.orange` | `#FF9F0A` | amber |
| Available (idle, discovered) | `.blue` | `#0A84FF` | blue |
| Error / needs attention | `.red` | `#FF453A` | error red |
| Blocked / occupied | `.secondary` gray | `#8E8E93` | disabled gray |
| Paid accent (Supporter) | `.pink` | `Theme.accent` pink | pink |

**Mac action:** add `Color+State.swift` (new View-layer file under `Views/Components/`) with `extension ConnectionState { var dotColor: Color }` and reuse it in `StatusDot` + `TransportBadge`. This is pure View code, reads only the enum.

### 1.2 Spacing & typography — an 8pt grid

- **Section gap** 20 (Mac already uses this, `DeviceDetailView.swift:16`), **intra-group** 8, **inline** 6.
- Type ramp: title `.title2`/`.semibold` (header, `DeviceDetailView.swift:149`), section `.headline`, body `.callout`, hint `.caption`/`.tertiary`. Harmony: 22/17/15/13sp. Android: TextAppearance Headline6/Subtitle1/Body2/Caption.
- **Rule:** captions are always `.tertiary` (Mac) / 60% opacity (tablet) — never full-contrast — so the eye lands on controls first.

### 1.3 Iconography

- Mac: SF Symbols already in use (`display`, `ipad.landscape`, `wifi`, `bolt`, `lock.fill`). Standardize sizes (header 32, inline 16, badge caption). No new symbols required for quick wins.
- Tablet: keep emoji glyphs for the floating ball (✎/↖) but **add VoiceOver/a11y text labels** (currently absent — gap confirmed). View-layer attribute only.

---

## 2. Mac — Screens Redesigned (View files only)

### 2.1 Device list (sidebar) — `DashboardView.swift`
- **Bigger, unified status indicator.** Replace the 9×9 `StatusDot` in `SidebarRow` (`DashboardView.swift:107`) with a 12pt dot + the shared color helper; add `.help()` tooltip = state text. Pure View edit.
- **Truncation polish.** `name` is `lineLimit(1)` (`DashboardView.swift:108`) but un-styled — add `.truncationMode(.middle)` so long "HUAWEI MatePad Pro 13.2" reads better in the narrow 220pt sidebar.
- **Inline IP validation.** The wireless footer (`DashboardView.swift:63-73`) accepts anything; add a `@State` computed `isValidIP` in `DashboardView` (regex in the View) to disable 添加 + show a red hairline on malformed input. No VM change.

### 2.2 Detail pane — `DeviceDetailView.swift`
Today it's a flat stack of `GroupBox`es (画质/开机/会员/画面/权限/连接信息, `DeviceDetailView.swift:22-134`). Polish without restructuring services:
- **Quality presets.** Above the raw bitrate slider (`DeviceDetailView.swift:29`), add a SwiftUI `Picker(.segmented)` 流畅 / 高清 / 极致 that just sets `vm.bitrateMbps` to 25/50/80. The slider stays as the advanced control. Writes an existing `@Published` — no new VM surface.
- **Error differentiation.** `ConnectionToggle.swift:20-25` lumps `.needsPermission/.failed/.blocked` into one orange caption. Split presentation in the View: failed→show "重试" button (calls existing `vm.toggleConnection`), needsPermission→"打开系统设置" (existing `vm.requestPermissions`), blocked→explanatory text. **All actions already exist on the VM**; only the View branches.
- **Disconnect confirmation.** Wrap the disconnect path of `ConnectionToggle` in a `.confirmationDialog` when `state.isConnected`. View-only.

### 2.3 First-run / permissions — **new file** `Views/OnboardingView.swift`
Confirmed gap: permissions live buried in a `GroupBox` (`DeviceDetailView.swift:105-123`) with no first-run flow. The VM already exposes everything needed read-only: `screenRecordingOK`, `accessibilityOK` (`AppViewModel.swift:16-17`) and actions `requestPermissions()`, `regrantAccessibility()` (`AppViewModel.swift:203-215`).
- New `OnboardingView` shows a 2-step checklist (屏幕录制 / 辅助功能) with live ✓ as the VM's polled booleans flip (`AppViewModel.swift:196-201` already drives this).
- **Gating is View-layer:** add one read-only computed `var hostReady: Bool { screenRecordingOK && accessibilityOK }` on the VM (read-only, no service). `DashboardView` shows `OnboardingView` as an `.sheet` when `!vm.hostReady` and no device is connected.

### 2.4 会员 / paywall — `DeviceDetailView.swift` (`membership`, `:163-201`) + **new** `Views/Components/PaywallCard.swift`
- Extract the inline lock rows (`DeviceDetailView.swift:44-53`, `59-68`) into a reusable `PaywallCard` that renders `TierBadge` + perk list + the `accountVerified` seal (`AppViewModel.swift:56`) + a single CTA.
- The `#if DEBUG || SC_DEV_ENTITLEMENT` test buttons (`DeviceDetailView.swift:180-196`) stay exactly as-is — confirmed the only ship change is removing that barrier + swapping the provider in `AppEnvironment`, never a View edit.
- Reads only `vm.entitlements`, `vm.lowLatencyAvailable`, `vm.primaryDisplayAvailable`, `vm.accountVerified` — all existing read-only VM surface.

### 2.5 Empty / idle states — `EmptyStateView.swift`, `DashboardView.placeholder` (`:89-96`)
- `EmptyStateView` gains a 3-step "下一步" checklist (插上 USB 线 / 打开平板 / 开启无线模式). Static View text. No VM read needed.

**Mac files changed:** `DashboardView.swift`, `DeviceDetailView.swift`, `ConnectionToggle.swift`, `StatusDot.swift`, `TransportBadge.swift`, `EmptyStateView.swift` + **new** `Views/Components/Color+State.swift`, `Views/Components/PaywallCard.swift`, `Views/OnboardingView.swift`.
**VM additions (read-only, no service):** `var hostReady: Bool`. Everything else already exists.
**Confirmed untouched:** `AppEnvironment.swift`, `ConnectionCoordinator`, all of `Transport/`, `FrameCodec/`, `Session/`, `HostConnection`, discovery sources, `LoginItemService`, `EntitlementProvider` implementations.

---

## 3. Tablet — Harmony (ArkUI) Screens Redesigned

All state already lives in `Index.ets` `@State` (`Index.ets:30-62`); each screen is a prop-fed `@Component`. Polish = edit the `ui/` components + the props passed in `Index.build()`.

### 3.1 Connecting / connected / disconnected — `ui/IdleView.ets`, `ui/WindowedView.ets`, **new** `ui/StatusBanner.ets`
- The status model (`ConnectionStatus` + `statusLabel`/`statusColor`, used at `Index.ets:265, 272-273`) already maps state→label/color. Add a **transitional banner** component shown on `Failed`/`Listening` with "正在重连 [Mac 名]…" — fed by existing props. Peer name: pass `pairingName` (already in `Index.ets:51`) through.
- Animate the idle↔streaming transition (ArkUI `animateTo`) so the jump is less jarring (confirmed gap). View-only.

### 3.2 Pairing prompt — `ui/PairingDialog.ets`
- Add a sub-line "下次将自动信任此 Mac" so the TOFU one-time-trust model is clear (confirmed gap). It's pure text in the dialog; the trust persistence already happens in `WirelessService` via `respondPairing` (`Index.ets:344-347`) — **no service edit**.

### 3.3 Settings / cheat-sheet — `ui/ControlPanel.ets`
- Reorganize into a **"快捷开关" card on top** (drawing / pause input / hide ball — the `@Link`/callback toggles at `Index.ets:296-301`) then an **info card** (status/port/codec/IP) then cheat-sheets. Confirmed today they're intermixed. Pure layout reorder inside the component; same props.
- Add a **pro-mode badge** ("更跟手 已启用") driven by the existing `isLowLatency` state (`Index.ets:34, 97-100`) — pass it as a prop. Read-only.

### 3.4 Gesture hints / onboarding — **new** `ui/FirstRunHints.ets`
- A dismissible bubble shown once on first fullscreen entry (`enterFullscreen`, `Index.ets:170-174`) explaining ✎/↖ and double-tap. Persist "seen" via the existing prefs the panel already uses (a boolean key) — read/write a UI pref, not a service. Mounted as a conditional layer in `Index.build()`'s fullscreen branch alongside `FloatingBall` (`Index.ets:246-255`).

**Harmony files changed:** `ui/IdleView.ets`, `ui/WindowedView.ets`, `ui/ControlPanel.ets`, `ui/PairingDialog.ets`, `components/FloatingBall.ets` (a11y labels only), `pages/Index.ets` (wire new props + mount new components in `build()`) + **new** `ui/StatusBanner.ets`, `ui/FirstRunHints.ets`.
**Confirmed untouched:** `services/ConnectionManager.ets`, `app/AppEnvironment.ets`, `input/InputRouter.ets`, `KeyboardHandler`, `WirelessService`, `ReceiverConnection`, the `XComponent` surface mount (`Index.ets:216-220`) and the `ImeCatcher` mount gate (`Index.ets:225-226`) — both are the regression-sensitive seams and stay byte-identical.

> **Decoupling guardrail honored:** `Index.ets:101-126` documents the link-state↔display-mode separation that caused past keyboard regressions. None of the above touches `onStatus`, `ImeCatcher` mounting, or `InputOverlay` mounting — new components are additive overlay layers in `build()`.

---

## 4. Tablet — Android (Material) Screens Redesigned

Mirror Harmony. All UI is code-built in `MainActivity.kt` + `ControlPanel.kt` + `FloatingBall.kt` (confirmed no XML).
- **Status text → Material banner** for connecting/reconnecting, with peer name.
- **ControlPanel.kt** reorg into Quick-Settings card + info card (same `State`/`Callbacks` split, `ControlPanel.kt:28-45`).
- **Pairing AlertDialog** (`MainActivity.kt:379-391`) gains the auto-trust sub-text via `setMessage`.
- **First-run hint** overlay View added in `onCreate` fullscreen setup.
- **a11y:** `contentDescription` on `FloatingBall` glyphs.

**Android files changed:** `MainActivity.kt` (UI wiring + banner + first-run only), `ControlPanel.kt`, `FloatingBall.kt`.
**Confirmed untouched:** `InputRouter`, `KeyboardHandler`, `Session`, decoder, `wireless`.

---

## 5. Empty / Idle / Error State Matrix (all platforms)

| State | Mac | Tablet (both) |
|---|---|---|
| No device | `EmptyStateView` + 3-step next-steps | `IdleView` + USB/Wi-Fi how-to |
| Idle/available | blue dot + "可连接" | blue dot + IP:port shown |
| Connecting | orange dot + spinner | banner "连接中…" |
| Connected | green dot + telemetry | green; windowed→fullscreen hint |
| Needs permission | red + "打开系统设置" (`requestPermissions`) | n/a |
| Failed | red + "重试" (`toggleConnection`) | banner "正在重连 [Mac]…" |
| Blocked/occupied | gray + explanation | gray status |

All error copy already flows from `AppError.userMessage` (Mac, `ConnectionToggle.swift:22`) / `ConnectionStatus` (tablet). No new error plumbing.

---

## 6. First-Connect Onboarding Flow

1. **Mac launch** → if `!vm.hostReady`, `OnboardingView` sheet (permissions checklist, live ✓ from VM polling).
2. **Tablet launch** → `IdleView` shows USB-or-Wi-Fi how-to; first fullscreen → `FirstRunHints` bubble.
3. **First pair** → `PairingDialog`/`AlertDialog` with auto-trust sub-text.
All read-only against existing state; the only new VM surface is `hostReady` (derived from two existing booleans).

---

## 7. Phased Plan (quick wins first)

**Phase 0 — Tokens & dedupe (½ day, zero behavior change)**
- Mac: `Color+State.swift`, bump dot to 12pt, unify `StatusDot`/`TransportBadge` colors, `.help()` tooltips.
- Tablet: a11y labels on floating-ball glyphs.
- Lowest risk; touches only leaf View files.

**Phase 1 — High-impact polish (1–2 days)**
- Mac: quality-preset segmented picker; error differentiation + 重试/设置 buttons in `ConnectionToggle`; disconnect confirmation; sidebar truncation + IP validation.
- Tablet: `StatusBanner` (reconnect + peer name); `ControlPanel` reorg (Quick-Settings card); pairing auto-trust sub-text; pro-mode badge.

**Phase 2 — Onboarding & empty states (1–2 days)**
- Mac: `OnboardingView` sheet + `hostReady`; `EmptyStateView` next-steps.
- Tablet: `FirstRunHints` bubble; idle how-to copy; transition animations.

**Phase 3 — Paywall cohesion (1 day)**
- Mac: `PaywallCard` extraction (Supporter/全设备 perks + account seal + single CTA). Test buttons untouched behind `#if`.
- Tablet: pro-mode visibility surfaced in panel.

**Phase 4 — A11y & dark-mode audit (1 day)**
- Contrast check pink/orange/blue badges in dark mode; VoiceOver/TalkBack labels on dots, badges, dialog buttons.

---

## 8. Decoupling Confirmation (explicit)

- **NO** edits to: Mac `ConnectionCoordinator`, `AppEnvironment.swift`, `Transport/`, `FrameCodec/`, `Session/`, `HostConnection`, `DeviceStore`/discovery, `LoginItemService`, `EntitlementProvider` concrete types; Harmony `ConnectionManager.ets`, `AppEnvironment.ets`, `InputRouter.ets`, `KeyboardHandler`, `WirelessService`, `ReceiverConnection`, `XComponent`/`ImeCatcher` mount seams; Android `InputRouter`, `KeyboardHandler`, `Session`, decoder, wireless.
- **Only** new VM read-only surface: Mac `var hostReady: Bool` (derives from `screenRecordingOK && accessibilityOK`).
- Every behavior reuses an **existing** VM action (`toggleConnection`, `requestPermissions`, `regrantAccessibility`, `addManualWirelessDevice`) or existing prop/callback already wired in `Index.ets`/`MainActivity.kt`.
- The two historically regression-prone seams — Mac's `AppViewModel` isolation and Harmony's link-state↔display-mode + `ImeCatcher` mount gate — are left byte-identical; all new tablet UI is additive overlay layers in `build()`/`onCreate`.

This satisfies the hard modularity rule: a UI change here cannot break input, transport, or entitlement logic because it never imports or calls into those layers.
