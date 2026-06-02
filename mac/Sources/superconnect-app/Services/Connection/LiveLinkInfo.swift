import Foundation

/// A read-only snapshot of one live connection, handed to `ConnectionPolicy.admit` so the policy can
/// reason about conflicts WITHOUT reaching into `ConnectionCoordinator.ManagedConnection` internals
/// (the engine / tunnel / Combine bag stay private to the coordinator). `peerID` is nil until the
/// handshake confirms the cross-transport identity (Tier-2); the connect-time policy uses only
/// `physicalKey`. See docs/CONFLICTS.md.
struct LiveLinkInfo: Equatable {
    let deviceID: String
    let transport: TransportKind
    let physicalKey: PhysicalKey
    let peerID: String?
}
