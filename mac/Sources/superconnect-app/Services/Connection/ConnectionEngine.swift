import Combine

/// What a live connection DOES, regardless of direction — so `ConnectionCoordinator` is
/// role-agnostic. `HostConnection` (capture + send) is real today; `ReceiverConnection`
/// (receive + display) is a stub. `start(over:)` is DIRECTION-NEUTRAL: the coordinator resolves a
/// `TunnelTarget` (via `TunnelService`) and hands it over; a host engine acts on `.dial`, a future
/// receiver engine on `.listen`. The lifecycle never branches on direction. Telemetry is optional
/// and quarantined (host only). See docs/MODULARITY_AUDIT.md.
protocol ConnectionEngine: AnyObject {
    var statePublisher: AnyPublisher<ConnectionState, Never> { get }
    var telemetryPublisher: AnyPublisher<SessionTelemetry, Never>? { get }
    func start(over target: TunnelTarget)
    func disconnect()
    /// Adjust the encode bitrate (Mbps) of a live link. Host-only; see the default below.
    func setBitrate(_ mbps: Int)
    /// Provide a wireless proximity-pairing token to present in the handshake (nil = none). Host-only.
    func setPairingToken(_ token: String?)
    /// For WIRELESS/LAN targets: dial over the physical interface, excluding virtual (VPN/utun) ones,
    /// so a VPN like EasyConnect can't hijack the LAN route. Off for wired (loopback). Host-only.
    func setAvoidVirtualInterfaces(_ avoid: Bool)
    /// Re-establish the underlying tunnel (re-run the USB port-forward) and yield a FRESH dial target
    /// before each reconnect attempt — so a WIRED link self-heals when the forward was cleared (USB
    /// hiccup / adb-server restart): the old retry reconnected the socket to a now-dead local port and
    /// looped on "Connection refused" forever. nil result ⇒ keep the current target. Wireless reopen is
    /// a no-op (same host:port). Host-only; the receiver stub inherits the no-op default.
    func setTunnelReopen(_ reopen: (() async -> TunnelTarget?)?)
    /// Force a reconnect on system WAKE. Across sleep the SCStream dies and the CGVirtualDisplay is
    /// invalidated without raising any TCP/producer error, so the passive heartbeat is slow (or, on a
    /// half-open socket, never) to notice. The coordinator fans this out to every live link on
    /// NSWorkspace.didWake; the engine rebuilds a FRESH display + capture. No-op when not live.
    func wakeReconnect()
}

extension ConnectionEngine {
    /// Default: ignore — only a host engine encodes. The `ReceiverConnection` stub inherits this,
    /// so the symmetric-future engines need no edit; `HostConnection` overrides it.
    func setBitrate(_ mbps: Int) {}
    /// Default: ignore — only the host presents a pairing token in its `hello`.
    func setPairingToken(_ token: String?) {}
    /// Default: ignore — only the host dials out (and so cares about interface selection).
    func setAvoidVirtualInterfaces(_ avoid: Bool) {}
    /// Default: ignore — only the host dials out, so only it needs to re-establish a wired tunnel.
    func setTunnelReopen(_ reopen: (() async -> TunnelTarget?)?) {}
    /// Default: ignore — a stub engine has nothing to rebuild on wake.
    func wakeReconnect() {}
}
