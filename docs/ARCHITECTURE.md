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

**Multiple receivers** = the connection lifecycle owner (`ConnectionCoordinator` / `ConnectionManager`)
holding a `Peer → Engine` map instead of a single link. Pure orchestration; the engine/tunnel/
discovery contracts don't change (Phase 9).

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

- **Layer A — connection-per-session (the chosen path):** multiple independent TCP/`hdc fport`
  connections, one `Session` each, keyed by `peerId` in an app-layer registry. The wire needs
  **nothing new** — the protocol is already transport-per-session. This is where multi-device
  actually arrives, with zero wire risk (suits a performance-limited host: fan out at the
  connection layer, not the wire).
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

## 7. Repo layout: source vs DevEco build

The mac side builds directly from this repo (`cd mac && swift build`). The HarmonyOS side in
`harmony/` is a **source snapshot** — it currently lacks the DevEco project scaffolding
(`build-profile.json5`, `hvigorfile.ts`, `oh-package.json5`) and the `media/` icon resources, so it
is **not standalone-buildable** yet (the working project lives in a local DevEco workspace). Making
`harmony/` a self-contained, `ohpm install`-able project is a tracked open-source-readiness task —
see **[`ROADMAP.md`](ROADMAP.md) §4**.
