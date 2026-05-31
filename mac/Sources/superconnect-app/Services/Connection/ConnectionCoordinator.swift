import Foundation
import Combine

/// Selects the connection engine for a role. Today `{ _ in HostConnection() }`. Going
/// symmetric = dispatch `.host`→HostConnection / `.receiver`→ReceiverConnection here,
/// touching no other file.
typealias RoleFactory = (Role) -> ConnectionEngine
/// Selects the tunnel for a transport (`.wired`→HdcFportTunnel, `.wireless`→DirectTunnel).
typealias TunnelFactory = (TransportKind) -> TunnelService

/// Owns the full connect/disconnect/retry/teardown lifecycle for the ONE chosen device.
/// Role- and transport-agnostic: it only knows the `ConnectionEngine` / `TunnelService`
/// protocols and the injected factories, so it's unit-testable with fakes (no real
/// display / USB) and the symmetric future is a composition-root edit.
final class ConnectionCoordinator: ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var telemetry: SessionTelemetry?
    private(set) var connectedDeviceID: String?

    private let tunnelFor: TunnelFactory
    private let engineFor: RoleFactory
    private var engine: ConnectionEngine?
    private var tunnel: TunnelService?
    private var bag = Set<AnyCancellable>()

    init(tunnelFor: @escaping TunnelFactory, engineFor: @escaping RoleFactory) {
        self.tunnelFor = tunnelFor
        self.engineFor = engineFor
    }

    func connect(_ device: Device, as role: Role = .host) {
        disconnect()

        if let err = SystemPermissions.preflight(for: role) {
            state = .needsPermission(err)
            return
        }

        state = .connecting
        connectedDeviceID = device.id

        let tunnel = tunnelFor(device.transport)
        let engine = engineFor(role)
        self.tunnel = tunnel
        self.engine = engine

        engine.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.state = s }
            .store(in: &bag)
        engine.telemetryPublisher?
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.telemetry = t }
            .store(in: &bag)

        Task { [weak self] in
            do {
                let dial = try await tunnel.open(for: device.endpoint)
                engine.connect(host: dial.host, port: dial.port)
            } catch {
                let appErr = (error as? AppError) ?? .tunnelFailed
                DispatchQueue.main.async { self?.state = .failed(appErr) }
            }
        }
    }

    func disconnect() {
        bag.removeAll()
        engine?.disconnect(); engine = nil
        tunnel?.close(); tunnel = nil
        connectedDeviceID = nil
        telemetry = nil
        state = .idle
    }
}
