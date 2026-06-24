import Foundation
import Security

/// Per-pair secret persistence for the SC-AUTH-v1 trust contract (H4). The 32-byte secret is the only
/// thing that authenticates a paired peer, so it lives in the system secure store — never plaintext
/// UserDefaults. Decoupled behind a protocol so `Session`/handshake depends on the abstraction (and
/// tests/previews use the in-memory impl), not on Keychain directly.
public protocol PairSecretStore: AnyObject {
    /// The stored secret for a peer id, or nil if this peer isn't enrolled (→ caller must (re)pair).
    func secret(for peerId: String) -> Data?
    /// Persist (replacing any existing) the per-pair secret.
    func store(_ secret: Data, for peerId: String)
    /// Forget a peer (e.g. user removed the device / re-pair).
    func remove(for peerId: String)
}

/// Production store: a Keychain generic-password item per peer, this-device-only.
public final class KeychainPairSecretStore: PairSecretStore {
    private let service: String
    public init(service: String = "com.superconnect.pairsecret") { self.service = service }

    private func baseQuery(_ peerId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: peerId]
    }

    public func secret(for peerId: String) -> Data? {
        var q = baseQuery(peerId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func store(_ secret: Data, for peerId: String) {
        remove(for: peerId)   // upsert: SecItemAdd fails on a duplicate, so clear first
        var q = baseQuery(peerId)
        q[kSecValueData as String] = secret
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public func remove(for peerId: String) {
        SecItemDelete(baseQuery(peerId) as CFDictionary)
    }
}

/// In-memory store for tests/previews (and a safe fallback). Thread-safe.
public final class InMemoryPairSecretStore: PairSecretStore {
    private var map: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func secret(for peerId: String) -> Data? { lock.lock(); defer { lock.unlock() }; return map[peerId] }
    public func store(_ secret: Data, for peerId: String) { lock.lock(); map[peerId] = secret; lock.unlock() }
    public func remove(for peerId: String) { lock.lock(); map[peerId] = nil; lock.unlock() }
}
