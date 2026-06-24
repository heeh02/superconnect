package com.superconnect.receiver

import android.content.Context
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure persistence of the SC-AUTH-v1 per-pair `secret` (32 random bytes) keyed by the Mac's `peerId`.
 * Decoupled crypto leaf for the frozen contract (proto/AUTH-SPEC.md §1): the secret is the long-lived
 * credential proven via HMAC challenge-response on every connect, so it must NEVER sit in clear at rest.
 *
 * Backed by Jetpack Security [EncryptedSharedPreferences] — values are AES-256-GCM sealed under a master
 * key held in the AndroidKeyStore (hardware-backed where available), so the on-disk prefs file is opaque
 * even with root/adb. Mirrors HarmonyOS's `@ohos.security.asset` SecretStore and macOS Keychain. Stores
 * base64(secret) per peerId. No transport/session dependency (the handshake author wires this in later).
 */
class SecretStore(context: Context) {
    private val prefs by lazy {
        val app = context.applicationContext
        val masterKey = MasterKey.Builder(app)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            app,
            PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** The stored secret for [peerId], or null if this Mac isn't enrolled yet (caller must (re)pair). */
    @Synchronized fun secret(peerId: String): ByteArray? {
        if (peerId.isEmpty()) return null
        val b64 = prefs.getString(peerId, null) ?: return null
        return try { Base64.decode(b64, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { null }
    }

    /** Upsert the per-pair [secret] for [peerId] into the secure store. */
    @Synchronized fun store(secret: ByteArray, peerId: String) {
        if (peerId.isEmpty()) return
        prefs.edit().putString(peerId, Base64.encodeToString(secret, Base64.NO_WRAP)).apply()
    }

    /** Forget the secret for [peerId] (e.g. user un-pairs the Mac) → next connect re-enrolls. */
    @Synchronized fun remove(peerId: String) {
        if (peerId.isEmpty()) return
        prefs.edit().remove(peerId).apply()
    }

    /** The set of enrolled Mac peerIds (each maps to a stored secret) — for the "已配对设备" UI list. The
     *  prefs keys ARE the peerIds (values are the sealed secrets); EncryptedSharedPreferences decrypts keys
     *  transparently. Returns a defensive copy. */
    @Synchronized fun peers(): Set<String> = HashSet(prefs.all.keys)

    private companion object {
        const val PREFS = "sc_secrets"
    }
}
