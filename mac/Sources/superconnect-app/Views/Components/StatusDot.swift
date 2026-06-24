import SwiftUI

/// Small colored dot reflecting the user-facing connection state. Color comes from the single
/// source of truth (`ConnectionState.dotColor`); `size` lets the sidebar use a larger dot than inline.
struct StatusDot: View {
    let state: ConnectionState
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(state.dotColor).frame(width: size, height: size)
    }
}
