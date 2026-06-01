# Superconnect — Architecture (code-structure contract)

This is the **living contract for how the code is organized** across the two apps. It is the
counterpart to `proto/` (the wire source-of-truth): `proto/` defines the *bytes on the wire*,
this document defines *where code lives and what the interfaces are*.

> `docs/DESIGN.md` is the frozen v0.1 research/decision log (some folders it proposed — ChannelMux/
> Display/Capture — were never built). Treat DESIGN.md as history; treat **this file as current**.

---

## 1. The vocabulary (six concepts, identical on both platforms)

The macOS app is the reference architecture. These six concepts exist on **both** sides, each in
its native idiom (Swift `protocol` / ArkTS `interface`). Use the **same names** everywhere.

| Concept | Meaning | macOS (Swift) | HarmonyOS (ArkTS) |
|---|---|---|---|
| **Peer / Device** | a remote endpoint: stable id + capabilities + how it's reached | `Models/Device.swift` | `models/Peer.ets` |
| **Role** | direction of a live link: `host` (cast out) / `receiver` (be cast to) | `Models/Role.swift` | `models/Role.ets` |
| **RoleCapabilities** | what a peer *can* do: `canHost` / `canReceive` / `both` | `Models/Role.swift` | `models/Role.ets` |
| **TransportKind / Endpoint** | *how* a peer is reached: `wired`/`wireless`; `wiredHdc`/`tcp` | `Models/TransportKind.swift`, `Endpoint.swift` | `models/Peer.ets` |
| **Discovery** | long-lived source publishing the current `[Peer]` for one TransportKind | `Services/Discovery/*` | `services/discovery/*` |
| **Connection / Session / Transport** | lifecycle owner → live engine → byte pipe | `Services/Connection/*`, `Core/Session`, `Core/Transport` | `services/connection/*`, `session/Session`, `transport/*Transport` |

### Two "Transport"s — do not conflate
- **Transport** = the **byte pipe** (TCP). `SuperconnectCore/Transport.swift`, `transport/TcpServerTransport.ets`.
- **TransportKind** = the **enum** `{ wired, wireless }` used by Discovery and the badge.

Rule: *Transport = byte pipe; TransportKind = the wired/wireless enum; never call Discovery a "transport."*

---

## 2. Layer → folder mirror

| Layer | macOS | HarmonyOS |
|---|---|---|
| L0–L1 byte transport | `SuperconnectCore/Transport.swift` | `transport/*Transport.ets` |
| L2 session / handshake | `SuperconnectCore/Session.swift` | `session/Session.ets` |
| L3 protocol / codecs | `SuperconnectCore/{FrameCodec,InputCodec}.swift` | `protocol/{FrameCodec,InputCodec}.ets` |
| L4 role pipelines | `SuperconnectProducer/*` (+ future `SuperconnectConsumer`) | `pipeline/` + `cpp/` (native decode/render) |
| connection lifecycle | `Services/Connection/{ConnectionCoordinator,ConnectionEngine,TunnelService,Role/*}` | `services/connection/{ConnectionManager,ConnectionEngine,TunnelService,role/*}` |
| discovery | `Services/Discovery/*` | `services/discovery/*` |
| models / vocabulary | `Models/*` | `models/*` |
| app seam (view-model) | `ViewModels/AppViewModel.swift` | `services/ConnectionManager` + page `@State` |
| UI | `Views/*` | `pages/Index.ets` + `ui/*` + `components/*` |
| composition root | `App/AppEnvironment.swift` | `app/AppEnvironment.ets` |
| input capture (receiver) | n/a (Mac is host today) | `input/*` (router + pen/trackpad/keyboard handlers) |

---

## 3. The Role × Platform matrix (what's real vs a seam)

The symmetric end-state ("any device can host or receive; multiple receivers") is a matrix of
`(Role × Platform)`. Each cell is an independent implementation behind a shared interface.

| | **Host** (cast out) | **Receiver** (be cast to) |
|---|---|---|
| **macOS** | ✅ REAL — `HostConnection` + `SuperconnectProducer` | �stub — `ReceiverConnection` → `.receiverNotSupported` (Phase 7 = new `SuperconnectConsumer`) |
| **HarmonyOS** | �stub — `HostConnection.ets` → not-supported (Phase 8 = capture/encode pipeline + dial-out) | ✅ REAL — `ReceiverConnection.ets` (decode → XComponent, input → INPUT frames) |

