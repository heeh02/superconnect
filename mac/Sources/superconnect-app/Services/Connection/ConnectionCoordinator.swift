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
        init(device: Device, engine: ConnectionEngine, tunnel: TunnelService) {
            self.device = device; self.engine = engine; self.tunnel = tunnel
        }
    }
    private var conns: [String: ManagedConnection] = [:]

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

        // Cross-device conflict gate: refuse a connection to a physical tablet that already has a live
        // link (e.g. the same tablet shown as a second wireless card). SOFT — it only blocks a provable
        // same-device duplicate; distinct tablets always pass, so one Mac → many tablets is unaffected.
        if case .refuse(let reason) = policy.admit(device, against: liveLinkInfos()) {
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
        let mc = ManagedConnection(device: device, engine: engine, tunnel: tunnel)
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
                // Tier-2: capture the peer's confirmed cross-transport identity (from hello_ack) and, if
                // it duplicates another live link, reconcile (tear down this newcomer). weak mc so the
                // subscription stored in mc.bag doesn't retain-cycle the connection.
                if let mc, let pid = t.peerId, !pid.isEmpty, mc.peerID != pid {
                    mc.peerID = pid
                    self.reconcile(confirmed: mc, peerID: pid)
                }
            }
            .store(in: &mc.bag)

        Task { [weak self] in
            do {
                let dial = try await tunnel.open(for: device.endpoint)
                // The user may have disconnected this device while the tunnel was opening. Only start
                // the engine if this exact connection is still the registered one — otherwise undo the
                // just-opened tunnel so we don't leave a zombie pipeline the registry no longer tracks.
                DispatchQueue.main.async {
                    guard let self, self.conns[device.id] === mc else { tunnel.close(); return }
                    engine.connect(host: dial.host, port: dial.port)
                }
            } catch {
                let appErr = (error as? AppError) ?? .tunnelFailed
                DispatchQueue.main.async {
                    // Drop the half-open entry (close the tunnel defensively) so the user can retry;
                    // keep the `.failed` state visible on the device's card. engine.connect() never ran,
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

    /// Tier-2 conflict resolution. Once a link's cross-transport `peerId` is confirmed, if ANOTHER live
    /// link already carries the same `peerId` they are the same physical tablet reached two ways (the
    /// wired+wireless duplicate the connect-time policy can't see across the serial/host namespace gap).
    /// Keep the incumbent, tear down this newcomer with `.blocked`. Belt-and-suspenders for the tablet's
    /// own single-active guard (and a safety net for an older tablet lacking it). Main-thread only.
    private func reconcile(confirmed mc: ManagedConnection, peerID: String) {
        let dupID = mc.device.id
        for other in conns.values where other !== mc && other.peerID == peerID {
            disconnect(deviceID: dupID)                       // clears states/telemetry/conns for dupID
            states[dupID] = .blocked(.alreadyConnectedElsewhere)
            return
        }
    }

    /// Apply a bitrate (Mbps) to every live engine — the global bitrate setting fans out to all
    /// connected tablets (and seeds a just-connecting one, whose engine reads it at producer build).
    func applyBitrate(_ mbps: Int) {
        for mc in conns.values { mc.engine.setBitrate(mbps) }
    }
}
