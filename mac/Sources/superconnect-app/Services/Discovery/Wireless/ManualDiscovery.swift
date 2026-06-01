import Foundation
import Combine

/// Manual WIRELESS discovery: a user-curated list of tablet IPs — the fallback for networks where
/// mDNS/Bonjour is blocked (the auto path is `WirelessDiscovery`, Inc4). Each entry is published as
/// one `.wireless` `Device` with a `.tcp(host,port)` endpoint, so connecting reuses the EXISTING
/// path unchanged (`DirectTunnel` → `TcpTransport` → `HostConnection`) — no new connection code.
/// Persisted in UserDefaults so added tablets survive relaunch. Lives in Discovery/Wireless/ beside
/// the mDNS source; the wired path knows nothing about it.
final class ManualDiscovery: DeviceDiscovery {
    let kind: TransportKind = .wireless

    private struct Entry: Codable, Hashable { let host: String; let port: UInt16 }

    private static let defaultsKey = "sc.manualWirelessDevices"
    private let subject = CurrentValueSubject<[Device], Never>([])
    private let lock = NSLock()
    private var entries: [Entry]

    init() { entries = ManualDiscovery.load() }

    var devices: AnyPublisher<[Device], Never> { subject.eraseToAnyPublisher() }

    func start() { publish() }   // emit the persisted set immediately
    func stop() {}

    /// Stable id for a manual entry (so the coordinator/store key on it consistently).
    static func deviceID(host: String, port: UInt16) -> String { "manual:\(host):\(port)" }

    /// Add a tablet by IP (default port 8888). Idempotent; persists + republishes.
    func add(host: String, port: UInt16 = 8888) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        lock.lock()
        if !entries.contains(where: { $0.host == h && $0.port == port }) {
            entries.append(Entry(host: h, port: port))
            save()
        }
        lock.unlock()
        publish()
    }

    func remove(id: String) {
        lock.lock()
        entries.removeAll { ManualDiscovery.deviceID(host: $0.host, port: $0.port) == id }
        save()
        lock.unlock()
        publish()
    }

    // MARK: - internals

    private func publish() {
        lock.lock(); let snapshot = entries; lock.unlock()
        let devs = snapshot.map { e in
            Device(id: ManualDiscovery.deviceID(host: e.host, port: e.port),
                   name: "无线 · " + e.host,
                   transport: .wireless,
                   capabilities: .canReceive,            // tablet receives; Mac hosts (today)
                   endpoint: .tcp(host: e.host, port: e.port))
        }
        subject.send(devs)
    }

    /// MUST be called under `lock`.
    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: ManualDiscovery.defaultsKey)
        }
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let arr = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return arr
    }
}
