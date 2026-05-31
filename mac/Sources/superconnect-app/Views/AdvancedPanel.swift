import SwiftUI

/// Optional, collapsed-by-default disclosure — the ONLY place technical stats appear.
/// Reads telemetry; never referenced by the main flow.
struct AdvancedPanel: View {
    let telemetry: SessionTelemetry

    var body: some View {
        DisclosureGroup("高级信息") {
            VStack(spacing: 4) {
                row("分辨率", telemetry.resolution)
                row("编码", telemetry.codec)
                row("帧率", telemetry.fps > 0 ? "\(telemetry.fps) fps" : "—")
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
    }
}
