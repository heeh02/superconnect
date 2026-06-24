package com.superconnect.protocol

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * Android (Kotlin/JVM) reproduces the cross-language golden vectors in proto/auth-vectors.json so its
 * AuthCrypto is wire-interoperable with Swift CryptoKit + HarmonyOS cryptoFramework — verified off-device:
 *   ./gradlew :protocol:test
 */
class AuthCryptoTest {
    private fun vectors(): JSONObject {
        var dir: File? = File(System.getProperty("user.dir"))
        while (dir != null && !File(dir, "proto/auth-vectors.json").exists()) dir = dir.parentFile
        requireNotNull(dir) { "proto/auth-vectors.json not found above ${System.getProperty("user.dir")}" }
        return JSONObject(File(dir, "proto/auth-vectors.json").readText())
    }
    private fun unhex(s: String) = ByteArray(s.length / 2) {
        ((Character.digit(s[it * 2], 16) shl 4) or Character.digit(s[it * 2 + 1], 16)).toByte()
    }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun b64(s: String) = Base64.getDecoder().decode(s)
    private fun b64e(b: ByteArray) = Base64.getEncoder().encodeToString(b)

    @Test fun hmacGolden() {
        val h = vectors().getJSONObject("hmac")
        val secret = unhex(h.getString("secretHex"))
        val ctxMac = AuthCrypto.contextMac(h.getString("macPeerId"), h.getString("tabletPeerId"), h.getString("nonceB64"))
        assertEquals(h.getString("contextMac"), ctxMac)
        assertEquals(h.getString("proofMacB64"), b64e(AuthCrypto.hmac(secret, ctxMac)))
        val ctxPad = AuthCrypto.contextPad(h.getString("macPeerId"), h.getString("tabletPeerId"), h.getString("macNonceB64"))
        assertEquals(h.getString("contextPad"), ctxPad)
        assertEquals(h.getString("proofPadB64"), b64e(AuthCrypto.hmac(secret, ctxPad)))
        assertTrue(AuthCrypto.verify(b64(h.getString("proofMacB64")), secret, ctxMac))
        assertFalse(AuthCrypto.verify(b64(h.getString("proofPadB64")), secret, ctxMac))   // wrong context
    }

    @Test fun ecdhHkdfGolden() {
        val e = vectors().getJSONObject("ecdh")
        val key = AuthCrypto.deriveEcdhKey(unhex(e.getString("macEphScalarHex")), b64(e.getString("tabletEphPubB64")), b64(e.getString("saltB64")))
        assertEquals(e.getString("ecdhKeyHex"), hex(key))
        val key2 = AuthCrypto.deriveEcdhKey(unhex(e.getString("tabletEphScalarHex")), b64(e.getString("macEphPubB64")), b64(e.getString("saltB64")))
        assertArrayEquals(key, key2)   // both directions agree
    }

    @Test fun aesGcmGolden() {
        val e = vectors().getJSONObject("ecdh")
        val key = unhex(e.getString("ecdhKeyHex"))
        val nonce = b64(e.getString("aeadNonceB64"))
        val aad = e.getString("aeadAad").toByteArray(Charsets.UTF_8)
        assertEquals(e.getString("plaintextSecretHex"), hex(AuthCrypto.open(b64(e.getString("encSecretB64")), key, nonce, aad)))
        assertEquals(e.getString("encSecretB64"), b64e(AuthCrypto.seal(unhex(e.getString("plaintextSecretHex")), key, nonce, aad)))
    }

    @Test fun roundTripFreshKeys() {
        val secret = AuthCrypto.newSecret()
        val (macS, macP) = AuthCrypto.newEphemeralKeyPair()
        val (tabS, tabP) = AuthCrypto.newEphemeralKeyPair()
        val salt = AuthCrypto.randomBytes(16); val nonce = AuthCrypto.randomBytes(12)
        val enc = AuthCrypto.seal(secret, AuthCrypto.deriveEcdhKey(tabS, macP, salt), nonce, AuthCrypto.PAIR_INFO)
        assertArrayEquals(secret, AuthCrypto.open(enc, AuthCrypto.deriveEcdhKey(macS, tabP, salt), nonce, AuthCrypto.PAIR_INFO))
    }
}
