import Foundation
import Combine

/// Merges every `DeviceDiscovery` source into one observable list, collapsing the same
/// `id` seen across transports into a single card (unioning capabilities). Intentionally
/// thin — it owns merge/dedupe, not a heavyweight "hub". Publishes on the main thread for
/// SwiftUI.
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []

    private let sources: [DeviceDiscovery]
    private var byKind: [TransportKind: [Device]] = [:]
    private var bag = Set<AnyCancellable>()
    private var started = false

    init(sources: [DeviceDiscovery]) { self.sources = sources }

    func start() {
        guard !started else { return }
        started = true
        for source in sources {
            source.devices
                .receive(on: RunLoop.main)
                .sink { [weak self] devs in self?.merge(kind: source.kind, devs) }
                .store(in: &bag)
            source.start()
        }
    }

    func stop() { sources.forEach { $0.stop() } }

    private func merge(kind: TransportKind, _ devs: [Device]) {
        byKind[kind] = devs
        var byId: [String: Device] = [:]
        for list in byKind.values {
            for d in list {
                if var existing = byId[d.id] {
                    existing.capabilities.formUnion(d.capabilities)
                    byId[d.id] = existing       // first transport seen wins the badge
                } else {
                    byId[d.id] = d
                }
            }
        }
        devices = byId.values.sorted { $0.name < $1.name }
    }
}
