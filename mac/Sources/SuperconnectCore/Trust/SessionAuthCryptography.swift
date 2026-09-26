import Foundation
import CryptoKit

public enum SessionAuthBackend: Equatable, Sendable {
    case compatibility
    case rustCore
}

public enum SessionAuthCryptoField: Equatable, Sendable {
    case pairSecret
    case authNonce
    case proof
    case privateScalar
    case publicKey
    case pairingSalt
    case pairKey
    case aeadNonce
    case sealedSecret
}

public enum SessionAuthCryptoError: Error, Equatable, Sendable {
    case invalidLength(SessionAuthCryptoField)
    case invalidPeerID
    case invalidArgument
    case authenticationFailed
    case internalFailure(Int32)
}

/// The proof direction is semantic rather than an arbitrary preformatted context string. This keeps
/// prover/verifier ordering and the nonce owner explicit at the Session-to-crypto boundary.
public enum SessionAuthProofDirection: Equatable, Sendable {
    case macToTablet(macPeerID: String, tabletPeerID: String, tabletNonce: Data)
    case tabletToMac(macPeerID: String, tabletPeerID: String, macNonce: Data)

    var components: (proverID: String, verifierID: String, nonce: Data) {
        switch self {
        case .macToTablet(let macPeerID, let tabletPeerID, let tabletNonce):
            return (macPeerID, tabletPeerID, tabletNonce)
        case .tabletToMac(let macPeerID, let tabletPeerID, let macNonce):
            return (tabletPeerID, macPeerID, macNonce)
        }
    }
}

/// Pure, deterministic SC-AUTH-v1 operations consumed by Session. Entropy, private-scalar creation,
/// secure storage, JSON and handshake timing remain platform responsibilities.
public protocol SessionAuthCryptography {
    var backend: SessionAuthBackend { get }

    func validatePeerID(_ peerID: String) throws
    func publicKey(privateScalar: Data) throws -> Data
    func createProof(secret: Data, direction: SessionAuthProofDirection) throws -> Data
    func verifyProof(_ proof: Data, secret: Data, direction: SessionAuthProofDirection) throws
    func derivePairKey(privateScalar: Data, peerPublicKey: Data, salt: Data) throws -> Data
    func sealPairSecret(_ secret: Data, pairKey: Data, nonce: Data) throws -> Data
    func openPairSecret(_ sealedSecret: Data, pairKey: Data, nonce: Data) throws -> Data
}

public enum SessionAuthCryptographyProvider {
    public static var active: any SessionAuthCryptography {
        RustSessionAuthCryptography()
    }
}

/// Compatibility/KAT oracle. Product builds select the Rust implementation above;
/// ordinary Swift tests retain this implementation to prove byte and error parity.
struct SwiftSessionAuthCryptography: SessionAuthCryptography {
    let backend = SessionAuthBackend.compatibility

    func validatePeerID(_ peerID: String) throws {
        let bytes = Data(peerID.utf8)
        guard !bytes.isEmpty, bytes.count <= 128,
              !peerID.unicodeScalars.contains(where: {
                  $0.value == 0x7C || $0.value <= 0x1F || (0x7F...0x9F).contains($0.value)
              })
        else { throw SessionAuthCryptoError.invalidPeerID }
    }

    func publicKey(privateScalar: Data) throws -> Data {
        try require(privateScalar, count: 32, field: .privateScalar)
        do {
            return try AuthCrypto.publicKey(privateScalar: privateScalar)
        } catch {
            throw SessionAuthCryptoError.invalidArgument
        }
    }

    func createProof(secret: Data, direction: SessionAuthProofDirection) throws -> Data {
        try require(secret, count: 32, field: .pairSecret)
        let parts = direction.components
        try validatePeerID(parts.proverID)
        try validatePeerID(parts.verifierID)
        try require(parts.nonce, count: 32, field: .authNonce)
        return AuthCrypto.hmac(secret: secret, context: context(direction))
    }

    func verifyProof(_ proof: Data, secret: Data, direction: SessionAuthProofDirection) throws {
        try require(proof, count: 32, field: .proof)
        _ = try createProof(secret: secret, direction: direction)
        guard AuthCrypto.verify(proof: proof, secret: secret, context: context(direction)) else {
            throw SessionAuthCryptoError.authenticationFailed
        }
    }

    func derivePairKey(privateScalar: Data, peerPublicKey: Data, salt: Data) throws -> Data {
        try require(privateScalar, count: 32, field: .privateScalar)
        try require(peerPublicKey, count: 65, field: .publicKey)
        try require(salt, count: 16, field: .pairingSalt)
        do {
            let key = try AuthCrypto.deriveEcdhKey(
                myPrivRaw: privateScalar, peerPubRaw: peerPublicKey, salt: salt
            )
            return key.withUnsafeBytes { Data($0) }
        } catch {
            throw SessionAuthCryptoError.invalidArgument
        }
    }

    func sealPairSecret(_ secret: Data, pairKey: Data, nonce: Data) throws -> Data {
        try require(secret, count: 32, field: .pairSecret)
        try require(pairKey, count: 32, field: .pairKey)
        try require(nonce, count: 12, field: .aeadNonce)
        do {
            return try AuthCrypto.seal(
                plaintext: secret, key: SymmetricKey(data: pairKey), nonce: nonce,
                aad: AuthCrypto.pairInfo
            )
        } catch {
            throw SessionAuthCryptoError.internalFailure(-1)
        }
    }

    func openPairSecret(_ sealedSecret: Data, pairKey: Data, nonce: Data) throws -> Data {
        try require(sealedSecret, count: 48, field: .sealedSecret)
        try require(pairKey, count: 32, field: .pairKey)
        try require(nonce, count: 12, field: .aeadNonce)
        do {
            return try AuthCrypto.open(
                encSecret: sealedSecret, key: SymmetricKey(data: pairKey), nonce: nonce,
                aad: AuthCrypto.pairInfo
            )
        } catch {
            throw SessionAuthCryptoError.authenticationFailed
        }
    }

    private func context(_ direction: SessionAuthProofDirection) -> String {
        switch direction {
        case .macToTablet(let macPeerID, let tabletPeerID, let nonce):
            return AuthCrypto.contextMac(
                macPeerId: macPeerID, tabletPeerId: tabletPeerID,
                nonceB64: nonce.base64EncodedString()
            )
        case .tabletToMac(let macPeerID, let tabletPeerID, let nonce):
            return AuthCrypto.contextPad(
                macPeerId: macPeerID, tabletPeerId: tabletPeerID,
                macNonceB64: nonce.base64EncodedString()
            )
        }
    }

    private func require(_ value: Data, count: Int, field: SessionAuthCryptoField) throws {
        guard value.count == count else { throw SessionAuthCryptoError.invalidLength(field) }
    }
}
