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

    private var errorText: String? {
        switch state {
        case .needsPermission(let e), .failed(let e): return e.userMessage
        default: return nil
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

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
