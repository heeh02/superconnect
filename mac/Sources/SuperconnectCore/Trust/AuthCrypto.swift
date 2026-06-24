import Foundation
import CryptoKit

/// Crypto primitives for the SC-AUTH-v1 wireless trust contract (audit H4/M10 fix). Decoupled leaf:
/// pure functions, no transport/session/Keychain dependency, so it can be unit-tested against the
/// cross-language golden vectors in `proto/auth-vectors.json` (every platform must reproduce them).
///
/// Trust model: a 32-byte per-pair `secret` is established at pairing (never sent in clear — delivered
/// P-256-ECDH-encrypted). Every later connect proves possession via HMAC-SHA256 over a fresh nonce,
/// so a sniffed/replayed handshake can't impersonate a paired peer. See proto/AUTH-SPEC.md.
public enum AuthCrypto {
    public static let authLabel = "SC-AUTH-v1"
    public static let pairInfo = Data("SC-PAIR-v1".utf8)   // HKDF info + AES-GCM AAD

    public enum AuthError: Error { case badCiphertext, badKeyLength }

    // MARK: - HMAC challenge-response (steady state)

    /// HMAC-SHA256(secret, UTF-8(context)).
    public static func hmac(secret: Data, context: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(context.utf8), using: SymmetricKey(data: secret)))
    }

    /// Constant-time verification of a peer's proof.
    public static func verify(proof: Data, secret: Data, context: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(context.utf8),
                                               using: SymmetricKey(data: secret))
    }

    /// Mac→Pad proof context. peerId order + label are domain separation so a proof can't be replayed
    /// in the opposite direction or across protocols.
    public static func contextMac(macPeerId: String, tabletPeerId: String, nonceB64: String) -> String {
        "\(authLabel)|\(macPeerId)|\(tabletPeerId)|\(nonceB64)"
    }
    /// Pad→Mac proof context (peer order swapped).
    public static func contextPad(macPeerId: String, tabletPeerId: String, macNonceB64: String) -> String {
        "\(authLabel)|\(tabletPeerId)|\(macPeerId)|\(macNonceB64)"
    }

    // MARK: - P-256 ECDH + HKDF (enrollment key agreement)
    // NIST P-256 (not X25519): uniformly available at each platform's min version (Android JCA "ECDH"
    // works at minSdk 24; "XDH"/X25519 needs API 33+). Private key = 32-byte big-endian scalar
    // (rawRepresentation); public key = x9.63 uncompressed 0x04‖X‖Y (65 bytes, x963Representation).

    /// Derive the 32-byte AEAD key from our P-256 private scalar + the peer's x9.63 public key via HKDF-SHA256.
    public static func deriveEcdhKey(myPrivRaw: Data, peerPubRaw: Data, salt: Data) throws -> SymmetricKey {
        let priv = try P256.KeyAgreement.PrivateKey(rawRepresentation: myPrivRaw)
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: peerPubRaw)
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)   // 32-byte X coordinate
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: pairInfo, outputByteCount: 32)
    }

    // MARK: - AES-256-GCM (enrollment secret transport). encSecret = ciphertext ‖ tag(16).

    public static func seal(plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }
    public static func open(encSecret: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        guard encSecret.count >= 16 else { throw AuthError.badCiphertext }
        let ct = encSecret.prefix(encSecret.count - 16)
        let tag = encSecret.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - Keygen / CSPRNG

    /// Fresh ephemeral P-256 keypair: priv = 32-byte scalar (rawRepresentation), pub = x9.63 65-byte 0x04‖X‖Y.
    public static func newEphemeralKeyPair() -> (priv: Data, pub: Data) {
        let p = P256.KeyAgreement.PrivateKey()
        return (p.rawRepresentation, p.publicKey.x963Representation)
    }

    /// `n` cryptographically-random bytes (SystemRandomNumberGenerator is a CSPRNG on Apple platforms).
    public static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in g.next() as UInt8 })
    }
    /// A fresh 32-byte per-pair secret.
    public static func newSecret() -> Data { randomBytes(32) }
}
