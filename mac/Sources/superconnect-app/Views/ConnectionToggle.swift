import SwiftUI

/// The connect/disconnect control for ONE device. Reflects that device's connection state and
/// surfaces a calm error/permission message when needed, plus an advisory performance caption once
/// the soft cap is reached (connecting is still allowed — #51).
struct ConnectionToggle: View {
    @ObservedObject var vm: AppViewModel
    let device: Device

    private var state: ConnectionState { vm.state(for: device.id) }

    private var title: String {
        switch state {
        case .connected:  return "断开连接"
        case .connecting: return "连接中…"
        default:          return "开始连接"
        }
    }

    /// Each terminal state gets a tailored message + the RIGHT recovery action, instead of one
    /// undifferentiated orange line: needs-permission → open System Settings, failed → retry,
    /// blocked → a calm explanation (retrying won't help; free the other link). All actions already
    /// exist on the VM — this only branches the presentation.
    @ViewBuilder private var errorSection: some View {
        switch state {
        case .needsPermission(let e):
            errorRow(e.userMessage, action: ("打开系统设置", { vm.requestPermissions() }))
        case .failed(let e):
            errorRow(e.userMessage, action: ("重试", { vm.toggleConnection(for: device) }))
        case .blocked(let e):
            errorRow(e.userMessage, action: nil)   // single-active conflict — calm, no retry
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func errorRow(_ message: String, action: (title: String, run: () -> Void)?) -> some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.caption).foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
    }

    /// Shown when this (not-yet-connected) device would push past the advisory soft cap.
    private var perfHint: String? {
        guard vm.softCapReached, !vm.isConnected(device.id), !vm.isBusy(device.id) else { return nil }
        return "已连接 \(vm.activeConnectionCount) 台，再连可能影响性能。"
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: { vm.toggleConnection(for: device) }) {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    Text(title).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(state.isConnected ? .red : .accentColor)

            if let perfHint {
                Text(perfHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            errorSection
        }
    }
}
