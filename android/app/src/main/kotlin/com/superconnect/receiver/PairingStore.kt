package com.superconnect.receiver

import android.content.Context

/**
 * TOFU allow-list of trusted Mac peerIds for the WIRELESS (LAN) path. Mirrors HarmonyOS PairingStore.
 *
 * A LAN client whose `peerId` (stable per-install id from the Mac's `hello`) is here connects silently;
 * an unknown one must be approved once via the on-screen prompt, after which it's persisted here.
 * Loopback (wired / adb-forwarded) clients are EXEMPT and never consult this. Persisted in
 * SharedPreferences. Free/core, universal (no brand-specific APIs) → dev.
 */
class PairingStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized fun isTrusted(peerId: String): Boolean = peerId.isNotEmpty() && trusted().contains(peerId)

    @Synchronized fun trust(peerId: String) {
        if (peerId.isEmpty()) return
        val next = trusted().toMutableSet()
        if (next.add(peerId)) prefs.edit().putStringSet(KEY, next).apply()
    }

    @Synchronized fun forget(peerId: String) {
        val next = trusted().toMutableSet()
        if (next.remove(peerId)) prefs.edit().putStringSet(KEY, next).apply()
    }

    @Synchronized fun list(): Set<String> = trusted()

    // Copy out: SharedPreferences.getStringSet returns a set you must not mutate.
    private fun trusted(): Set<String> = HashSet(prefs.getStringSet(KEY, emptySet()) ?: emptySet())

    private companion object {
        const val PREFS = "sc_pairing"
        const val KEY = "trusted_peers"
    }
}
