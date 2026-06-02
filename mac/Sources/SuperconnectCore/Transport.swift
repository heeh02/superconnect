import Foundation
import Network

/// State of the underlying byte-stream link.
public enum TransportState: Equatable {
    case setup
    case ready
    case failed(String)
    case cancelled
}

/// L1 — the swap boundary. A Transport is *any* reliable, ordered,
/// bidirectional byte stream. Today the only impl is `TcpTransport`
/// (used for BOTH wired `hdc fport` over USB and future LAN/Wi-Fi).
/// Nothing above this layer knows or cares which physical link is underneath.
public protocol Transport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onStateChange: ((TransportState) -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func stop()
}

/// TCP implementation over Network.framework.
///
/// Wired (Phase 1):   connect to 127.0.0.1:<port>, with `hdc fport tcp:<port> tcp:<port>`
///                    tunnelling that port to the tablet over USB.
/// Wireless (Phase 4): connect to <tablet-ip>:<port> discovered via mDNS / BLE / manual.
/// Same class, same code path — only the host (and `avoidVirtualInterfaces`) changes.
public final class TcpTransport: Transport {
    public var onReceive: ((Data) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "superconnect.tcp")
    private let pinnedToPhysical: Bool
    private var watchdog: DispatchWorkItem?
    private var becameReady = false

