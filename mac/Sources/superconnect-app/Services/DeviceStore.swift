import Foundation
import Combine

/// Merges every `DeviceDiscovery` source into one observable list, collapsing the same
/// `id` seen across transports into a single card (unioning capabilities). Intentionally
/// thin — it owns merge/dedupe, not a heavyweight "hub". Publishes on the main thread for
/// SwiftUI.
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []

    private let sources: [DeviceDiscovery]
    /// Keyed by SOURCE identity (not `TransportKind`): several sources can share a kind — e.g. the
    /// manual-IP and mDNS wireless sources are both `.wireless` — so keying on kind would let one
    /// clobber the other's list. Each source owns its own slot; merge unions all slots.
    private var bySource: [ObjectIdentifier: [Device]] = [:]
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
        devices = byId.values.sorted { $0.name < $1.name }
    }
}
