import Foundation

/// The user-facing error domain. Every case maps to one calm, actionable message — the
/// only thing the UI ever shows on failure. No stack traces, no codec strings.
enum AppError: Error, Equatable {
    case hdcNotFound
    case needsScreenRecording
    case needsAccessibility
    case tunnelFailed
    case connectionFailed
    case receiverNotSupported
    case pairingRejected
    case wirelessUnreachable
    case alreadyConnectedElsewhere
    case authFailed

    var userMessage: String {
        switch self {
        case .hdcNotFound:
            return "未找到设备连接工具，请确认已安装 DevEco Studio"
        case .needsScreenRecording:
            return "请在「系统设置 › 隐私与安全性 › 屏幕录制」中允许 Superconnect，然后重试"
        case .needsAccessibility:
            return "请在「系统设置 › 隐私与安全性 › 辅助功能」中允许 Superconnect，然后重试"
        case .tunnelFailed:
            return "无法建立与设备的连接通道，请重新插拔后重试"
        case .connectionFailed:
            return "连接已断开，正在自动重连…"
        case .receiverNotSupported:
            return "此设备方向暂不支持（即将推出）"
        case .pairingRejected:
            return "平板未授权本机连接。请在平板上点「允许」配对后重试"
        case .wirelessUnreachable:
            return "多次连接超时，无法到达平板。若开启了 VPN/EasyConnect，请尝试关闭后重连，或确认平板 IP 与无线模式已开启"
        case .alreadyConnectedElsewhere:
            return "该平板已被另一连接占用（同一时间仅支持一条连接）。请先断开有线/无线中的另一条，再连接此设备"
        case .authFailed:
            return "此平板不再信任本 Mac（或密钥已变更）。请在平板上重新「允许」配对后重试"
        }
    }
}