Note the **mirror symmetry**: each platform has exactly one real role engine and one stub, on
*opposite* sides. Selecting the engine is a **one-line edit in the composition root** (`engineFor(role)`).

**Multiple connections** = the connection lifecycle owner (`ConnectionCoordinator` / `ConnectionManager`)
holding a `deviceID → Engine` map instead of a single link. Pure orchestration; the engine/tunnel/
discovery contracts don't change. **Built for hosting (#51 / Layer A)** — the Mac drives N tablets at
once; the symmetric *receiver* side (Mac being cast to by several hosts) is the same map once a real
`SuperconnectConsumer` exists (Phase 9).

---

## 4. Where new code goes (the rule)

- **A new transport (e.g. Wi‑Fi/LAN)** = a new `Discovery` impl + a `TunnelService`/`Endpoint` case +
  **one line** in the composition root. No caller changes. (On the tablet, the listen address
  `127.0.0.1` vs `0.0.0.0` is the wired-vs-wireless seam.)
- **A new role on a platform** = implement the `ConnectionEngine` for that cell + flip the
  `engineFor(role)` factory line. No coordinator/UI changes.
- **A protocol change** = edit `proto/protocol.md` **and** `proto/vectors.json` **and** all three
  codecs **in the same commit** (the conformance suite enforces this).

---

## 5. Multi-device transport strategy

- **Layer A — connection-per-session (the chosen path, ✅ built #51):** multiple independent
  TCP/`hdc fport` connections, one `Session` each, keyed by `Device.id` in an app-layer registry
  (`ConnectionCoordinator` holds `[deviceID: ManagedConnection]`; each owns its own `HostConnection`
  → `CGVirtualDisplay` + capture + encode + injector). The wire needs **nothing new** — the protocol
  is already transport-per-session (the conformance suite passes unchanged). Three shared-globals were
  made multi-safe: each device gets its **own local `hdc fport`** port (the tablet's listen port is the
  *remote*), `CGVirtualDisplay` serials come from a **process-global allocator** (`DisplaySerial`) so
  N displays never share an identity, and one **refcounted `DisplayModeGuard.shared`** snapshots the
  real displays once before any virtual display. Connecting/disconnecting one device is independent of
  the others; an advisory soft cap (2) warns about perf on a limited host but never blocks. The key is
  `Device.id` (hdc serial) today; the v2 `peerId` is the future cross-transport identity (§6).
  This is where multi-device actually arrives, with zero wire risk.
- **Layer B — multiplexed logical sessions on one byte stream (reserved, not built):** would add
  `sessionId:u16` to an 8-byte frame header + `session_start`/`session_end` control messages,
  **feature-gated** by a `muxSessions` capability so two peers only switch to the 8-byte header
  when both advertise it (never a flag day). Documented to reserve the evolution path; do **not**
  burn the `0x04`/`0x08` frame-flag bits on it.

---

## 6. Backward-compatible protocol evolution (v2)

`protocolVersion` bumps to 2, but **a v2 peer must accept a v1 peer by treating absent fields as
v1 defaults** (initiator = host, responder = receiver — exactly today's Mac-host/tablet-receiver
behavior). New, all optional: `peerId` (UUID, persisted per install — the trust/routing key, not a
transport address), `deviceName`, `platform`, `appVersion`, `desiredRole`/`supportedRoles`/
`acceptedRole`, role-keyed `caps`, and a resendable `caps_update`. The 44-byte INPUT record is **not**
resized — the dead `reserved:u16` becomes `pointerId:u16` (legacy senders already write `0`).

---

## 7. Repo layout: building each side

The mac side builds directly from this repo (`cd mac && swift build`). The HarmonyOS side in
`harmony/` is a **complete, self-contained DevEco Studio project** (scaffolding + `media/` icons +
all source) — open it in DevEco, `ohpm install`, and build. Signing is intentionally empty
(`build-profile.json5` → `signingConfigs: []`, no certs/keys/passwords committed); contributors
enable DevEco's **automatic signing** with their own Huawei developer identity. The app bundle id
is `com.superconnect.pad`.
