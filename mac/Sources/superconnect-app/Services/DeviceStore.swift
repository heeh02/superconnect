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
    /// Sticky representative `id` per wireless `host:port`, so the collapsed card keeps a STABLE
    /// identity when a flaky BLE/mDNS sibling comes and goes (a flip would orphan the connection
    /// state keyed by the old id). Re-chosen only when the held representative itself disappears.
    private var repIdByEndpoint: [String: String] = [:]
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
    }

    /// Collapse wireless (`.tcp`) devices sharing the same `host:port` into one card; pass wired and
    /// anything else through untouched. The representative carries the BLE proximity token (so the
    /// merged card still auto-trusts) and the most human name, and its `id` is held stable per
    /// endpoint via `repIdByEndpoint`.
    private func collapseWireless(_ all: [Device]) -> [Device] {
        var groups: [String: [Device]] = [:]
        var passthrough: [Device] = []
        for d in all {
            guard case let .tcp(host, port) = d.endpoint else { passthrough.append(d); continue }
            groups[Self.endpointKey(host: host, port: port), default: []].append(d)
        }
        repIdByEndpoint = repIdByEndpoint.filter { groups.keys.contains($0.key) }   // forget vanished endpoints
        var result = passthrough
        for (key, group) in groups { result.append(representative(of: group, endpointKey: key)) }
        return result
    }

    /// Pick one card for a wireless `host:port` group. ID comes from the most STABLE source
    /// (manual is user-entered, removable, and doesn't flap → mdns → ble), pinned via the sticky
    /// map so a sibling flap can't flip it. NAME comes from the most HUMAN source (mdns/ble report
    /// the device's real name; a manual entry may be a raw IP). Token + capabilities union the group.
    private func representative(of group: [Device], endpointKey key: String) -> Device {
        guard group.count > 1 else {
            if let only = group.first { repIdByEndpoint[key] = only.id }
            return group.first!
        }
        func rank(_ id: String, _ order: [String]) -> Int {
            for (i, p) in order.enumerated() where id.hasPrefix(p) { return i }
            return order.count
        }
        // Hold the previously-chosen representative if it's still present; else pick by id-stability.
        let chosen: Device
        if let held = repIdByEndpoint[key], let stillThere = group.first(where: { $0.id == held }) {
            chosen = stillThere
        } else {
            chosen = group.min { rank($0.id, ["manual:", "mdns:", "ble:"]) < rank($1.id, ["manual:", "mdns:", "ble:"]) }!
            repIdByEndpoint[key] = chosen.id
        }
        var rep = chosen
        if let nicest = group.min(by: { rank($0.id, ["mdns:", "ble:", "manual:"]) < rank($1.id, ["mdns:", "ble:", "manual:"]) }),
           !nicest.name.isEmpty { rep.name = nicest.name }
        rep.pairingToken = rep.pairingToken ?? group.compactMap { $0.pairingToken }.first
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
