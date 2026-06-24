import SwiftUI

/// Friendly empty state when nothing is detected. No jargon. Adds a short "下一步" checklist so a
/// first-time user knows exactly what to do. Pure static View text — reads no VM state.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("未检测到设备")
                .font(.headline)
            Text("用数据线连接你的平板，即可在此显示")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                nextStep("1", "用数据线把平板插到 Mac")
                nextStep("2", "在平板上打开本应用")
                nextStep("3", "或在平板里开启「无线模式」，下方手动添加 IP")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 14)
    }

    /// One numbered next-step line: circled index + caption text.
    private func nextStep(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "\(index).circle")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
