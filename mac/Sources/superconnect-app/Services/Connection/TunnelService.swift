import Foundation
import Darwin

/// The direction-typed result of opening a tunnel: WHERE the engine operates and HOW. This is the
/// seam that keeps connection DIRECTION out of the coordinator's lifecycle — the coordinator just
/// hands this to `engine.start(over:)` and the engine interprets its own case. Today every tunnel
/// yields `.dial` (host role dials out); a future receiver-side tunnel yields `.listen` (bind +
/// accept) and the receiver engine fills that branch — no coordinator change. See docs/MODULARITY_AUDIT.md.
enum TunnelTarget {
    case dial(host: String, port: UInt16)     // host role: dial OUT to this address
    case listen(host: String, port: UInt16)   // receiver role: BIND + accept here (future, #59)
}

/// Abstracts the local→peer plumbing so the engine's `start` is identical for wired and wireless.
/// Wired opens an `hdc fport` and yields `.dial(127.0.0.1:port)`; wireless yields the device's own
/// `.dial(host:port)` untouched. The factory pairs a tunnel with a role-matched engine, so direction
/// is chosen at composition time, never branched on in the lifecycle.
protocol TunnelService {
    func open(for endpoint: Endpoint) async throws -> TunnelTarget
    func close()
}

/// Real, built-now: forwards a local TCP port to the chosen device over USB. Each device gets its
/// OWN local port (allocated fresh per open) so several tablets can be forwarded at once without
/// colliding (#51); the device-side listen port is the same on every tablet (its own process).
final class HdcFportTunnel: TunnelService {
    private var opened: (serial: String, local: UInt16, remote: UInt16)?

    func open(for endpoint: Endpoint) async throws -> TunnelTarget {
        guard case let .wiredHdc(serial, remote) = endpoint else { throw AppError.tunnelFailed }
        guard HdcTool.path() != nil else { throw AppError.hdcNotFound }
        // `LocalPort.free()` picks a free port then RELEASES it; between that and `hdc fport` binding
        // it, another process can grab the port (a TOCTOU window) → fport fails. Retry up to 3× with a
        // fresh local port before giving up, so a transient race doesn't fail the whole connect.
        for _ in 0..<3 {
            let local = LocalPort.free() ?? remote   // unique per device; fall back to the remote port (single-device)
            if HdcTool.fport(serial: serial, local: local, remote: remote) {
                opened = (serial, local, remote)
                return .dial(host: "127.0.0.1", port: local)
            }
        }
        throw AppError.tunnelFailed
    }

    func close() {
        if let o = opened { HdcTool.killFport(serial: o.serial, local: o.local, remote: o.remote) }
        opened = nil
    }
}

/// Real, built-now: forwards a local TCP port to an ANDROID device over USB via `adb forward`. The
/// `adb` mirror of `HdcFportTunnel` — each device gets its own Mac-local port (#51), forwarded to the
/// Android receiver's fixed listen port. Selected by the factory for a `.wiredAdb` endpoint.
final class AdbFportTunnel: TunnelService {
    private var opened: (serial: String, local: UInt16, remote: UInt16)?

    func open(for endpoint: Endpoint) async throws -> TunnelTarget {
        guard case let .wiredAdb(serial, remote) = endpoint else { throw AppError.tunnelFailed }
        guard AdbTool.path() != nil else { throw AppError.hdcNotFound }   // reuse "bridge missing" error
        // Same TOCTOU guard as hdc: free()→forward window can race; retry with a fresh local port.
        for _ in 0..<3 {
            let local = LocalPort.free() ?? remote
            if AdbTool.forward(serial: serial, local: local, remote: remote) {
                opened = (serial, local, remote)
                return .dial(host: "127.0.0.1", port: local)
            }
        }
        throw AppError.tunnelFailed
    }

    func close() {
        if let o = opened { AdbTool.removeForward(serial: o.serial, local: o.local) }
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
    func open(for endpoint: Endpoint) async throws -> TunnelTarget {
        guard case let .tcp(host, port) = endpoint else { throw AppError.tunnelFailed }
        return .dial(host: host, port: port)
    }
    func close() {}
}
