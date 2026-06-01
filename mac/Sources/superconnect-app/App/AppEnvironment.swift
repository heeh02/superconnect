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
            WiredDiscovery(),
            manual,                  // wireless: user-entered IPs (mDNS-blocked fallback)
            WirelessDiscovery(),     // wireless: mDNS/Bonjour auto-discovery
        ])
        coordinator = ConnectionCoordinator(
            tunnelFor: { kind in kind == .wired ? HdcFportTunnel() as TunnelService : DirectTunnel() as TunnelService },
            engineFor: { _ in HostConnection() }   // future: .host→HostConnection / .receiver→ReceiverConnection
        )
        viewModel = AppViewModel(store: store, coordinator: coordinator, manual: manual)
        store.start()   // discover immediately so the popover isn't empty on first open
    }
}
