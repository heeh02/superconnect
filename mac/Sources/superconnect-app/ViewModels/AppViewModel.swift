import Foundation
import Combine

/// THE single seam between the SwiftUI views and the service layer. Exposes only what the
/// UI needs — the device list, the current selection, a de-jargoned `ConnectionState`, and
/// two actions. No Transport / Session / Producer / Process / encoder type ever appears in
/// its surface. Auto-selects a sole device and auto-disconnects if the connected device
/// unplugs.
final class AppViewModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var telemetry: SessionTelemetry?

    private let store: DeviceStore
    private let coordinator: ConnectionCoordinator
    private var bag = Set<AnyCancellable>()

    init(store: DeviceStore, coordinator: ConnectionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        store.$devices.receive(on: RunLoop.main).sink { [weak self] in self?.onDevices($0) }.store(in: &bag)
        coordinator.$state.receive(on: RunLoop.main).sink { [weak self] in self?.state = $0 }.store(in: &bag)
        coordinator.$telemetry.receive(on: RunLoop.main).sink { [weak self] in self?.telemetry = $0 }.store(in: &bag)
    }

    // Derived, read-only conveniences for the views.
    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    var isConnected: Bool { state.isConnected }
    var isBusy: Bool { state.isBusy }
    var canConnect: Bool { selectedDevice != nil }

    // Actions
    func onAppear() { store.start() }

    func select(_ id: String) {
        guard !isConnected, !isBusy else { return }   // don't switch device mid-connection
        selectedDeviceID = id
    }

    func toggleConnection() {
        switch state {
        case .connected, .connecting:
            coordinator.disconnect()
        default:
            guard let device = selectedDevice else { return }
            coordinator.connect(device, as: .host)
        }
    }

    private func onDevices(_ devs: [Device]) {
        devices = devs
        if selectedDeviceID == nil, devs.count == 1 {
            selectedDeviceID = devs[0].id                       // auto-select the only device
        }
        if let sel = selectedDeviceID, !devs.contains(where: { $0.id == sel }) {
            if coordinator.connectedDeviceID == sel { coordinator.disconnect() }  // it unplugged
            selectedDeviceID = devs.first?.id
        }
    }
}
