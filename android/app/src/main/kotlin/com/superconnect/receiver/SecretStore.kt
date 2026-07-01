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
 * dependency, which (a) broke the no-external-deps build (android/build-apk.sh) and (b) is a deprecated
 * ALPHA that threw at runtime on keystore-invalidation / prefs-corruption — a `SecretStore` throw here
 * crashed the wireless handshake (gate → secret()) → "black screen / can't connect".
 *
 * DEFENSIVE CONTRACT: every method is wrapped so it NEVER throws into the handshake. On any keystore or
 * crypto failure it degrades to "not paired" (return null / empty / skip), so a flaky keystore or a
 * corrupted entry turns into a one-time re-pair, never a failed connection. Mirrors HarmonyOS's
 * `@ohos.security.asset` SecretStore and macOS Keychain. Stores base64(iv‖ct) per peerId.
 */
class SecretStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Get-or-create the AES-256-GCM key in the AndroidKeyStore. null if the keystore is unavailable
     *  (extremely rare) — callers then treat every peer as un-enrolled rather than crashing. */
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
    } catch (e: Exception) { null }

    /** The stored secret for [peerId], or null if this Mac isn't enrolled (or the entry is unreadable). */
    @Synchronized fun secret(peerId: String): ByteArray? {
        if (peerId.isEmpty()) return null
        val blob = prefs.getString(peerId, null) ?: return null
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            val key = secretKey() ?: return null
            if (raw.size <= GCM_IV_LEN) return null
            val iv = raw.copyOfRange(0, GCM_IV_LEN)
            val ct = raw.copyOfRange(GCM_IV_LEN, raw.size)
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            c.doFinal(ct)
        } catch (e: Exception) { null }   // corrupt / undecryptable → treat as un-enrolled (re-pair)
    }

    /** Upsert the per-pair [secret] for [peerId]. On keystore failure it silently skips (caller re-enrolls). */
    @Synchronized fun store(secret: ByteArray, peerId: String) {
        if (peerId.isEmpty()) return
        try {
            val key = secretKey() ?: return
            val c = Cipher.getInstance(TRANSFORM)
            c.init(Cipher.ENCRYPT_MODE, key)      // AndroidKeyStore GCM: provider MUST generate the IV
            val iv = c.iv
            val ct = c.doFinal(secret)
            val blob = ByteArray(iv.size + ct.size)
            System.arraycopy(iv, 0, blob, 0, iv.size)
            System.arraycopy(ct, 0, blob, iv.size, ct.size)
            prefs.edit().putString(peerId, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
        } catch (e: Exception) { /* keystore unavailable → skip; next connect re-enrolls */ }
    }

    /** Forget the secret for [peerId] (e.g. user un-pairs the Mac) → next connect re-enrolls. */
    @Synchronized fun remove(peerId: String) {
        if (peerId.isEmpty()) return
        try { prefs.edit().remove(peerId).apply() } catch (e: Exception) { /* best-effort */ }
    }

    /** The set of enrolled Mac peerIds (the prefs keys) — for the "已配对设备" UI list. Defensive copy. */
    @Synchronized fun peers(): Set<String> =
        try { HashSet(prefs.all.keys) } catch (e: Exception) { emptySet() }

    private companion object {
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
