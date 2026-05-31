import Foundation

/// A discovered peer. Carries three orthogonal facts (identity, how it's reached, what
/// it can do) plus the badge-driving transport. The UI reads only `name` + `transport`
/// today; `capabilities` and `endpoint` are plumbing for the symmetric future and the
/// connection coordinator respectively.
struct Device: Identifiable, Hashable {
    /// Stable peer identity — the hdc serial today (e.g. "<DEVICE-SERIAL>"), an
    /// ip/Bonjour name later. Used to collapse the same device seen on >1 transport.
    let id: String
    /// Friendly display name; falls back to the serial today.
    var name: String
    /// Drives the bottom-right wired/wireless badge.
    var transport: TransportKind
    /// What the device can do (symmetric-future field; tablets are `.canReceive` today).
    var capabilities: RoleCapabilities
    /// How the coordinator reaches it.
    var endpoint: Endpoint
}
