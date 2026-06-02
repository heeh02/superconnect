import SwiftUI

/// The detail pane for the selected device: header + connect control + (when connected) live
/// telemetry + a Permissions section (Screen Recording / Accessibility, with a grant button) +
/// read-only negotiated info. Reuses ConnectionToggle / AdvancedPanel / StatusDot / TransportBadge.
struct DeviceDetailView: View {
    @ObservedObject var vm: AppViewModel
    let device: Device

    private var deviceState: ConnectionState { vm.state(for: device.id) }
    private var isThisConnected: Bool { vm.isConnected(device.id) }
    private var deviceTelemetry: SessionTelemetry? { vm.telemetry(for: device.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ConnectionToggle(vm: vm, device: device)

                // 画质 / 码率 — always visible so it can be set before connecting; persists + retunes
                // a live stream immediately, or applies on the next connect.
                GroupBox("画质") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("码率").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(vm.bitrateMbps)) Mbps")
                        }
                        Slider(value: $vm.bitrateMbps, in: 10...100, step: 5)
                        if isThisConnected, let t = deviceTelemetry, t.actualMbps > 0 {
                            HStack {
                                Text("实际输出").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(t.actualMbps) Mbps").monospacedDigit()
                            }
                        }
                        Text("越高越清晰、越占带宽。连接时拖动实时生效；未连接时的设置会在连接后应用。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                if isThisConnected, let t = deviceTelemetry {
                    GroupBox("画面") { AdvancedPanel(telemetry: t).padding(6) }
                }

                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 8) {
                        permRow("屏幕录制", vm.screenRecordingOK)
                        permRow("辅助功能（输入注入）", vm.accessibilityOK)
                        if !(vm.screenRecordingOK && vm.accessibilityOK) {
                            Button("授予权限 / 打开系统设置") { vm.requestPermissions() }
                                .controlSize(.small)
                            Text("重新打包应用后权限会被系统重置，需重新授予。")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox("连接信息") {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow("传输", device.transport == .wired ? "有线 (USB)" : "无线")
                        infoRow("画面", deviceTelemetry.map { "\($0.resolution) · \($0.codec.uppercased())" } ?? "连接后显示")
                        Text("分辨率 / 刷新率 / 编码由 Mac 与平板自动协商；码率可在「高级信息」中实时调节。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(vm.displayName(for: device))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "ipad.landscape").font(.system(size: 32)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.displayName(for: device)).font(.title2).fontWeight(.semibold)
                HStack(spacing: 8) {
                    StatusDot(state: deviceState)
                    Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                    TransportBadge(kind: device.transport)
                }
            }
            Spacer()
        }
    }

    private var stateText: String {
        switch deviceState {
        case .connected:       return "已连接 · 投屏中"
        case .connecting:      return "连接中…"
        case .needsPermission: return "需要权限"
        case .failed:          return "连接失败"
        case .blocked:         return "已被占用"
        case .idle:            return "未连接"
        }
    }

    private func permRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
            Spacer()
            Text(ok ? "已授权" : "未授权").foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }
    }
}
