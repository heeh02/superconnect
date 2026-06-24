package com.superconnect.protocol

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Crypto for the SC-AUTH-v1 wireless trust contract (audit H4/M10 fix): a 32-byte per-pair secret
 * established at pairing (P-256-ECDH-encrypted) + HMAC-SHA256 challenge-response on every connect, so a
 * sniffed/replayed handshake can't impersonate a paired peer. Pure JVM (javax.crypto) so it is
 * conformance-tested off-device against proto/auth-vectors.json — reproducing the SAME golden vectors as
 * Swift CryptoKit + HarmonyOS cryptoFramework guarantees wire interop. P-256 (not X25519) because JCA
 * "ECDH" works at minSdk 24 while "XDH"/X25519 needs API 33+. Decoupled leaf: no transport/session dep.
 */
object AuthCrypto {
    const val AUTH_LABEL = "SC-AUTH-v1"
    val PAIR_INFO: ByteArray = "SC-PAIR-v1".toByteArray(Charsets.UTF_8)   // HKDF info + AES-GCM AAD

    // P-256 (secp256r1) domain parameters, fetched once.
    private val ecParams: ECParameterSpec by lazy {
        val p = AlgorithmParameters.getInstance("EC")
        p.init(ECGenParameterSpec("secp256r1"))
        p.getParameterSpec(ECParameterSpec::class.java)
    }

    // ---- HMAC challenge-response (steady state) ----
    fun hmac(secret: ByteArray, context: String): ByteArray {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(secret, "HmacSHA256"))
        return m.doFinal(context.toByteArray(Charsets.UTF_8))
    }

    /** Constant-time verification of a peer's proof. */
    fun verify(proof: ByteArray, secret: ByteArray, context: String): Boolean =
        MessageDigest.isEqual(proof, hmac(secret, context))

    fun contextMac(macPeerId: String, tabletPeerId: String, nonceB64: String): String =
        "$AUTH_LABEL|$macPeerId|$tabletPeerId|$nonceB64"

    fun contextPad(macPeerId: String, tabletPeerId: String, macNonceB64: String): String =
        "$AUTH_LABEL|$tabletPeerId|$macPeerId|$macNonceB64"

    // ---- P-256 ECDH + HKDF (enrollment key agreement) ----
    /** Derive the 32-byte AEAD key from our P-256 scalar + the peer's x9.63 (0x04||X||Y) public key. */
    fun deriveEcdhKey(myScalar: ByteArray, peerPubX963: ByteArray, salt: ByteArray): ByteArray {
        val kf = KeyFactory.getInstance("EC")
        val priv = kf.generatePrivate(ECPrivateKeySpec(BigInteger(1, myScalar), ecParams))
        val pub = kf.generatePublic(ECPublicKeySpec(decodeX963(peerPubX963), ecParams))
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(priv)
        ka.doPhase(pub, true)
        val shared = ka.generateSecret()   // 32-byte X coordinate (the ECDH Z value)
        return hkdfSha256(shared, salt, PAIR_INFO, 32)
    }

    // ---- AES-256-GCM (enrollment secret transport); ciphertext output = ct || 16-byte tag ----
    fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad)
        return c.doFinal(plaintext)
    }
    fun open(encSecret: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad)
        return c.doFinal(encSecret)
    }

    // ---- keygen / CSPRNG ----
    /** Fresh ephemeral P-256 keypair: (scalar 32B big-endian, public x9.63 65B 0x04||X||Y). */
    fun newEphemeralKeyPair(): Pair<ByteArray, ByteArray> {
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"))
        val kp = g.generateKeyPair()
        return Pair(toFixed((kp.private as ECPrivateKey).s, 32), encodeX963((kp.public as ECPublicKey).w))
    }
    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { SecureRandom().nextBytes(it) }
    fun newSecret(): ByteArray = randomBytes(32)

    // ---- helpers ----
    private fun toFixed(bi: BigInteger, len: Int): ByteArray {
        val b = bi.toByteArray()                 // may carry a leading 0x00 sign byte, or be short
        if (b.size == len) return b
        val out = ByteArray(len)
        if (b.size > len) System.arraycopy(b, b.size - len, out, 0, len)
        else System.arraycopy(b, 0, out, len - b.size, b.size)
        return out
    }
    private fun encodeX963(w: ECPoint): ByteArray {
        val out = ByteArray(65)
        out[0] = 0x04
        System.arraycopy(toFixed(w.affineX, 32), 0, out, 1, 32)
        System.arraycopy(toFixed(w.affineY, 32), 0, out, 33, 32)
        return out
    }
    private fun decodeX963(b: ByteArray): ECPoint {
        require(b.size == 65 && b[0].toInt() == 0x04) { "expected x9.63 uncompressed P-256 point (65B 0x04||X||Y)" }
        return ECPoint(BigInteger(1, b.copyOfRange(1, 33)), BigInteger(1, b.copyOfRange(33, 65)))
    }
    /** RFC 5869 HKDF-SHA256. */
    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = extract.doFinal(ikm)
        val out = ByteArray(len)
        var pos = 0; var t = ByteArray(0); var counter = 1
        while (pos < len) {
            val exp = Mac.getInstance("HmacSHA256")
            exp.init(SecretKeySpec(prk, "HmacSHA256"))
            exp.update(t); exp.update(info); exp.update(counter.toByte())
            t = exp.doFinal()
            val n = minOf(t.size, len - pos)
            System.arraycopy(t, 0, out, pos, n); pos += n; counter++
        }
        return out
    }
}
