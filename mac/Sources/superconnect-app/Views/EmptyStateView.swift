import SwiftUI

/// Friendly empty state when nothing is detected. No jargon.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("未检测到设备")
                .font(.headline)
            Text("用数据线连接你的平板，即可在此显示")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
