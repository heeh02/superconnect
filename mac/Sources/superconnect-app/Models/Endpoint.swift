import Foundation

/// How a chosen device is actually reached. This is the transport-specific seam that
/// `TunnelService` / `ConnectionCoordinator` consume — it keeps the wired-vs-wireless
/// branch from leaking into the UI or view-model layers.
enum Endpoint: Hashable, Codable {
    /// Reached over USB through `hdc fport`; needs a tunnel that forwards a local port.
    case wiredHdc(serial: String, port: UInt16)
    /// Reached directly over TCP (LAN / Wi-Fi); dialed as-is, no tunnel.
    case tcp(host: String, port: UInt16)
}
