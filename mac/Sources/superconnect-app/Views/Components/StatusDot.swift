import SwiftUI

/// Small colored dot reflecting the user-facing connection state.
struct StatusDot: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .connected:                     return .green
        case .connecting:                    return .orange
        case .needsPermission, .failed:      return .red
        case .blocked:                       return .orange
        case .idle:                          return .secondary
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}
