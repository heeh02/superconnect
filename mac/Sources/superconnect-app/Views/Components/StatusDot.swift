import SwiftUI

/// Small colored dot reflecting the user-facing connection state.
struct StatusDot: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .connected:                     return .green       // 已连接
        case .connecting:                    return .orange      // 连接中
        case .needsPermission, .failed:      return .red
        case .blocked:                       return .gray        // 被占用 / 不可连接
        case .idle:                          return .blue        // 可连接（已发现，未连接）
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}
