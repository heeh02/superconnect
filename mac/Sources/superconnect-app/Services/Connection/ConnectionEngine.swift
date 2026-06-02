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
    /// Provide a wireless proximity-pairing token to present in the handshake (nil = none). Host-only.
    func setPairingToken(_ token: String?)
    /// For WIRELESS/LAN targets: dial over the physical interface, excluding virtual (VPN/utun) ones,
    /// so a VPN like EasyConnect can't hijack the LAN route. Off for wired (loopback). Host-only.
    func setAvoidVirtualInterfaces(_ avoid: Bool)
}

extension ConnectionEngine {
    /// Default: ignore — only a host engine encodes. The `ReceiverConnection` stub inherits this,
    /// so the symmetric-future engines need no edit; `HostConnection` overrides it.
    func setBitrate(_ mbps: Int) {}
    /// Default: ignore — only the host presents a pairing token in its `hello`.
    func setPairingToken(_ token: String?) {}
    /// Default: ignore — only the host dials out (and so cares about interface selection).
    func setAvoidVirtualInterfaces(_ avoid: Bool) {}
}
