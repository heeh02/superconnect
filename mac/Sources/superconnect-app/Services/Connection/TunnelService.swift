import Foundation
import Darwin

/// Abstracts the local→peer plumbing so `connect` is identical for wired and wireless.
/// Wired opens an `hdc fport` and returns 127.0.0.1:port; wireless returns the device's
/// own host:port untouched.
protocol TunnelService {
    func open(for endpoint: Endpoint) async throws -> (host: String, port: UInt16)
    func close()
}

/// Real, built-now: forwards a local TCP port to the chosen device over USB. Each device gets its
/// OWN local port (allocated fresh per open) so several tablets can be forwarded at once without
/// colliding (#51); the device-side listen port is the same on every tablet (its own process).
final class HdcFportTunnel: TunnelService {
    private var opened: (serial: String, local: UInt16, remote: UInt16)?

    func open(for endpoint: Endpoint) async throws -> (host: String, port: UInt16) {
        guard case let .wiredHdc(serial, remote) = endpoint else { throw AppError.tunnelFailed }
        guard HdcTool.path() != nil else { throw AppError.hdcNotFound }
        let local = LocalPort.free() ?? remote   // unique per device; fall back to the remote port (single-device)
        guard HdcTool.fport(serial: serial, local: local, remote: remote) else { throw AppError.tunnelFailed }
        opened = (serial, local, remote)
        return ("127.0.0.1", local)
    }

    func close() {
        if let o = opened { HdcTool.killFport(serial: o.serial, local: o.local, remote: o.remote) }
        opened = nil
    }
}

/// Picks a free localhost TCP port by binding an ephemeral socket to `127.0.0.1:0`, reading the
/// OS-assigned port, then releasing it. Gives each wired device its own Mac-local fport (#51).
enum LocalPort {
    static func free() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0   // 0 ⇒ OS assigns a free ephemeral port
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        let port = UInt16(bigEndian: addr.sin_port)
        return port == 0 ? nil : port
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
