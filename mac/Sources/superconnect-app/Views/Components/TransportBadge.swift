import SwiftUI

/// The wired/wireless transport pill. The ICON + label show the transport TYPE (wifi=无线 /
/// cable=有线); the COLOR shows connection STATE — GREEN when this link is connected, BLUE when it's
/// available but not connected. So at a glance: blue = 可连接, green = 已连接 (independent of type).
struct TransportBadge: View {
    let kind: TransportKind
    var connected: Bool = false

    var body: some View {
        Label(kind.badgeLabel, systemImage: kind.badgeSymbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill((connected ? Color.green : Color.blue).opacity(0.9)))
            .foregroundStyle(.white)
    }
}
