import Foundation

/// Quarantined technical detail: the stream stats. Read ONLY by the optional, collapsed
/// "高级" disclosure — never referenced anywhere in the main user flow. Keeping this in
/// its own type is how we honor "no technical details" while still exposing stats to the
/// curious.
struct SessionTelemetry: Equatable {
    var fps: Int = 0
    var resolution: String = "—"
    var codec: String = "—"
    var bitrateMbps: Int = 0
}
