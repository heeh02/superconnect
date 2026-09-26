import Foundation
import Network

/// State of the underlying byte-stream link.
public enum TransportState: Equatable {
    case setup
    case ready
    case failed(String)
    case cancelled
}

/// Terminal result for admission to the local reliable route. `.submitted` means Network.framework
/// processed the local send request; it is deliberately not a peer receive/decode acknowledgement.
public enum TransportLocalSendOutcome: Equatable, Sendable {
    case submitted
    case failed
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
    /// `completion` fires when the connection has DRAINED these bytes (TCP: .contentProcessed) —
    /// the video send-gate uses it as the "link is ready for the next frame" signal. It fires on
    /// success AND failure so a dead link can never latch the gate shut.
    func send(_ data: Data, completion: (() -> Void)?)
    /// Enqueue one logical message made from multiple byte ranges. No other caller's bytes may be
    /// inserted between `parts`: FrameCodec header + VideoFrameMeta + encoded AU must remain one
    /// contiguous TCP record even when CONTROL/INPUT writers run concurrently. Implementations that
    /// can scatter/gather should override this to avoid copying.
    func send(parts: [Data], completion: (() -> Void)?)
    /// Typed local-route terminal used by media conservation. Alternate transports inherit a
    /// success-only adapter; TcpTransport overrides it to preserve failure and cancellation.
    func sendLogicalMessage(
        parts: [Data],
        localCompletion: ((TransportLocalSendOutcome) -> Void)?
    )
    func stop()
}

public extension Transport {
    /// Default: no drain signal available → report completion immediately (mocks, loopback tests).
    func send(_ data: Data, completion: (() -> Void)?) {
        send(data)
        completion?()
    }

    /// Correctness-first fallback for mocks/alternate transports: collapse the logical message into
    /// one `send`. TcpTransport overrides this with a zero-full-frame-copy serialized writer.
    func send(parts: [Data], completion: (() -> Void)? = nil) {
        guard !parts.isEmpty else {
            completion?()
            return
        }
        var message = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for part in parts { message.append(part) }
        send(message, completion: completion)
    }

    func sendLogicalMessage(
        parts: [Data],
        localCompletion: ((TransportLocalSendOutcome) -> Void)?
    ) {
        send(parts: parts) { localCompletion?(.submitted) }
    }
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
    private var cancelling = false
    private var nextMessageID: UInt64 = 0   // queue-confined; tags multipart ContentContexts

    /// `avoidVirtualInterfaces` (set by the caller for WIRELESS/LAN targets): exclude virtual (VPN /
    /// utun) interfaces so a VPN such as EasyConnect — which routes the tablet's LAN IP into its tunnel
    /// — cannot hijack the connection; the socket then binds to the physical Wi-Fi/Ethernet path. It
    /// is IGNORED for loopback (hdc / 127.0.0.1 / ::1), where it would be both unnecessary and wrong.
    /// Deliberately NOT `requiredInterfaceType = .wifi`, so wired Ethernet stays a valid path.
    public init(host: String, port: UInt16, avoidVirtualInterfaces: Bool = false, lowLatency: Bool = false) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        // Low latency: disable Nagle so small input/control frames go out immediately.
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        // Paid pro-mode QoS: tag the flow .interactiveVideo so a WMM-enabled AP / the OS schedules it in
        // the Wi-Fi video access category (AC_VI, ~DSCP 34) ahead of best-effort traffic — measurably lower
        // p95 jitter/tail latency on a shared/congested Wi-Fi. Reliable TCP remains the fallback.
        if lowLatency { params.serviceClass = .interactiveVideo }
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
        send(data, completion: nil)
    }

    public func send(_ data: Data, completion: (() -> Void)?) {
        send(parts: [data], completion: completion)
    }

    public func send(parts: [Data], completion: (() -> Void)? = nil) {
        sendLogicalMessage(parts: parts) { _ in completion?() }
    }

    public func sendLogicalMessage(
        parts: [Data],
        localCompletion: ((TransportLocalSendOutcome) -> Void)?
    ) {
        // Every outbound call — CONTROL, INPUT and multipart VIDEO — enters this ONE serial queue.
        // A multipart block invokes all NWConnection sends before the next queued block can run, so
        // no concurrent control send can split a FrameCodec logical record. Network.framework keeps
        // send invocation order on the byte stream; the final .contentProcessed therefore also means
        // all preceding parts of this logical message have drained locally.
        queue.async { [weak self] in
            guard let self else {
                localCompletion?(.cancelled)
                return
            }
            guard !self.cancelling else {
                localCompletion?(.cancelled)
                return
            }
            let nonEmpty = parts.filter { !$0.isEmpty }
            guard !nonEmpty.isEmpty else {
                localCompletion?(.submitted)
                return
            }
            self.nextMessageID &+= 1
            let context = NWConnection.ContentContext(
                identifier: "superconnect.message.\(self.nextMessageID)",
                metadata: []
            )
            for part in nonEmpty.dropLast() {
                self.connection.send(content: part, contentContext: context, isComplete: false,
                                     completion: .idempotent)
            }
            self.connection.send(content: nonEmpty[nonEmpty.count - 1], contentContext: context,
                                 isComplete: true,
                                 completion: .contentProcessed { [weak self] error in
                guard let self else {
                    localCompletion?(.cancelled)
                    return
                }
                if let error { self.onStateChange?(.failed(error.localizedDescription)) }
                if self.cancelling {
                    localCompletion?(.cancelled)
                } else if error != nil {
                    localCompletion?(.failed)
                } else {
                    localCompletion?(.submitted)
                }
            })
        }
    }

    public func stop() {
        watchdog?.cancel()
        queue.async {
            self.cancelling = true
            self.connection.cancel()
        }
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

    /// Whether `host` is genuine loopback (wired hdc/USB forward). Used as a CLIENT-side fact to decide
    /// the SC-AUTH-v1 auth exemption — never trust the peer's omission of a challenge (audit H4 fail-open).
    public static func isLoopback(_ host: String) -> Bool {
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

    /// A network path generation invalidates both the address and its interface scope. Without this,
    /// the first reconnect after Wi-Fi A→B can reuse the previous NWInterface for up to ten seconds.
    public static func invalidatePhysicalInterfaceCache() {
        cacheLock.lock()
        cachedInterface = nil
        cachedAt = .distantPast
        cacheLock.unlock()
    }

    /// Public for the separately linked private UDP driver, which pins to the SAME physical interface
    /// so VIDEO datagrams cannot egress a VPN/utun while the TCP control path uses en0.
    public static func physicalInterface() -> NWInterface? {
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
    /// Public so the separately linked private UDP driver can log its interface-pin decision here too.
    public static func diag(_ s: String) {
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
