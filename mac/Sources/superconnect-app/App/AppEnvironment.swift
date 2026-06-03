import Foundation

/// Composition root — the ONE place concrete services are constructed and wired. Adding
/// wireless discovery or symmetric roles is a one-line edit here; nothing else changes.
final class AppEnvironment {
    let store: DeviceStore
    let coordinator: ConnectionCoordinator
    let viewModel: AppViewModel

    init() {
        let manual = ManualDiscovery()
        store = DeviceStore(sources: [
            WiredDiscovery(),          // wired: HarmonyOS tablets over hdc
            AndroidWiredDiscovery(),   // wired: Android tablets over adb (generic; brand niceties layer on later)
            manual,                  // wireless: user-entered IPs (mDNS-blocked fallback)
            WirelessDiscovery(),     // wireless: mDNS/Bonjour auto-discovery (same subnet)
            BleDiscovery(),          // wireless: BLE bootstrap (cross-subnet auto-discovery + token)
        ])
        coordinator = ConnectionCoordinator(
            // Tunnel chosen by ENDPOINT so wired bridges coexist (hdc / adb / future). Wireless dials direct.
            tunnelFor: { endpoint in
                switch endpoint {
                case .wiredHdc: return HdcFportTunnel()
                case .wiredAdb: return AdbFportTunnel()
                case .tcp:      return DirectTunnel()
                }
            },
            engineFor: { _ in HostConnection() },  // future: .host→HostConnection / .receiver→ReceiverConnection
            policy: DefaultConnectionPolicy()      // single-active-per-physical-tablet (see docs/CONFLICTS.md)
        )
        viewModel = AppViewModel(store: store, coordinator: coordinator, manual: manual)
        store.start()   // discover immediately so the popover isn't empty on first open
    }
}
