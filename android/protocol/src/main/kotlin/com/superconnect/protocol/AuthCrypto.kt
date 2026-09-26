package com.superconnect.protocol

import java.security.SecureRandom

/** Product SC-AUTH-v1 surface. Deterministic crypto and identity validation are Rust-authoritative. */
object AuthCrypto {
    val PAIR_INFO: ByteArray = "SC-PAIR-v1".toByteArray(Charsets.UTF_8)

    fun isValidPeerId(peerId: String): Boolean =
        AuthNative.nativeValidatePeerId(peerId.toByteArray(Charsets.UTF_8))

    fun createProof(
        secret: ByteArray,
        proverPeerId: String,
        verifierPeerId: String,
        nonce: ByteArray,
    ): ByteArray = AuthNative.nativeCreateProof(
        secret,
        proverPeerId.toByteArray(Charsets.UTF_8),
        verifierPeerId.toByteArray(Charsets.UTF_8),
        nonce,
    )

    fun verifyProof(
        proof: ByteArray,
        secret: ByteArray,
        proverPeerId: String,
        verifierPeerId: String,
        nonce: ByteArray,
    ): Boolean = AuthNative.nativeVerifyProof(
        proof,
        secret,
        proverPeerId.toByteArray(Charsets.UTF_8),
        verifierPeerId.toByteArray(Charsets.UTF_8),
        nonce,
    )

    fun deriveEcdhKey(myScalar: ByteArray, peerPubX963: ByteArray, salt: ByteArray): ByteArray =
        AuthNative.nativeDerivePairKey(myScalar, peerPubX963, salt)

    fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        require(aad.contentEquals(PAIR_INFO)) { "unsupported auth AAD" }
        return AuthNative.nativeSealPairSecret(plaintext, key, nonce)
    }

    fun open(encSecret: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray): ByteArray {
        require(aad.contentEquals(PAIR_INFO)) { "unsupported auth AAD" }
        return AuthNative.nativeOpenPairSecret(encSecret, key, nonce)
    }

    /** Platform entropy chooses the scalar; Rust validates it and computes the public key. */
    fun newEphemeralKeyPair(): Pair<ByteArray, ByteArray> {
        repeat(128) {
            val scalar = randomBytes(32)
            try {
                return Pair(scalar, AuthNative.nativePublicFromPrivate(scalar))
            } catch (_: IllegalArgumentException) {
                scalar.fill(0)
            }
        }
        error("failed to generate ephemeral key")
    }

    fun randomBytes(n: Int): ByteArray {
        require(n >= 0) { "negative random byte count" }
        return ByteArray(n).also { SecureRandom().nextBytes(it) }
    }

    fun newSecret(): ByteArray = randomBytes(32)

}
