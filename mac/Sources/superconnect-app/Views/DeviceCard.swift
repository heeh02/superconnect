import SwiftUI

/// One device tile: glyph + name, a selection ring when chosen, and the wired/wireless
/// `TransportBadge` pinned to the BOTTOM-RIGHT.
struct DeviceCard: View {
    let device: Device
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "ipad.landscape")
                .font(.system(size: 30))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(device.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            TransportBadge(kind: device.transport).padding(8)
        }
        .contentShape(Rectangle())
    }
}
