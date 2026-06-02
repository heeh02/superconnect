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
    /// Wireless proximity-pairing token obtained over BLE (nil for wired/mDNS/manual). When present,
    /// the Mac presents it in the Wi-Fi `hello` and the tablet auto-trusts this Mac (closes the
    /// cleartext-peerId replay gap). Orthogonal to `endpoint`, like `capabilities`.
    var pairingToken: String? = nil
}
