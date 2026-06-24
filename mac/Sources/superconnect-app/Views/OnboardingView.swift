import SwiftUI

/// First-run permissions checklist, shown as a sheet from `DashboardView` while `!vm.hostReady`
/// and nothing is connected. A 2-step list — 屏幕录制 / 辅助功能 — whose ✓ flip live as the VM's
/// permission polling (`refreshPermissions`, every 2s) updates `screenRecordingOK` / `accessibilityOK`.
/// Pure View: reads the two published booleans + reuses the existing `requestPermissions()` /
/// `regrantAccessibility()` actions. Touches no service.
struct OnboardingView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 12) {
                stepRow(
                    index: 1,
                    title: "屏幕录制",
                    detail: "用于把 Mac 画面投到平板。",
                    ok: vm.screenRecordingOK
                )
                stepRow(
                    index: 2,
                    title: "辅助功能（输入注入）",
                    detail: "用于把平板上的触控与手写还原成 Mac 的鼠标/键盘操作。",
                    ok: vm.accessibilityOK
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                if !vm.hostReady {
                    Button("授予权限 / 打开系统设置") { vm.requestPermissions() }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
                // Safety net: 辅助功能 shows 已授权 but触控/手写仍无效 ⇒ a stale TCC entry; reset & re-grant.
                if vm.accessibilityOK {
                    Button("已授权却无触控？重置并重新授权辅助功能") { vm.regrantAccessibility() }
                        .controlSize(.small)
                }
                Text("授权后此处的 ✓ 会自动亮起，无需重启应用。本应用使用稳定签名，权限会跨重新构建保留。")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.hostReady {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("权限已就绪，可以开始投屏。").font(.callout)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .padding(28)
        .frame(width: 460)
        .animation(.default, value: vm.hostReady)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 32)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                Text("开始前，先授予两项权限").font(.title2).fontWeight(.semibold)
                Text("一次设置，长期生效").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// One numbered step: a circled index, title + caption, and a live ✓ / 待授权 trailing badge.
    private func stepRow(index: Int, title: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "\(index).circle")
                .font(.system(size: 22))
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(ok ? "已授权" : "待授权")
                        .font(.caption)
                        .foregroundStyle(ok ? Color.green : Color.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
