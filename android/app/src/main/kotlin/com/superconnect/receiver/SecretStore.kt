package com.superconnect.receiver

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secure persistence of the SC-AUTH-v1 per-pair `secret` (32 random bytes) keyed by the Mac's `peerId`.
 *
 * FRAMEWORK-ONLY (no external deps): the secret is sealed with AES-256-GCM under a hardware-backed
 * AndroidKeyStore key (alias [KEY_ALIAS]) and the sealed blob (iv‖ciphertext‖tag, base64) is stored in a
 * plain SharedPreferences keyed by peerId (the peerId is NOT sensitive — only the secret is). This gives
 * the same confidentiality as Jetpack `EncryptedSharedPreferences` WITHOUT the `androidx.security-crypto`
 * dependency, which is a deprecated ALPHA that threw at runtime on keystore invalidation / prefs
 * corruption — a `SecretStore` throw here
 * crashed the wireless handshake (gate → secret()) → "black screen / can't connect".
 *
 * DEFENSIVE CONTRACT: every method is wrapped so it NEVER throws into the handshake. On any keystore or
 * crypto failure it degrades to "not paired" (return null / empty / skip), so a flaky keystore or a
 * corrupted entry turns into a one-time re-pair, never a failed connection. Mirrors HarmonyOS's
 * `@ohos.security.asset` SecretStore and macOS Keychain. Stores base64(iv‖ct) per peerId.
 */
internal class SecretStore internal constructor(
    private val prefs: SharedPreferences,
    private val encodeSecret: (ByteArray) -> String?,
    private val decodeSecret: (String) -> ByteArray?,
) : PairSecretStore {
    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
        { encodeWithAndroidKeyStore(it) },
        { decodeWithAndroidKeyStore(it) },
    )

    /** The stored secret for [peerId], or null if this Mac isn't enrolled (or the entry is unreadable). */
    override fun secret(peerId: String): ByteArray? = synchronized(PROCESS_LOCK) {
        val plaintext = decodeSecretLocked(peerId) ?: return@synchronized null
        try {
            plaintext.copyOf()
        } finally {
            plaintext.fill(0)
        }
    }

    /** Returns an owned temporary. Every caller must overwrite it in a finally block. */
    private fun decodeSecretLocked(peerId: String): ByteArray? {
        if (peerId.isEmpty()) return null
        val blob = try { prefs.getString(peerId, null) } catch (_: Exception) { null } ?: return null
        return try { decodeSecret(blob) } catch (_: Exception) { null }
    }

    /** Insert once across every in-process SecretStore owner of the same prefs/key. */
    override fun storeIfAbsent(
        secret: ByteArray,
        peerId: String,
    ): PairSecretWriteResult = synchronized(PROCESS_LOCK) {
        if (peerId.isEmpty() || secret.isEmpty()) return@synchronized PairSecretWriteResult.Unavailable
        val existing = decodeSecretLocked(peerId)
        try {
            if (existing != null) {
                return@synchronized if (existing.contentEquals(secret)) PairSecretWriteResult.Unchanged
                else PairSecretWriteResult.Conflict
            }
        } finally {
            existing?.fill(0)
        }
        val encodingInput = secret.copyOf()
        val blob = try {
            try { encodeSecret(encodingInput) } catch (_: Exception) { null }
        } finally {
            encodingInput.fill(0)
        } ?: return@synchronized PairSecretWriteResult.Unavailable
        val committed = try { prefs.edit().putString(peerId, blob).commit() } catch (_: Exception) {
            false
        }
        if (!committed) return@synchronized PairSecretWriteResult.Unavailable
        val persisted = decodeSecretLocked(peerId)
        try {
            when {
                persisted == null -> PairSecretWriteResult.Unavailable
                persisted.contentEquals(secret) -> PairSecretWriteResult.Inserted
                else -> PairSecretWriteResult.Conflict
            }
        } finally {
            persisted?.fill(0)
        }
    }

    fun store(secret: ByteArray, peerId: String): Boolean {
        return when (storeIfAbsent(secret, peerId)) {
            PairSecretWriteResult.Inserted, PairSecretWriteResult.Unchanged -> true
            PairSecretWriteResult.Conflict, PairSecretWriteResult.Unavailable -> false
        }
    }

    /** Forget the secret for [peerId] (e.g. user un-pairs the Mac) → next connect re-enrolls. */
    override fun remove(peerId: String) = synchronized(PROCESS_LOCK) {
        if (peerId.isEmpty()) return@synchronized
        try { prefs.edit().remove(peerId).commit() } catch (_: Exception) { /* best-effort */ }
    }

    /** The set of enrolled Mac peerIds (the prefs keys) — for the "已配对设备" UI list. Defensive copy. */
    fun peers(): Set<String> = synchronized(PROCESS_LOCK) {
        try { HashSet(prefs.all.keys) } catch (_: Exception) { emptySet() }
    }

    private companion object {
        private val PROCESS_LOCK = Any()

        /** Get-or-create the AES-256-GCM AndroidKeyStore key, or null when unavailable. */
        private fun secretKey(): SecretKey? = try {
            val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey ?: run {
                val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
                kg.init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build()
                )
                kg.generateKey()
            }
        } catch (_: Exception) { null }

        private fun decodeWithAndroidKeyStore(blob: String): ByteArray? {
            var raw: ByteArray? = null
            var iv: ByteArray? = null
            var ciphertext: ByteArray? = null
            return try {
                raw = Base64.decode(blob, Base64.NO_WRAP)
                val key = secretKey() ?: return null
                if (raw.size <= GCM_IV_LEN) return null
                iv = raw.copyOfRange(0, GCM_IV_LEN)
                ciphertext = raw.copyOfRange(GCM_IV_LEN, raw.size)
                val cipher = Cipher.getInstance(TRANSFORM)
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
                cipher.doFinal(ciphertext)
            } catch (_: Exception) {
                null
            } finally {
                ciphertext?.fill(0)
                iv?.fill(0)
                raw?.fill(0)
            }
        }

        private fun encodeWithAndroidKeyStore(secret: ByteArray): String? {
            var iv: ByteArray? = null
            var ciphertext: ByteArray? = null
            var sealed: ByteArray? = null
            return try {
                val key = secretKey() ?: return null
                val cipher = Cipher.getInstance(TRANSFORM)
                cipher.init(Cipher.ENCRYPT_MODE, key)
                iv = cipher.iv
                ciphertext = cipher.doFinal(secret)
                sealed = ByteArray(iv.size + ciphertext.size)
                System.arraycopy(iv, 0, sealed, 0, iv.size)
                System.arraycopy(ciphertext, 0, sealed, iv.size, ciphertext.size)
                Base64.encodeToString(sealed, Base64.NO_WRAP)
            } catch (_: Exception) {
                null
            } finally {
                sealed?.fill(0)
                ciphertext?.fill(0)
                iv?.fill(0)
            }
        }

        // Fresh prefs file (v2): the old "sc_secrets" was an EncryptedSharedPreferences store with an
        // incompatible on-disk format; reading it with plain prefs would surface encrypted-key garbage.
        // A clean file means enrolled Macs re-pair once (the H4 secret is a short-lived credential anyway).
        const val PREFS = "sc_secrets_v2"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "sc_secret_key"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val GCM_IV_LEN = 12
        const val GCM_TAG_BITS = 128
    }
}
