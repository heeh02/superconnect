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

    var isBusy: Bool { self == .connecting }
    var isConnected: Bool { self == .connected }
}
