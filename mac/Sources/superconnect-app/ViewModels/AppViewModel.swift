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
    @Published private(set) var connectedDeviceID: String?   // which device the active connection is for
    @Published private(set) var screenRecordingOK: Bool = false
    @Published private(set) var accessibilityOK: Bool = false

    private let store: DeviceStore
    private let coordinator: ConnectionCoordinator
    private var bag = Set<AnyCancellable>()
    private var permTimer: Timer?

    init(store: DeviceStore, coordinator: ConnectionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        store.$devices.receive(on: RunLoop.main).sink { [weak self] in self?.onDevices($0) }.store(in: &bag)
        coordinator.$state.receive(on: RunLoop.main).sink { [weak self] in
            self?.state = $0
            self?.connectedDeviceID = self?.coordinator.connectedDeviceID
        }.store(in: &bag)
        coordinator.$telemetry.receive(on: RunLoop.main).sink { [weak self] in self?.telemetry = $0 }.store(in: &bag)
    }

    // Derived, read-only conveniences for the views.
    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    var isConnected: Bool { state.isConnected }
    var isBusy: Bool { state.isBusy }
    var canConnect: Bool { selectedDevice != nil }

    deinit { permTimer?.invalidate() }

    // Actions
    func onAppear() {
        store.start()
        refreshPermissions()
        startPermissionPolling()
    }

    /// Poll permissions every 2s so the GUI flips after the user grants in System Settings;
    /// stops itself once both are granted (re-armed by requestPermissions).
    private func startPermissionPolling() {
        guard permTimer == nil else { return }
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
    }

    func refreshPermissions() {
        let s = SystemPermissions.hostStatus()
        if screenRecordingOK != s.screenRecording { screenRecordingOK = s.screenRecording }
        if accessibilityOK != s.accessibility { accessibilityOK = s.accessibility }
        if screenRecordingOK && accessibilityOK { permTimer?.invalidate(); permTimer = nil }
    }

    func requestPermissions() {
        SystemPermissions.requestHost()
        startPermissionPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshPermissions() }
    }

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
        // Tear down if the CONNECTED device unplugged — independent of what's selected.
        if let cid = coordinator.connectedDeviceID, !devs.contains(where: { $0.id == cid }) {
            coordinator.disconnect()
        }
        if selectedDeviceID == nil, devs.count == 1 {
            selectedDeviceID = devs[0].id                       // auto-select the only device
        }
        if let sel = selectedDeviceID, !devs.contains(where: { $0.id == sel }) {
            selectedDeviceID = devs.first?.id                   // selected one vanished → reselect
        }
    }
}
