import SwiftUI

/// The detail pane for the selected device: header + connect control + (when connected) live
/// telemetry + a Screen Recording permission section +
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
                        Text("使用 H.264 兼容模式，适配 Android 与卓易通接收端。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                if isThisConnected, let t = deviceTelemetry {
                    GroupBox("画面") {
                        HStack {
                            Image(systemName: "display").foregroundStyle(.tint)
                            Text(t.resolution)
                            Spacer()
                            Text(t.codec.uppercased()).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                }

                GroupBox("权限") {
                    VStack(alignment: .leading, spacing: 8) {
                        permRow("屏幕录制", vm.screenRecordingOK)
                        if !vm.screenRecordingOK {
                            Button("授予权限 / 打开系统设置") { vm.requestPermissions() }
                                .controlSize(.small)
                        }
                        Toggle("允许平板触控、手写笔与键盘", isOn: $vm.pointerControlEnabled)
                        if vm.pointerControlEnabled { permRow("辅助功能（控制画面）", vm.accessibilityOK) }
                        Text("仅观看只需要屏幕录制。开启控制后，需允许辅助功能；可随时关闭。")
                            .font(.caption).foregroundStyle(.tertiary)
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

                GroupBox("更多协作方式") {
                    VStack(spacing: 12) {
                        HStack {
                            Label("触控、手写笔与键盘", systemImage: "hand.draw")
                            Spacer()
                            Text(vm.pointerControlEnabled && vm.accessibilityOK ? "已开启" : "在权限中开启")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        lockedRow("文件传输", icon: "doc.on.doc")
                    }.padding(10)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(vm.displayName(for: device))
        .background(FOSSPreviewAppearance.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "ipad.landscape").font(.system(size: 32)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(vm.displayName(for: device)).font(.title2).fontWeight(.semibold)
                HStack(spacing: 8) {
                    StatusDot(state: deviceState)
                    Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                    TransportBadge(kind: device.transport, connected: deviceState.isConnected)
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

    private func lockedRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Label("后续解锁", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}
