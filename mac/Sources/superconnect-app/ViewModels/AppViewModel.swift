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

    /// Global encode bitrate (Mbps, 10–100), persisted across launches. Changing it retunes every
    /// live link immediately (the coordinator fans it out to all engines). The single user-adjustable
    /// encode setting; fps/codec stay caps-negotiated.
    @Published var bitrateMbps: Double = AppViewModel.loadBitrate() {
        didSet {
            UserDefaults.standard.set(bitrateMbps, forKey: AppViewModel.bitrateKey)
            coordinator.applyBitrate(Int(bitrateMbps))
        }
    }
    private static let bitrateKey = "sc.bitrateMbps"
    private static func loadBitrate() -> Double {
        let v = UserDefaults.standard.double(forKey: bitrateKey)
        return (v >= 10 && v <= 100) ? v : 50
    }

    private let store: DeviceStore
    private let coordinator: ConnectionCoordinator
    private let manualDiscovery: ManualDiscovery
    private var bag = Set<AnyCancellable>()
    private var permTimer: Timer?

    init(store: DeviceStore, coordinator: ConnectionCoordinator, manual: ManualDiscovery) {
        self.store = store
        self.coordinator = coordinator
        self.manualDiscovery = manual
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
            // .idle / .failed / .needsPermission → (re)connect. A terminal engine failure (e.g. a
            // wireless pairing rejection) leaves a stopped engine registered; coordinator.connect is
            // idempotent and would no-op, so drop the stale entry first.
            if case .failed = state(for: device.id) { coordinator.disconnect(deviceID: device.id) }
            coordinator.connect(device, as: .host)
            coordinator.applyBitrate(Int(bitrateMbps))   // seed the new link with the current global bitrate
        }
    }

    // MARK: - Manual wireless devices (mDNS-blocked fallback)

    /// True for a user-added wireless device (so the UI can offer "移除"). Auto-discovered devices
    /// (wired serials, mDNS) are not removable.
    func isManualWireless(_ id: String) -> Bool { id.hasPrefix("manual:") }

    /// Add a tablet by typed address: "192.168.1.5" (port 8888) or "192.168.1.5:9000".
    func addManualWirelessDevice(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var host = t
        var port: UInt16 = 8888
        // Trailing ":port" → split it off (IPv4 only for the MVP; bare IPv6 isn't supported here).
        if let colon = t.lastIndex(of: ":"), let p = UInt16(t[t.index(after: colon)...]) {
            host = String(t[..<colon])
            port = p
        }
        manualDiscovery.add(host: host, port: port)
    }

    /// Remove a manual device — tearing down its link first if connected.
    func removeManualWirelessDevice(_ id: String) {
        coordinator.disconnect(deviceID: id)
        if selectedDeviceID == id { selectedDeviceID = nil }
        manualDiscovery.remove(id: id)
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
