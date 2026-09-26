import Foundation

/// Per-pair secret persistence for the SC-AUTH-v1 trust contract (H4). The 32-byte secret is the only
/// thing that authenticates a paired peer, so it lives in the system secure store — never plaintext
/// UserDefaults. Decoupled behind a protocol so `Session`/handshake depends on the abstraction (and
/// tests/previews use the in-memory impl), not on Keychain directly.
public protocol PairSecretStore: AnyObject {
    /// The stored secret for a peer id, or nil if this peer isn't enrolled (→ caller must (re)pair).
    func secret(for peerId: String) -> Data?
    /// Persist only when this peer has no credential. A different known secret is a conflict and is
    /// never overwritten implicitly; re-pair remains an explicit remove followed by enrollment.
    func storeIfAbsent(_ secret: Data, for peerId: String) -> PairSecretStoreWriteResult
    /// Forget a peer (e.g. user removed the device / re-pair).
    func remove(for peerId: String)
}

public enum PairSecretStoreWriteResult: Equatable, Sendable {
    case inserted
    case unchanged
    case conflict
    case unavailable
}

/// In-memory store for tests/previews (and a safe fallback). Thread-safe.
public final class InMemoryPairSecretStore: PairSecretStore {
    private var map: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func secret(for peerId: String) -> Data? { lock.lock(); defer { lock.unlock() }; return map[peerId] }
    public func storeIfAbsent(_ secret: Data, for peerId: String) -> PairSecretStoreWriteResult {
        lock.lock()
        defer { lock.unlock() }
        if let known = map[peerId] { return known == secret ? .unchanged : .conflict }
        map[peerId] = secret
        return .inserted
    }
    public func remove(for peerId: String) { lock.lock(); map[peerId] = nil; lock.unlock() }
}
