package com.superconnect.receiver

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec

/** Stable non-exportable AndroidKeyStore identity for the separate FOSS package. */
internal object FossDeviceIdentity {
    fun peerId(): String {
        val publicKey = loadOrCreatePublicKey()
        val digest = try {
            MessageDigest.getInstance("SHA-256").digest(publicKey)
        } finally {
            publicKey.fill(0)
        }
        return try {
            "android-foss-" + Base64.encodeToString(
                digest,
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
        } finally {
            digest.fill(0)
        }
    }

    private fun loadOrCreatePublicKey(): ByteArray {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        store.getCertificate(KEY_ALIAS)?.publicKey?.encoded?.let { return it.copyOf() }

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        generator.initialize(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        return generator.generateKeyPair().public.encoded.copyOf()
    }

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "sc_foss_device_identity_v1"
}
