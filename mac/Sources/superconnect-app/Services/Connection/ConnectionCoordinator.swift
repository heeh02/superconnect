import Foundation
import Combine

/// Selects the connection engine for a role. Today `{ _ in HostConnection() }`. Going
/// symmetric = dispatch `.host`→HostConnection / `.receiver`→ReceiverConnection here,
/// touching no other file.
typealias RoleFactory = (Role) -> ConnectionEngine
/// Selects the tunnel for a transport (`.wired`→HdcFportTunnel, `.wireless`→DirectTunnel).
typealias TunnelFactory = (TransportKind) -> TunnelService

/// Owns the connect/disconnect/teardown lifecycle for EVERY connected device — a `deviceID`-keyed
/// registry, so multiple tablets can be live extended displays at once (#51 Layer A). Each entry is
/// an independent `(engine, tunnel)` pair with its own state + telemetry; connecting or disconnecting
/// one device never touches the others. Role- and transport-agnostic via the injected factories
/// (unit-testable with fakes). The wire is unchanged — the protocol is already transport-per-session.
///
/// Registry key = `Device.id` (the hdc serial today: the discovery/teardown/dedup key). The
/// v2-handshake `peerId` is the future cross-transport trust identity (`ARCHITECTURE.md` §5/§6) but
/// is only known after the handshake, so it can't key the registry at connect time.
final class ConnectionCoordinator: ObservableObject {
    /// Per-device connection state, keyed by `Device.id`. Absent ⇒ `.idle`.
    @Published private(set) var states: [String: ConnectionState] = [:]
    /// Per-device stream telemetry, keyed by `Device.id`.
    @Published private(set) var telemetry: [String: SessionTelemetry] = [:]

    private let tunnelFor: TunnelFactory
    private let engineFor: RoleFactory
    /// The injected cross-device conflict policy (single-active-per-physical-tablet). The coordinator
    /// asks and obeys; it never owns the predicate (keeps this registry a dumb, per-device-isolated
    /// store). See docs/CONFLICTS.md.
    private let policy: ConnectionPolicy

    /// One live link per device: the engine, its tunnel, and the subscriptions feeding `states`/`telemetry`.
    private final class ManagedConnection {
        let device: Device
        let engine: ConnectionEngine
        let tunnel: TunnelService
        var bag = Set<AnyCancellable>()
        /// The peer's cross-transport identity, learned from hello_ack telemetry (nil until confirmed).
        /// Used for Tier-2 reconciliation of the wired+wireless duplicate the connect-time policy can't
        /// pre-detect.
        var peerID: String?
        /// Monotonic connect order — the single-active sweep keeps the EARLIEST link per peer.
        let startSeq: Int
        init(device: Device, engine: ConnectionEngine, tunnel: TunnelService, startSeq: Int) {
            self.device = device; self.engine = engine; self.tunnel = tunnel; self.startSeq = startSeq
        }
    }
    private var conns: [String: ManagedConnection] = [:]
    private var connectSeq = 0

    init(tunnelFor: @escaping TunnelFactory, engineFor: @escaping RoleFactory, policy: ConnectionPolicy) {
        self.tunnelFor = tunnelFor
        self.engineFor = engineFor
        self.policy = policy
    }

    // MARK: - Queries

    /// Device ids with a live (connecting or connected) link.
    var connectedDeviceIDs: [String] { Array(conns.keys) }
    /// Number of live links — drives the advisory soft cap in the UI.
    var activeCount: Int { conns.count }
    func state(for id: String) -> ConnectionState { states[id] ?? .idle }

    // MARK: - Lifecycle (per device)

    /// Bring up a link for `device`. Idempotent (ignored if already live) and independent of every
    /// other connection — no longer tears anything else down.
    func connect(_ device: Device, as role: Role = .host) {
        guard conns[device.id] == nil else { return }
        diag("connect id=\(device.id) transport=\(device.transport) endpoint=\(device.endpoint)")

        // Cross-device conflict gate: refuse a connection to a physical tablet that already has a live
        // link (e.g. the same tablet shown as a second wireless card). SOFT — it only blocks a provable
        // same-device duplicate; distinct tablets always pass, so one Mac → many tablets is unaffected.
        if case .refuse(let reason) = policy.admit(device, against: liveLinkInfos()) {
            diag("admit REFUSED id=\(device.id) (\(reason)) — already connected to this tablet")
            states[device.id] = .blocked(reason)
            return
        }

        if let err = SystemPermissions.preflight(for: role) {
            states[device.id] = .needsPermission(err)
            return
        }

        let tunnel = tunnelFor(device.transport)
        let engine = engineFor(role)
        engine.setPairingToken(device.pairingToken)   // wireless BLE proximity token (nil otherwise)
        // Wireless targets dial over the physical NIC (exclude VPN/utun) so a VPN can't hijack the LAN
        // route; wired (hdc/loopback) keeps default routing.
        engine.setAvoidVirtualInterfaces(device.transport == .wireless)
        connectSeq += 1
        let mc = ManagedConnection(device: device, engine: engine, tunnel: tunnel, startSeq: connectSeq)
        conns[device.id] = mc
        states[device.id] = .connecting

        engine.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.states[device.id] = s }
            .store(in: &mc.bag)
        engine.telemetryPublisher?
            .receive(on: RunLoop.main)
            .sink { [weak self, weak mc] t in
                guard let self else { return }
                self.telemetry[device.id] = t
                // Tier-2: capture the peer's confirmed cross-transport identity (from hello_ack). Once
                // known, run the single-active sweep so the same physical tablet can't stay connected
                // over two transports. weak mc so the subscription in mc.bag doesn't retain-cycle the link.
                if let mc, let pid = t.peerId, !pid.isEmpty, mc.peerID != pid {
                    mc.peerID = pid
                    self.diag("peerId for id=\(device.id) = \(pid)")
                    self.enforceSingleActivePerPeer()
                } else if let mc, mc.peerID == nil, (t.peerId ?? "").isEmpty, t.resolution != "—" {
                    // Streaming but NO peerId arrived — log it: this is exactly the case that would
                    // defeat peer-based dedup (a tablet build not sending peerId in hello_ack).
                    self.diag("WARN id=\(device.id) streaming with EMPTY peerId — dedup can't match")
                }
            }
            .store(in: &mc.bag)

