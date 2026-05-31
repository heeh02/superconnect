import Foundation

/// Abstracts the local→peer plumbing so `connect` is identical for wired and wireless.
/// Wired opens an `hdc fport` and returns 127.0.0.1:port; wireless returns the device's
/// own host:port untouched.
protocol TunnelService {
    func open(for endpoint: Endpoint) async throws -> (host: String, port: UInt16)
    func close()
}

/// Real, built-now: forwards a local TCP port to the chosen device over USB.
final class HdcFportTunnel: TunnelService {
    private var opened: (serial: String, port: UInt16)?

    func open(for endpoint: Endpoint) async throws -> (host: String, port: UInt16) {
        guard case let .wiredHdc(serial, port) = endpoint else { throw AppError.tunnelFailed }
        guard HdcTool.path() != nil else { throw AppError.hdcNotFound }
        guard HdcTool.fport(serial: serial, port: port) else { throw AppError.tunnelFailed }
        opened = (serial, port)
        return ("127.0.0.1", port)
    }

    func close() {
        if let o = opened { HdcTool.killFport(serial: o.serial, port: o.port) }
        opened = nil
    }
}

/// Wireless pass-through stub: a LAN/Wi-Fi device is dialed directly, no tunnel.
final class DirectTunnel: TunnelService {
    func open(for endpoint: Endpoint) async throws -> (host: String, port: UInt16) {
        guard case let .tcp(host, port) = endpoint else { throw AppError.tunnelFailed }
        return (host, port)
    }
    func close() {}
}
