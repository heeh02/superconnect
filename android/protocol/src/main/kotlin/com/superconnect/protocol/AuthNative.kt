package com.superconnect.protocol

/** Thin JNI declarations for the portable Rust SC-AUTH-v1 ABI. */
internal object AuthNative {
    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1) { "unsupported Superconnect auth ABI" }
    }

    external fun nativeAbiVersion(): Int
    external fun nativeValidatePeerId(peerIdUtf8: ByteArray): Boolean
    external fun nativeCreateProof(
        secret: ByteArray,
        proverPeerIdUtf8: ByteArray,
        verifierPeerIdUtf8: ByteArray,
        nonce: ByteArray,
    ): ByteArray
    external fun nativeVerifyProof(
        proof: ByteArray,
        secret: ByteArray,
        proverPeerIdUtf8: ByteArray,
        verifierPeerIdUtf8: ByteArray,
        nonce: ByteArray,
    ): Boolean
    external fun nativePublicFromPrivate(privateScalar: ByteArray): ByteArray
    external fun nativeDerivePairKey(
        privateScalar: ByteArray,
        peerPublicKey: ByteArray,
        pairingSalt: ByteArray,
    ): ByteArray
    external fun nativeSealPairSecret(secret: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray
    external fun nativeOpenPairSecret(sealed: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray
}
