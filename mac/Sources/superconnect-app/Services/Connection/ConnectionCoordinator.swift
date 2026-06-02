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

    /// One live link per device: the engine, its tunnel, and the subscriptions feeding `states`/`telemetry`.
    private final class ManagedConnection {
        let device: Device
        let engine: ConnectionEngine
        let tunnel: TunnelService
        var bag = Set<AnyCancellable>()
        init(device: Device, engine: ConnectionEngine, tunnel: TunnelService) {
            self.device = device; self.engine = engine; self.tunnel = tunnel
        }
    }
    private var conns: [String: ManagedConnection] = [:]

    init(tunnelFor: @escaping TunnelFactory, engineFor: @escaping RoleFactory) {
        self.tunnelFor = tunnelFor
        self.engineFor = engineFor
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

        if let err = SystemPermissions.preflight(for: role) {
            states[device.id] = .needsPermission(err)
            return
        }

        let tunnel = tunnelFor(device.transport)
        let engine = engineFor(role)
        engine.setPairingToken(device.pairingToken)   // wireless BLE proximity token (nil otherwise)
        let mc = ManagedConnection(device: device, engine: engine, tunnel: tunnel)
        conns[device.id] = mc
        states[device.id] = .connecting

        engine.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.states[device.id] = s }
            .store(in: &mc.bag)
        engine.telemetryPublisher?
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.telemetry[device.id] = t }
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

    /// Apply a bitrate (Mbps) to every live engine — the global bitrate setting fans out to all
    /// connected tablets (and seeds a just-connecting one, whose engine reads it at producer build).
    func applyBitrate(_ mbps: Int) {
        for mc in conns.values { mc.engine.setBitrate(mbps) }
    }
}
