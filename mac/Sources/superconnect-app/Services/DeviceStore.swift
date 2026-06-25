import Foundation
import Combine

/// Merges every `DeviceDiscovery` source into one observable list. Two collapse passes:
/// (1) same `id` seen across sources → one card (union capabilities); (2) WIRELESS cards that
/// resolve to the same `host:port` → one card — the very common case of one tablet seen at once
/// over BLE + mDNS (+ a manual IP). Wired stays its own card: an hdc serial and a LAN IP are
/// different identity namespaces with no reliable pre-connection link (mDNS/BLE don't advertise the
/// persisted `peerId`, and hdc can't read the app sandbox), and the connection arbiter already
/// blocks double-connecting one tablet. Intentionally thin — owns merge/dedupe, not a "hub".
/// Publishes on the main thread for SwiftUI. See docs/CONFLICTS.md / docs/MODULARITY_AUDIT.md.
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []

    private let sources: [DeviceDiscovery]
    /// Keyed by SOURCE identity (not `TransportKind`): several sources can share a kind — e.g. the
    /// manual-IP and mDNS wireless sources are both `.wireless` — so keying on kind would let one
    /// clobber the other's list. Each source owns its own slot; merge unions all slots.
    private var bySource: [ObjectIdentifier: [Device]] = [:]
    /// Sticky representative `id` per dedup GROUP (keyed by the group's stable `peerKey` when known, else
    /// its `host:port`), so the collapsed card keeps a STABLE identity when a flaky BLE/mDNS sibling or a
    /// second LAN IP comes and goes (a flip would orphan the connection state keyed by the old id).
    /// Re-chosen only when the held representative itself disappears.
    private var repIdByGroup: [String: String] = [:]
    private var bag = Set<AnyCancellable>()
    private var started = false

    init(sources: [DeviceDiscovery]) { self.sources = sources }

    func start() {
        guard !started else { return }
        started = true
        for source in sources {
            let sid = ObjectIdentifier(source)
            source.devices
                .receive(on: RunLoop.main)
                .sink { [weak self] devs in self?.merge(sourceID: sid, devs) }
                .store(in: &bag)
            source.start()
        }
    }

    func stop() { sources.forEach { $0.stop() } }

    private func merge(sourceID: ObjectIdentifier, _ devs: [Device]) {
        bySource[sourceID] = devs
        var byId: [String: Device] = [:]
        for list in bySource.values {
            for d in list {
                if var existing = byId[d.id] {
                    existing.capabilities.formUnion(d.capabilities)
                    byId[d.id] = existing       // first source seen wins the badge
                } else {
                    byId[d.id] = d
                }
            }
        }
        devices = collapseWireless(Array(byId.values)).sorted { $0.name < $1.name }
        Self.diag("cards=\(devices.count) " + devices.map { "[\($0.transport.rawValue) \($0.name) pk=\($0.peerKey ?? "—")]" }.joined(separator: " "))
    }

    /// Append a one-line device-list summary to /tmp/sc-mac-diag.log (shared with HostConnection/BLE) so
    /// the collapse result (and each card's dedup `peerKey`) is observable. Self-bounding.
    private static func diag(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 { try? FileManager.default.removeItem(atPath: path) }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = ("STORE: " + s + "\n").data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }

    /// Collapse wireless (`.tcp`) devices for the SAME tablet into one card; pass wired and anything else
    /// through untouched. Two wireless cards merge when they share a stable `peerKey` (the same tablet at
    /// two LAN IPs / over BLE vs mDNS) OR the same `host:port` (sources that don't advertise a peerKey,
    /// e.g. a manual IP next to a peerKey-bearing mDNS card). The representative carries the BLE proximity
    /// token + peerKey and the most human name; its `id` is held stable per group via `repIdByGroup`.
    private func collapseWireless(_ all: [Device]) -> [Device] {
        var wireless: [Device] = []
        var passthrough: [Device] = []
        for d in all {
            if case .tcp = d.endpoint { wireless.append(d) } else { passthrough.append(d) }
        }
        let groups = Self.groupWireless(wireless)
        let liveKeys = Set(groups.map { Self.groupKey(of: $0) })
        repIdByGroup = repIdByGroup.filter { liveKeys.contains($0.key) }   // forget vanished groups
        var result = passthrough
        for group in groups { result.append(representative(of: group)) }
        return result
    }

    /// Group wireless cards via union-find over two signals: a shared `peerKey` OR a shared `host:port`.
    /// peerKey is the cross-IP/cross-source tablet identity; host:port links peerKey-less sources. A card
    /// can bridge two host:port groups via a common peerKey (the dual-Wi-Fi case this whole change fixes).
    private static func groupWireless(_ devs: [Device]) -> [[Device]] {
        guard !devs.isEmpty else { return [] }
        var parent = Array(0..<devs.count)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        var firstByPeer: [String: Int] = [:]
        var firstByEndpoint: [String: Int] = [:]
        for (i, d) in devs.enumerated() {
            if let pk = d.peerKey {
                if let j = firstByPeer[pk] { union(i, j) } else { firstByPeer[pk] = i }
            }
            if case let .tcp(host, port) = d.endpoint {
                let ek = endpointKey(host: host, port: port)
                if let j = firstByEndpoint[ek] { union(i, j) } else { firstByEndpoint[ek] = i }
            }
        }
        var byRoot: [Int: [Device]] = [:]
        for (i, d) in devs.enumerated() { byRoot[find(i), default: []].append(d) }
        return Array(byRoot.values)
    }

    /// A stable key identifying a dedup group across refreshes: the shared peerKey if any (min for
    /// determinism), else the min `host:port` in the group. Used to pin the sticky representative id.
    private static func groupKey(of group: [Device]) -> String {
        if let pk = group.compactMap({ $0.peerKey }).min() { return "peer:" + pk }
        let eps: [String] = group.compactMap { d in
            if case let .tcp(host, port) = d.endpoint { return endpointKey(host: host, port: port) }
            return nil
        }
        return "ep:" + (eps.min() ?? (group.first?.id ?? ""))
    }

    /// Pick one card for a wireless `host:port` group. ID comes from the most STABLE source
    /// (manual is user-entered, removable, and doesn't flap → mdns → ble), pinned via the sticky
    /// map so a sibling flap can't flip it. NAME comes from the most HUMAN source (mdns/ble report
    /// the device's real name; a manual entry may be a raw IP). Token + capabilities union the group.
    private func representative(of group: [Device]) -> Device {
        let key = Self.groupKey(of: group)
        guard group.count > 1 else {
            if let only = group.first { repIdByGroup[key] = only.id }
            return group.first!
        }
        func rank(_ id: String, _ order: [String]) -> Int {
            for (i, p) in order.enumerated() where id.hasPrefix(p) { return i }
            return order.count
        }
        // Hold the previously-chosen representative if it's still present; else pick by id-stability.
        let chosen: Device
        if let held = repIdByGroup[key], let stillThere = group.first(where: { $0.id == held }) {
            chosen = stillThere
        } else {
            chosen = group.min { rank($0.id, ["manual:", "mdns:", "ble:"]) < rank($1.id, ["manual:", "mdns:", "ble:"]) }!
            repIdByGroup[key] = chosen.id
        }
        var rep = chosen
        if let nicest = group.min(by: { rank($0.id, ["mdns:", "ble:", "manual:"]) < rank($1.id, ["mdns:", "ble:", "manual:"]) }),
           !nicest.name.isEmpty { rep.name = nicest.name }
        rep.pairingToken = rep.pairingToken ?? group.compactMap { $0.pairingToken }.first
        rep.peerKey = rep.peerKey ?? group.compactMap { $0.peerKey }.first
        for d in group { rep.capabilities.formUnion(d.capabilities) }
        return rep
    }

    /// Normalize a wireless endpoint to a merge key: strip any IPv6 zone (`%en0`) and lowercase, so
    /// the same tablet reached by several sources collapses. Distinct tablets have distinct IPs, so
    /// this never merges two real devices. (IPv4-vs-IPv6 forms of one host don't collapse — an
    /// accepted residual; see docs/MODULARITY_AUDIT.md.)
    static func endpointKey(host: String, port: UInt16) -> String {
        let h = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return h.lowercased() + ":" + String(port)
    }
}
