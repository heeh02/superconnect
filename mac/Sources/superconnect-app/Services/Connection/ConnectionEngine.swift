import Combine

/// What a live connection DOES, regardless of direction — so `ConnectionCoordinator` is
/// role-agnostic. `HostConnection` (capture + send) is real today; `ReceiverConnection`
/// (receive + display) is a stub. The dial target (host:port) is resolved by the
/// coordinator's `TunnelService` before `connect` is called. Telemetry is optional and
/// quarantined (host only).
protocol ConnectionEngine: AnyObject {
    var statePublisher: AnyPublisher<ConnectionState, Never> { get }
    var telemetryPublisher: AnyPublisher<SessionTelemetry, Never>? { get }
    func connect(host: String, port: UInt16)
    func disconnect()
}
