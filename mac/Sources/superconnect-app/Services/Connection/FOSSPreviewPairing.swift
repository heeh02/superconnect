import Foundation
import Security
import SuperconnectCore

final class FOSSPreviewPairSecretStore: PairSecretStore {
    private let service: String
    private let localPeerID: String

    init(localIdentity: PortableSessionIdentity, service: String = FOSSPreviewProduct.keychainService) {
        self.service = service
        self.localPeerID = localIdentity.rawValue
    }

    func secret(for peerId: String) -> Data? {
        var query = baseQuery(peerId: peerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    func storeIfAbsent(_ secret: Data, for peerId: String) -> PairSecretStoreWriteResult {
        guard secret.count == 32, !peerId.isEmpty else { return .unavailable }
        if let known = self.secret(for: peerId) {
            return known == secret ? .unchanged : .conflict
        }
        var item = baseQuery(peerId: peerId)
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return .inserted }
        if status == errSecDuplicateItem, let known = self.secret(for: peerId) {
            return known == secret ? .unchanged : .conflict
        }
        return .unavailable
    }

    func remove(for peerId: String) {
        SecItemDelete(baseQuery(peerId: peerId) as CFDictionary)
    }

    private func baseQuery(peerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(for: peerId),
        ]
    }

    func keychainAccount(for peerId: String) -> String {
        "\(localPeerID):\(peerId)"
    }
}

struct FOSSPreviewSessionFactory {
    let localIdentity: PortableSessionIdentity
    let secretStore: any PairSecretStore

    static let live: FOSSPreviewSessionFactory = {
        let defaults = UserDefaults.standard
        let key = FOSSPreviewProduct.localIdentityDefaultsKey
        if let stored = defaults.string(forKey: key),
           let identity = try? PortableSessionIdentity(stored) {
            return FOSSPreviewSessionFactory(
                localIdentity: identity,
                secretStore: FOSSPreviewPairSecretStore(localIdentity: identity)
            )
        }
        let value = "mac-foss-" + UUID().uuidString.lowercased()
        let identity = try! PortableSessionIdentity(value)
        defaults.set(value, forKey: key)
        return FOSSPreviewSessionFactory(
            localIdentity: identity,
            secretStore: FOSSPreviewPairSecretStore(localIdentity: identity)
        )
    }()

    var collaborationIntent: CollaborationIntentDraft {
        CollaborationIntentDraft(
            localRole: .source,
            sourceTopology: .extend,
            sinkPresentation: .windowed,
            inputPolicy: FOSSPreviewProduct.inputPolicy,
            transportPreference: FOSSPreviewProduct.transport,
            topology: .direct
        )
    }

    func makeSession(transport: Transport) -> Session {
        let intent = collaborationIntent
        return Session(
            transport: transport,
            role: "mac",
            localIdentity: localIdentity,
            secretStore: secretStore,
            supportedMediaRoles: [.source],
            desiredMediaRole: .source,
            projectionMode: FOSSPreviewProduct.projection,
            udpVideoVersion: 0,
            authorizedCapabilities: .minimum(localRole: .source, projection: .extend),
            capabilityIntentProductProfile: .init(exact: .init(intent)),
            collaborationIntent: intent
        )
    }
}
