# Connection Conflicts & the Single-Active Rule

How superconnect decides **which connections may coexist** — and the modules that enforce it.
Written so v1 multi-device interconnect is built against one explicit contract instead of rediscovering
the rule per feature.

## The core constraint

A tablet is **structurally single-session**. The receiver has exactly:

- **one** hardware decoder — `g_ctx.decoder` (`harmony/.../cpp/napi_init.cpp`),
- **one** display surface — the `XComponent` (`harmony/.../pages/Index.ets`),
- **one** input back-channel slot — `currentSend` / `currentClientId` (`harmony/.../transport/TcpServerTransport.ets`).

So **two simultaneous streams into one tablet corrupt each other**: two independent H.264/HEVC
bitstreams (different GOP/SPS-PPS, possibly different resolution) interleave into the single decoder →
green/blocky garbage and repeated decoder stop/restart; input routes only to whichever Mac connected
last. This is *not cosmetic* — it is the observable "显示问题" when the same tablet is connected over
wired **and** wireless at once.

The Mac, by contrast, is genuinely **multi-session**: it can host **N different tablets** at once, each
with its own isolated virtual display + producer + tunnel (#51, "Layer A"). That capability must be
preserved. The rule is therefore **per-physical-tablet**, never global:

> **At most one active session per physical tablet. Different tablets are unrestricted.**

## Why the same tablet appears as several cards

A physical tablet is surfaced by independent discovery sources, each minting `Device.id` from a
disjoint namespace, so nothing collapses them today:

| Transport | `Device.id` | Source |
|-----------|-------------|--------|
| Wired | `<hdc serial>` | `WiredDiscovery` |
| Wireless mDNS | `mdns:<name>` | `WirelessDiscovery` |
| Wireless BLE | `ble:<uuid>` | `BleDiscovery` |
| Wireless manual | `manual:<host>:<port>` | `ManualDiscovery` |

`DeviceStore.merge` dedups on the exact `id` string only, so one tablet can show as up to **4 cards**.
The only stable cross-transport identity, `peerId`, is known **after** the handshake — so it cannot key
discovery or connect-time admission.

## Conflict matrix (the v1 contract)

| Combination | Verdict | Enforced where |
|---|---|---|
| One Mac → **N different** tablets | **ALLOW** (the multi-device goal) | distinct identity → policy `.allow`; per-device isolated pipelines (#51) |
| Reconnect same `Device.id` / retry after `.failed`/`.blocked` | **ALLOW** | coordinator idempotency guard; VM drops the stale entry first |
| Same tablet via 2–3 **wireless** cards (one Mac) | **BLOCK** | Mac `ConnectionPolicy` Tier-1 (same host) at connect time; tablet guard as backstop |
| Same tablet **wired + wireless** (one Mac) — *the reported bug* | **BLOCK** | **tablet single-active guard** (authoritative); Mac Tier-2 `peerId` reconcile cleans up the UI |
| One tablet ← **N different** Macs (fan-in) | **BLOCK** | **tablet single-active guard only** — neither Mac sees the other, so only the shared tablet can arbitrate |
| Two **distinct** tablets reached at the **same host** (NAT/port-forward, or two manual entries to one IP) | **soft-BLOCK at connect (accepted residual)** | Tier-1 keys on host-*without*-port, so they collapse to one key and the 2nd is refused. Harmless in practice: distinct LAN tablets have distinct IPs, and one `host:port` can't stream to two devices anyway. Re-adding port would regress the common "one tablet on two ports" de-dup, so we keep host-only keying |
| Same device as host **and** receiver (reversed roles) | **BLOCK / future (#59)** | one future `admit()` case in the policy — data, not a coordinator change |

## The modules that enforce it

Conflict enforcement is the first requirement that is inherently **cross-device** — connecting device A
must consider device B. Putting that predicate inline in `ConnectionCoordinator` would break its
"each entry is independent" contract and smear the rule across the four discovery sources, `Session`,
and the UI. So it lives in dedicated seams, one per platform:

### 1. Tablet single-active guard — the authoritative backstop

`harmony/.../transport/TcpServerTransport.ets`, at the **top** of `server.on('connect')`, **before**
`currentSend`/`currentClientId` are assigned (assigning first would clobber the live session's input
slot). If a client is already active (`currentClientId !== -1`), the newcomer is rejected: it is sent an
explicit `{type:"error", message:"session_busy"}` CONTROL frame and the socket is closed. `currentClientId`
returns to `-1` when the active client closes, so a later reconnect is accepted normally.

This is the only place "many Macs / many transports → one tablet" can be arbitrated (neither Mac sees the
other), it is transport-agnostic and un-bypassable, and it is a **no-op when wireless is off** (≤1 hdc
client). It closes the wired+wireless, multi-wireless-card, **and** N-distinct-Macs cases at once.

### 2. Mac `ConnectionPolicy` — the soft connect-time / UX layer

`mac/.../Services/Connection/ConnectionPolicy.swift` (+ `LiveLinkInfo.swift`), injected from
`AppEnvironment` exactly like `tunnelFor`/`engineFor`. The coordinator **asks and obeys**:
`policy.admit(device, against: liveLinks)` runs after the idempotency guard; `.refuse` sets
`.blocked(.alreadyConnectedElsewhere)` and never opens a tunnel.

**Soft by design** — it refuses **only** a provable same-device duplicate (Tier-1 `PhysicalKey`):
`serial(...)` for wired, `host(...)` (normalized) for wireless. On any ambiguity it returns `.allow`, so
two genuinely distinct tablets are **never** blocked. It catches the cheap, common case (the same tablet
shown as several wireless cards on one LAN host) before a tunnel/virtual-display is wasted.

### 3. Mac Tier-2 `peerId` reconcile — closes the namespace gap

`ConnectionCoordinator.reconcile(...)`, fed by the existing telemetry seam (`SessionTelemetry.peerId`,
populated from `hello_ack`). Once a link's `peerId` is confirmed, if another live link already has the
same `peerId` they are the same physical tablet reached two ways (the wired+wireless case Tier-1 cannot
pre-detect across the serial/host namespaces). The newcomer is torn down (KEEP-INCUMBENT). This is
belt-and-suspenders for the tablet guard and a safety net for an older tablet that lacks it.

`peerId` is **persisted** on both ends (Mac: `UserDefaults`; tablet: `@ohos.data.preferences` via
`DeviceIdentity.initStablePeerId`), so it is stable across relaunches and reliable as a routing key.

## Identity tiers (summary)

- **Tier-1 (connect-time, best-effort):** `PhysicalKey` from `Endpoint` — `serial` (wired) or normalized
  `host` (wireless). Cannot bridge wired↔wireless, and **cannot** bridge a BLE-advertised IPv4 against an
  mDNS-resolved IPv6 for one tablet (different address families). Those fall through to the tablet guard /
  Tier-2. Conservative: only an exact match means "same device" → no false-merge of distinct tablets.
- **Tier-2 (post-handshake, authoritative):** `peerId` from `hello_ack`, identical across transports.

## Known residuals (acceptable for v1)

- **Reconnect-lockout window:** after an *unclean* drop (crash / Wi-Fi loss), the tablet keeps the
  incumbent slot until its TCP close is detected; a same-tablet reconnect is rejected (`session_busy`)
  until then. Clean disconnects clear it immediately. A future peerId-aware *preempt* (replace a stale
  same-peer session) would close this; deferred because it depends on the tablet guard keying on `peerId`.
- **Tier-1 IPv4/IPv6 gap:** a BLE card and an mDNS card for one tablet may not collapse at connect time;
  the tablet guard + Tier-2 still block the duplicate, just a moment later.
- **Multi-card display:** the same tablet may still *show* as multiple cards (only connecting is blocked).
  Collapsing cards in `DeviceStore` keyed on `PhysicalKey` is an optional, low-risk future nicety.
- **Same-host distinct tablets:** Tier-1 keys on host-without-port (deliberately, to de-dup one tablet
  advertised on two ports), so two *genuinely distinct* tablets reached at the same host (exotic:
  NAT/port-forward) would be soft-refused. Accepted — distinct LAN tablets have distinct IPs.

## Wired-path safety

The proven wired (hdc) path is byte-for-byte unchanged: the tablet guard is a no-op with ≤1 client and
runs before the synchronous `127.0.0.1`-localhost branch; `pairingGate` stays `null` for wired; the Mac
policy returns `.allow` for a lone device; Tier-2 only *reads* the `peerId` the v2 handshake already
carries. No `proto/` / `FrameCodec` / hello-ack wire change.
