import SwiftUI
import AppKit

/// The popover root. Header → device grid (or empty state) → single connect/disconnect
/// control → optional advanced disclosure → quit. Binds only to `AppViewModel`.
struct RootView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(.tint)
                Text("Superconnect").font(.headline)
                Spacer()
                StatusDot(state: vm.state)
            }

            if vm.devices.isEmpty {
                EmptyStateView()
            } else {
                DeviceListView(vm: vm)
            }

            ConnectionToggle(vm: vm)

            if vm.isConnected, let telemetry = vm.telemetry {
                AdvancedPanel(telemetry: telemetry)
            }

            Divider()

            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Label("退出 Superconnect", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { vm.onAppear() }
    }
}
