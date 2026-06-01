import Foundation
import Combine

/// THE single seam between the SwiftUI views and the service layer. Exposes only what the
/// UI needs — the device list, the current selection, per-device de-jargoned `ConnectionState`,
/// and two actions. No Transport / Session / Producer / Process / encoder type ever appears in
/// its surface. Multiple devices can be connected at once (#51); each is connected/disconnected
/// independently. Auto-selects a sole device and auto-disconnects a device that unplugs.
final class AppViewModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selectedDeviceID: String?
    /// Per-device connection state, keyed by `Device.id` (absent ⇒ `.idle`).
    @Published private(set) var states: [String: ConnectionState] = [:]
    /// Per-device stream telemetry, keyed by `Device.id`.
    @Published private(set) var telemetryByID: [String: SessionTelemetry] = [:]
    @Published private(set) var screenRecordingOK: Bool = false
    @Published private(set) var accessibilityOK: Bool = false

    /// Advisory soft cap: at/above this many simultaneous links the detail view warns about
    /// performance, but connecting is never blocked (a perf-limited Mac runs N encode pipelines — #51).
    let softCap = 2

    private let store: DeviceStore
    private let coordinator: ConnectionCoordinator
    private var bag = Set<AnyCancellable>()
    private var permTimer: Timer?

    init(store: DeviceStore, coordinator: ConnectionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        store.$devices.receive(on: RunLoop.main).sink { [weak self] in self?.onDevices($0) }.store(in: &bag)
        coordinator.$states.receive(on: RunLoop.main).sink { [weak self] in self?.states = $0 }.store(in: &bag)
        coordinator.$telemetry.receive(on: RunLoop.main).sink { [weak self] in self?.telemetryByID = $0 }.store(in: &bag)
    }

    // Per-device lookups for the views.
    func state(for id: String) -> ConnectionState { states[id] ?? .idle }
    func telemetry(for id: String) -> SessionTelemetry? { telemetryByID[id] }
    func isConnected(_ id: String) -> Bool { state(for: id).isConnected }
    func isBusy(_ id: String) -> Bool { state(for: id).isBusy }

    // Derived, read-only conveniences.
    var selectedDevice: Device? { devices.first { $0.id == selectedDeviceID } }
    /// Devices currently connected or connecting.
    var activeConnectionCount: Int { devices.reduce(0) { $0 + ((isConnected($1.id) || isBusy($1.id)) ? 1 : 0) } }
    /// True once the advisory soft cap is reached — the detail view shows a perf caption (non-blocking).
    var softCapReached: Bool { activeConnectionCount >= softCap }

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

    /// Selection just drives which detail pane is shown. Connecting a device no longer locks the
    /// sidebar, so the user can inspect another device while this one streams (#51).
    func select(_ id: String) {
        selectedDeviceID = id
    }

    /// Connect or disconnect THIS device, independently of the others.
    func toggleConnection(for device: Device) {
        if isConnected(device.id) || isBusy(device.id) {
            coordinator.disconnect(deviceID: device.id)
        } else {
            coordinator.connect(device, as: .host)
        }
    }

    private func onDevices(_ devs: [Device]) {
        devices = devs
        // Tear down ONLY the connections whose device unplugged; every other link stays alive.
        let present = Set(devs.map(\.id))
        for id in coordinator.connectedDeviceIDs where !present.contains(id) {
            coordinator.disconnect(deviceID: id)
        }
        if selectedDeviceID == nil, devs.count == 1 {
            selectedDeviceID = devs[0].id                       // auto-select the only device
        }
        if let sel = selectedDeviceID, !present.contains(sel) {
            selectedDeviceID = devs.first?.id                   // selected one vanished → reselect
        }
    }
}
