import Foundation

/// The de-jargoned, user-facing connection state the whole UI binds to. Deliberately has
/// NO fps / codec / bitrate — those live only in `SessionTelemetry`. The host pipeline's
/// internal phases (tunneling / waiting / streaming) collapse into these.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case needsPermission(AppError)
    case failed(AppError)
    /// The tablet refused this connection because it is already serving another link (single-active
    /// session). Terminal like `.failed`, but a distinct, calm state — the user disconnects the other
    /// link (or the other transport) rather than retrying. See docs/CONFLICTS.md.
    case blocked(AppError)

    var isBusy: Bool { self == .connecting }
    var isConnected: Bool { self == .connected }
}
