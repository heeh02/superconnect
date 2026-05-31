import SwiftUI

/// The wired/wireless corner badge. Capsule label, green for wired / blue for wireless.
/// Already renders the `.wireless` case so the discovery stub's future output is proven.
struct TransportBadge: View {
    let kind: TransportKind

    var body: some View {
        Label(kind.badgeLabel, systemImage: kind.badgeSymbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill((kind == .wired ? Color.green : Color.blue).opacity(0.9)))
            .foregroundStyle(.white)
    }
}
