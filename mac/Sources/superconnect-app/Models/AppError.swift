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
        }
    }
}
