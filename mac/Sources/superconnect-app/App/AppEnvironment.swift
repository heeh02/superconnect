import Foundation

/// Composition root — the ONE place concrete services are constructed and wired. Adding
/// wireless discovery or symmetric roles is a one-line edit here; nothing else changes.
final class AppEnvironment {
    let store: DeviceStore
    let coordinator: ConnectionCoordinator
    let viewModel: AppViewModel

    init() {
        let manual = ManualDiscovery()
#if SC_FOSS_PREVIEW
        let sources: [DeviceDiscovery] = [
            AndroidWiredDiscovery(port: 18888),
            manual,
            WirelessDiscovery(),
        ]
#else
        let sources: [DeviceDiscovery] = [
            WiredDiscovery(),
            AndroidWiredDiscovery(),
            manual,
            WirelessDiscovery(),
            BleDiscovery(),
        ]
#endif
        store = DeviceStore(sources: sources)
        coordinator = ConnectionCoordinator(
            // Tunnel chosen by ENDPOINT so wired bridges coexist (hdc / adb / future). Wireless dials direct.
            tunnelFor: { endpoint in
                switch endpoint {
                case .wiredHdc: return HdcFportTunnel()
                case .wiredAdb: return AdbFportTunnel()
                case .tcp:      return DirectTunnel()
                }
            },
            engineFor: { _ in HostConnection() },  // This preview only sends the Mac's display.
            policy: DefaultConnectionPolicy()      // single-active-per-physical-tablet (see docs/CONFLICTS.md)
        )
        viewModel = AppViewModel(store: store, coordinator: coordinator, manual: manual)
        store.start()   // discover immediately so the popover isn't empty on first open
    }
}