    /// `avoidVirtualInterfaces` (set by the caller for WIRELESS/LAN targets): exclude virtual (VPN /
    /// utun) interfaces so a VPN such as EasyConnect — which routes the tablet's LAN IP into its tunnel
    /// — cannot hijack the connection; the socket then binds to the physical Wi-Fi/Ethernet path. It
    /// is IGNORED for loopback (hdc / 127.0.0.1 / ::1), where it would be both unnecessary and wrong.
    /// Deliberately NOT `requiredInterfaceType = .wifi`, so wired Ethernet stays a valid path.
    public init(host: String, port: UInt16, avoidVirtualInterfaces: Bool = false) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        // Low latency: disable Nagle so small input/control frames go out immediately.
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        let loopback = TcpTransport.isLoopback(host)
        let pin = avoidVirtualInterfaces && !loopback
        if pin {
            // BIND the socket to the physical interface (Wi-Fi or Ethernet), which forces that
            // interface's SCOPED routing table — where the LAN target is reachable via the normal
            // gateway — instead of the global table (where a VPN's more-specific route to the LAN IP
            // points at utun). This inherently excludes the VPN tunnel. NOTE: prohibitedInterfaceTypes
            // = [.other] alone does NOT work here — the global route still resolves to utun, so the
            // path just goes .unsatisfied (verified on-device). requiredInterface is the real fix, and
            // it's adaptive (Wi-Fi OR Ethernet) — never a hardcoded .wifi.
            if let iface = TcpTransport.physicalInterface() {
                params.requiredInterface = iface
                TcpTransport.diag("pin requiredInterface=\(iface.name) type=\(iface.type)")
            } else {
                params.prohibitedInterfaceTypes = [.other]   // last-resort fallback
                TcpTransport.diag("no physical iface found → fell back to prohibit(.other)")
            }
        }
        self.pinnedToPhysical = pin
        connection = NWConnection(host: endpointHost, port: endpointPort, using: params)
        TcpTransport.diag("init host=\(host) port=\(port) avoidVirtual=\(avoidVirtualInterfaces) loopback=\(loopback) prohibit(.other)=\(pin)")
    }

    public func start() {
        startWatchdog()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becameReady = true
                self.watchdog?.cancel()
                TcpTransport.diag("ready \(self.pathInfo())")
                self.onStateChange?(.ready)
                self.receiveLoop()
            case .failed(let error):
                self.watchdog?.cancel()
                TcpTransport.diag("failed: \(error.localizedDescription) \(self.pathInfo())")
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.watchdog?.cancel()
                self.onStateChange?(.cancelled)
            case .waiting(let error):
                // No satisfiable path yet. When `.other` is prohibited on a FULL-tunnel VPN (no physical
                // route to the LAN at all), this can persist — the watchdog surfaces it as a failure.
                TcpTransport.diag("waiting: \(error.localizedDescription) \(self.pathInfo())")
                self.onStateChange?(.setup)
            case .setup, .preparing:
                self.onStateChange?(.setup)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onStateChange?(.failed(error.localizedDescription)) }
        })
    }

    public func stop() {
        watchdog?.cancel()
        connection.cancel()
    }

    // MARK: - internals

    /// Fail fast (instead of hanging in `.waiting`) if no path establishes — and log a clear hint for
    /// the full-tunnel case where excluding virtual interfaces leaves no usable route.
    private func startWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.becameReady else { return }
            let hint = self.pinnedToPhysical
                ? "no physical-LAN route — a full-tunnel VPN may be capturing all traffic (excluded .other left no path)"
                : "connection did not become ready"
            TcpTransport.diag("connect timeout: \(hint) \(self.pathInfo())")
            self.onStateChange?(.failed("connect timeout: \(hint)"))
            self.connection.cancel()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// Which interface the connection actually resolved to — confirms the VPN was avoided. Uses
    /// `connection.currentPath` (compile-valid across SDKs) rather than a path handler.
    private func pathInfo() -> String {
        guard let p = connection.currentPath else { return "path=nil" }
        return "path[status=\(p.status) wifi=\(p.usesInterfaceType(.wifi)) eth=\(p.usesInterfaceType(.wiredEthernet)) other=\(p.usesInterfaceType(.other))]"
    }

    private static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "localhost" || h == "::1" || h == "::ffff:127.0.0.1" || h.hasPrefix("127.")
    }

    /// The physical (non-virtual) interface to bind a LAN connection to — preferring Wi-Fi, then
    /// wired Ethernet, then any non-virtual/non-loopback/non-cellular interface. Discovered via a
    /// one-shot NWPathMonitor (resolves near-instantly; bounded 0.6s wait so a retry burst — every
    /// 1.5s — never stalls the lifecycle thread for long). The result is cached for a short TTL so
    /// repeated dials reuse it instead of re-probing each time; a Wi-Fi↔Ethernet switch is picked up
    /// once the TTL lapses. Returns nil only if nothing resolves and nothing was ever cached — caller
    /// then falls back. This is what lets the socket use the physical interface's scoped routing,
    /// bypassing a VPN that hijacks the global route to the LAN IP.
    private static let cacheLock = NSLock()
    private static var cachedInterface: NWInterface?
    private static var cachedAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 10

    private static func physicalInterface() -> NWInterface? {
        cacheLock.lock()
        if let c = cachedInterface, Date().timeIntervalSince(cachedAt) < cacheTTL {
            cacheLock.unlock(); return c
        }
        cacheLock.unlock()

        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var iface: NWInterface?
        monitor.pathUpdateHandler = { path in
            iface = path.availableInterfaces.first(where: { $0.type == .wifi })
                ?? path.availableInterfaces.first(where: { $0.type == .wiredEthernet })
                ?? path.availableInterfaces.first(where: { $0.type != .other && $0.type != .loopback && $0.type != .cellular })
            sem.signal()
        }
        monitor.start(queue: DispatchQueue(label: "superconnect.pathprobe"))
        _ = sem.wait(timeout: .now() + 0.6)
        monitor.cancel()

        cacheLock.lock()
        if let iface { cachedInterface = iface; cachedAt = Date() }
        let result = iface ?? cachedInterface   // probe timed out → reuse last-known rather than nil
        cacheLock.unlock()
        return result
    }

    /// Append a diagnostic line to /tmp/sc-mac-diag.log (shared with the app's BLE/host diag). Self-bounding.
    private static func diag(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = ("TCP: " + s + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }
}