        Task { [weak self] in
            do {
                let target = try await tunnel.open(for: device.endpoint)
                // The user may have disconnected this device while the tunnel was opening. Only start
                // the engine if this exact connection is still the registered one — otherwise undo the
                // just-opened tunnel so we don't leave a zombie pipeline the registry no longer tracks.
                // We hand the engine a direction-neutral TunnelTarget; the engine (host/receiver) acts
                // on its own case, so this lifecycle stays role-agnostic. See docs/MODULARITY_AUDIT.md.
                DispatchQueue.main.async {
                    guard let self, self.conns[device.id] === mc else { tunnel.close(); return }
                    engine.start(over: target)
                }
            } catch {
                let appErr = (error as? AppError) ?? .tunnelFailed
                DispatchQueue.main.async {
                    // Drop the half-open entry (close the tunnel defensively) so the user can retry;
                    // keep the `.failed` state visible on the device's card. engine.start() never ran,
                    // so we must NOT call engine.disconnect() (it would unbalance the shared guard).
                    guard let self, self.conns[device.id] === mc else { return }
                    mc.bag.removeAll(); mc.tunnel.close()
                    self.conns[device.id] = nil
                    self.states[device.id] = .failed(appErr)
                    self.telemetry[device.id] = nil
                }
            }
        }
    }

    /// Tear down the link for one device. No-op if it isn't connected.
    func disconnect(deviceID id: String) {
        guard let mc = conns[id] else { return }
        mc.bag.removeAll()
        mc.engine.disconnect()
        mc.tunnel.close()
        conns[id] = nil
        states[id] = nil
        telemetry[id] = nil
    }

    /// Tear down every link (app teardown).
    func disconnectAll() {
        for id in Array(conns.keys) { disconnect(deviceID: id) }
    }

    /// Read-only projection of the live links for `ConnectionPolicy` (no internals leak out).
    private func liveLinkInfos() -> [LiveLinkInfo] {
        conns.values.map { mc in
            LiveLinkInfo(deviceID: mc.device.id, transport: mc.device.transport,
                         physicalKey: PhysicalKey.from(mc.device), peerID: mc.peerID)
        }
    }

    /// Tier-2 single-active enforcement. Once links report their cross-transport `peerId` (from
    /// hello_ack), at most ONE live link may exist per physical tablet. Group live links by `peerID`,
    /// keep the EARLIEST (incumbent), and tear down every later duplicate with `.blocked`. A full sweep
    /// (not pairwise) so it converges no matter the order peerIds arrive. This is the authoritative
    /// dedup for the wired+wireless-same-tablet case the connect-time policy can't pre-detect across the
    /// serial/host namespace gap. Main-thread only. See docs/CONFLICTS.md.
    private func enforceSingleActivePerPeer() {
        var keep: [String: ManagedConnection] = [:]   // peerID → earliest live link
        for mc in conns.values.sorted(by: { $0.startSeq < $1.startSeq }) {
            guard let pid = mc.peerID, !pid.isEmpty else { continue }
            if let held = keep[pid] {
                let dup = mc.device.id
                diag("dedupe: block id=\(dup) — same tablet (peer \(pid)) already held by id=\(held.device.id)")
                disconnect(deviceID: dup)                     // clears conns/states/telemetry for dup
                states[dup] = .blocked(.alreadyConnectedElsewhere)
            } else {
                keep[pid] = mc
            }
        }
    }

    /// Append a diagnostic line to /tmp/sc-mac-diag.log (shared with HostConnection/BLE/TCP). Self-bounding.
    private func diag(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = ("COORD: " + s + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    /// Apply a bitrate (Mbps) to every live engine — the global bitrate setting fans out to all
    /// connected tablets (and seeds a just-connecting one, whose engine reads it at producer build).
    func applyBitrate(_ mbps: Int) {
        for mc in conns.values { mc.engine.setBitrate(mbps) }
    }
}
