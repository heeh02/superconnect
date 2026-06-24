import SwiftUI

/// View-layer presentation of `ConnectionState` — the SINGLE source of truth for a state's color and
/// short label, so `StatusDot`, sidebar tooltips, headers, etc. never re-derive them independently
/// (the colors used to be duplicated across `StatusDot` and per-row code). Pure View code: reads only
/// the enum, touches no service.
extension ConnectionState {
    /// Semantic status color. green=已连接, orange=连接中, red=需注意, gray=被占用, blue=可连接.
    var dotColor: Color {
        switch self {
        case .connected:                return .green
        case .connecting:               return .orange
        case .needsPermission, .failed: return .red
        case .blocked:                  return .gray
        case .idle:                     return .blue
        }
    }

    /// Short user-facing label (Chinese) for tooltips/headers. The DETAILED error text stays in
    /// `AppError.userMessage` — this is just the one-word status.
    var shortLabel: String {
        switch self {
        case .connected:       return "已连接"
        case .connecting:      return "连接中…"
        case .needsPermission: return "需要权限"
        case .failed:          return "连接失败"
        case .blocked:         return "被占用"
        case .idle:            return "可连接"
        }
    }
}
