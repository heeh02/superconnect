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
    /// Adjust the encode bitrate (Mbps) of a live link. Host-only; see the default below.
    func setBitrate(_ mbps: Int)
}

extension ConnectionEngine {
    /// Default: ignore — only a host engine encodes. The `ReceiverConnection` stub inherits this,
    /// so the symmetric-future engines need no edit; `HostConnection` overrides it.
    func setBitrate(_ mbps: Int) {}
}
