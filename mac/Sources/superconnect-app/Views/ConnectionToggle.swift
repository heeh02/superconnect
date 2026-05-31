import SwiftUI

/// The single connect/disconnect control. Reflects the connection state and surfaces a
/// calm error/permission message when needed — the only such control in the app.
struct ConnectionToggle: View {
    @ObservedObject var vm: AppViewModel

    private var title: String {
        switch vm.state {
        case .connected:  return "断开连接"
        case .connecting: return "连接中…"
        default:          return "开始连接"
        }
    }

    private var errorText: String? {
        switch vm.state {
        case .needsPermission(let e), .failed(let e): return e.userMessage
        default: return nil
        }
    }

    private var disabled: Bool {
        // Connectable only with a selection; always allow disconnect while busy/connected.
        !vm.canConnect && !vm.isConnected && !vm.isBusy
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: { vm.toggleConnection() }) {
                HStack(spacing: 8) {
                    StatusDot(state: vm.state)
                    Text(title).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(vm.isConnected ? .red : .accentColor)
            .disabled(disabled)

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
