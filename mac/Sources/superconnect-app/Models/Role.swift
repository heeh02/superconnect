import Foundation

/// The direction of a live connection. `.host` (capture + send our screen) is the only
/// role implemented today; `.receiver` (display an incoming stream) is the symmetric
/// future, wired up as a stub so it becomes a one-line change to enable.
enum Role: String, Codable {
    case host
    case receiver
}

/// What a device is *capable* of — the symmetric end-goal where a peer may be both a
/// source and a sink. Today every discovered tablet is published as `.canReceive` only
/// (the Mac hosts, the tablet receives). The OptionSet exists precisely so a hosting
/// MatePad or a richer peer gains capabilities later with ZERO model change.
struct RoleCapabilities: OptionSet, Codable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let canHost    = RoleCapabilities(rawValue: 1 << 0)
    static let canReceive = RoleCapabilities(rawValue: 1 << 1)
    static let both: RoleCapabilities = [.canHost, .canReceive]
}
