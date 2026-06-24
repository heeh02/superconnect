import XCTest
import CryptoKit
@testable import SuperconnectCore

/// Asserts the Swift AuthCrypto reproduces the cross-language golden vectors in proto/auth-vectors.json
/// (HMAC-SHA256, P-256 ECDH + HKDF-SHA256, AES-256-GCM). If these pass on Swift, HarmonyOS
/// (cryptoFramework) and Android (javax.crypto) only need to reproduce the SAME vectors to be guaranteed
/// wire-interoperable — without any live-device test.
final class AuthCryptoTests: XCTestCase {

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return d
    }
    private func b64(_ s: String) -> Data { Data(base64Encoded: s)! }
    private func keyBytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    private lazy var vectors: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SuperconnectCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("proto/auth-vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    func testHmacGoldenVector() {
        let h = vectors["hmac"] as! [String: Any]
        let secret = hex(h["secretHex"] as! String)
        // contexts must be byte-identical across platforms
        let ctxMac = AuthCrypto.contextMac(macPeerId: h["macPeerId"] as! String,
                                           tabletPeerId: h["tabletPeerId"] as! String,
                                           nonceB64: h["nonceB64"] as! String)
        XCTAssertEqual(ctxMac, h["contextMac"] as! String)
        let ctxPad = AuthCrypto.contextPad(macPeerId: h["macPeerId"] as! String,
                                           tabletPeerId: h["tabletPeerId"] as! String,
                                           macNonceB64: h["macNonceB64"] as! String)
        XCTAssertEqual(ctxPad, h["contextPad"] as! String)
        // proofs match the golden HMAC
        XCTAssertEqual(AuthCrypto.hmac(secret: secret, context: ctxMac).base64EncodedString(),
                       h["proofMacB64"] as! String)
        XCTAssertEqual(AuthCrypto.hmac(secret: secret, context: ctxPad).base64EncodedString(),
                       h["proofPadB64"] as! String)
        // verify() accepts the golden proof and rejects a tampered one
        XCTAssertTrue(AuthCrypto.verify(proof: b64(h["proofMacB64"] as! String), secret: secret, context: ctxMac))
        XCTAssertFalse(AuthCrypto.verify(proof: b64(h["proofPadB64"] as! String), secret: secret, context: ctxMac))
    }

    func testEcdhHkdfGoldenVector() throws {
        let e = vectors["ecdh"] as! [String: Any]
        // Mac derives the SAME ecdh key from its private scalar + tablet's public.
        let key = try AuthCrypto.deriveEcdhKey(myPrivRaw: hex(e["macEphScalarHex"] as! String),
                                               peerPubRaw: b64(e["tabletEphPubB64"] as! String),
                                               salt: b64(e["saltB64"] as! String))
        XCTAssertEqual(keyBytes(key).map { String(format: "%02x", $0) }.joined(), e["ecdhKeyHex"] as! String)
        // And from the tablet's scalar + Mac's public (must agree, both directions).
        let key2 = try AuthCrypto.deriveEcdhKey(myPrivRaw: hex(e["tabletEphScalarHex"] as! String),
                                                peerPubRaw: b64(e["macEphPubB64"] as! String),
                                                salt: b64(e["saltB64"] as! String))
        XCTAssertEqual(keyBytes(key2), keyBytes(key))
    }

    func testAesGcmGoldenVector() throws {
        let e = vectors["ecdh"] as! [String: Any]
        let key = SymmetricKey(data: hex(e["ecdhKeyHex"] as! String))
        let nonce = b64(e["aeadNonceB64"] as! String)
        let aad = Data((e["aeadAad"] as! String).utf8)
        // open the golden ciphertext → the plaintext secret
        let opened = try AuthCrypto.open(encSecret: b64(e["encSecretB64"] as! String),
                                         key: key, nonce: nonce, aad: aad)
        XCTAssertEqual(opened.map { String(format: "%02x", $0) }.joined(), e["plaintextSecretHex"] as! String)
        // seal the secret with the fixed nonce → exactly the golden ciphertext (deterministic)
        let sealed = try AuthCrypto.seal(plaintext: hex(e["plaintextSecretHex"] as! String),
                                         key: key, nonce: nonce, aad: aad)
        XCTAssertEqual(sealed.base64EncodedString(), e["encSecretB64"] as! String)
    }

    func testRoundTripFreshKeys() throws {
        // End-to-end with fresh ephemeral keys: tablet seals a secret, Mac opens it.
        let secret = AuthCrypto.newSecret()
        let mac = AuthCrypto.newEphemeralKeyPair()
        let tab = AuthCrypto.newEphemeralKeyPair()
        let salt = AuthCrypto.randomBytes(16), nonce = AuthCrypto.randomBytes(12)
        let tabKey = try AuthCrypto.deriveEcdhKey(myPrivRaw: tab.priv, peerPubRaw: mac.pub, salt: salt)
        let enc = try AuthCrypto.seal(plaintext: secret, key: tabKey, nonce: nonce, aad: AuthCrypto.pairInfo)
        let macKey = try AuthCrypto.deriveEcdhKey(myPrivRaw: mac.priv, peerPubRaw: tab.pub, salt: salt)
        let opened = try AuthCrypto.open(encSecret: enc, key: macKey, nonce: nonce, aad: AuthCrypto.pairInfo)
        XCTAssertEqual(opened, secret)
    }
}
