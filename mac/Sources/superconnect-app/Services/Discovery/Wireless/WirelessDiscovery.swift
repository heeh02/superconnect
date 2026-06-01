import Foundation
import Combine
import Network

/// WIRELESS auto-discovery over mDNS/Bonjour: browses for `_superconnect._tcp` services (advertised
/// by tablets in wireless mode) and publishes one `.wireless` `Device` per resolved peer. Connecting
/// reuses the EXISTING path unchanged (`DirectTunnel` → `TcpTransport` → `HostConnection`) — Bonjour
/// is resolved here to a concrete `host:port`, so nothing downstream needs to know about mDNS.
/// Manual IP entry (`ManualDiscovery`) remains the fallback on networks that block mDNS.
///
/// Requires `NSBonjourServices` (`_superconnect._tcp`) + `NSLocalNetworkUsageDescription` in
/// Info.plist; on macOS the first browse triggers the Local Network privacy prompt.
final class WirelessDiscovery: DeviceDiscovery {
    let kind: TransportKind = .wireless

    private let subject = CurrentValueSubject<[Device], Never>([])
    private let queue = DispatchQueue(label: "sc.wireless.discovery")
    private var browser: NWBrowser?
    /// Resolved devices keyed by Bonjour service name (all access on `queue`).
    private var found: [String: Device] = [:]
    /// Transient resolver connections, kept alive until they resolve (all access on `queue`).
    private var resolving: [String: NWConnection] = [:]

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_superconnect._tcp", domain: nil), using: NWParameters.tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async { self?.handle(results) }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        browser?.cancel(); browser = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.resolving.values.forEach { $0.cancel() }
            self.resolving.removeAll()
            self.found.removeAll()
            self.subject.send([])
        }
    }

    // MARK: - internals (all on `queue`)

    private func handle(_ results: Set<NWBrowser.Result>) {
        var present = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            present.insert(name)
            if found[name] == nil, resolving[name] == nil { resolve(r, name: name) }
        }
        // Drop devices (and any in-flight resolvers) that vanished from the browse set.
        let gone = Set(found.keys).union(resolving.keys).subtracting(present)
        guard !gone.isEmpty else { return }
        for n in gone {
            resolving[n]?.cancel(); resolving[n] = nil
            found[n] = nil
        }
        publish()
    }

    /// Resolve a Bonjour service to a concrete host:port via a short-lived connection, then publish.
    private func resolve(_ result: NWBrowser.Result, name: String) {
        let conn = NWConnection(to: result.endpoint, using: NWParameters.tcp)
        resolving[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var device: Device?
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let hostStr = WirelessDiscovery.string(from: host)
                    if !hostStr.isEmpty {
                        device = Device(id: "mdns:\(name)", name: name, transport: .wireless,
                                        capabilities: .canReceive,
                                        endpoint: .tcp(host: hostStr, port: port.rawValue))
                    }
                }
                self.queue.async {
                    // Identity-guard: only clear/replace if THIS conn is still the tracked resolver
                    // (a flapping service may have started a newer one for the same name).
                    if self.resolving[name] === conn { self.resolving[name] = nil }
                    if let device { self.found[name] = device; self.publish() }
                }
                conn.cancel()
            case .failed, .cancelled:
                self.queue.async { if self.resolving[name] === conn { self.resolving[name] = nil } }
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func publish() { subject.send(Array(found.values).sorted { $0.name < $1.name }) }

    /// A dial-able string for `TcpTransport`. For IPv6 KEEP the `%zone` — a link-local address
    /// (`fe80::…`, common from Bonjour on a LAN) is undialable without it, and `NWEndpoint.Host`
    /// accepts the zoned form.
    private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return a.debugDescription
        case .ipv6(let a): return a.debugDescription
        case .name(let n, _): return n
        @unknown default: return ""
        }
    }
}
