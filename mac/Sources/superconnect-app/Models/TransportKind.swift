import Foundation

/// How a device is reached. Drives the bottom-right badge on each device card, and
/// (later) which `TunnelService` is used. Each case owns its own label + SF Symbol so
/// the badge view stays dumb.
enum TransportKind: String, Codable, Hashable {
    case wired
    case wireless

    var badgeLabel: String {
        switch self {
        case .wired:    return "有线"
        case .wireless: return "无线"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .wired:    return "cable.connector"
        case .wireless: return "wifi"
        }
    }
}
