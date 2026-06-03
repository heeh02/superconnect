package com.superconnect.receiver

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Wireless (Wi-Fi LAN) support for the FREE Android receiver — mirrors HarmonyOS WirelessService.
 *
 * Owns: the wireless on/off preference; the socket bind address (0.0.0.0 = LAN when on, 127.0.0.1 =
 * wired/adb only when off); the mDNS/NSD advertisement of `_superconnect._tcp` so the Mac's
 * WirelessDiscovery (an NWBrowser for the SAME type that already finds HarmonyOS) auto-discovers this
 * device; the Wi-Fi IPv4 for the manual-connect hint; and the TOFU pairing gate (delegates to
 * PairingStore + an on-screen prompt). Binding 0.0.0.0 serves BOTH the wired adb-forwarded loopback
 * client AND LAN clients; loopback clients are pairing-exempt, LAN clients need approval.
 *
 * Deliberately uses only STANDARD Android APIs (NsdManager / NetworkInterface) so it works across
 * brands; brand-specific quirks (background limits, vendor NSD oddities) are a later adaptation layer.
 * Free/core → dev. The service type + hello_ack caps must match HarmonyOS so the same Mac discovers both.
 */
class WirelessService(
    private val context: Context,
    private val log: (String) -> Unit = {},
) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val pairing = PairingStore(app)
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var regListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Set by the UI: show the 允许/拒绝 prompt for an unknown LAN Mac. `promptId` binds the dialog to
     *  THIS prompt — the user's tap must echo it via [respondPairing] so a stale tap (its prompt already
     *  timed out / was cancelled) can't settle a prompt that replaced it (anti-hijack, mirrors HarmonyOS). */
    var onPairingRequest: ((peerId: String, deviceName: String, promptId: Int) -> Unit)? = null
    /** Set by the UI: dismiss the live pairing dialog (fired on tap / timeout / owner-disconnect / teardown). */
    var onPairingDismiss: (() -> Unit)? = null

    fun enabled(): Boolean = prefs.getBoolean(KEY_ENABLED, true)   // default ON: wireless is the point of the receiver
    /** Persist the on/off choice (+ reset this-run denials). NOT yet live-applied: no settings toggle calls
     *  this today, and MainActivity reads [bindAddress] once at onCreate — a change takes effect on next
     *  launch. When a toggle UI lands, add a restart hook (stop+rebind transport, re-fire onListening) like
     *  HarmonyOS setRestart/restartFn so 127.0.0.1↔0.0.0.0 + mDNS flip live. */
    fun setEnabled(on: Boolean) {
        prefs.edit().putBoolean(KEY_ENABLED, on).apply()
        if (on) synchronized(lock) { sessionDenied.clear() }   // re-enabling → fresh prompt for denied peers
    }

    /** '0.0.0.0' (LAN; also serves the wired adb-forwarded loopback client) when on, else loopback only. */
    fun bindAddress(): String = if (enabled()) "0.0.0.0" else "127.0.0.1"

    /** The device's private IPv4 (Wi-Fi), dotted, for the manual-connect hint; "" if none (not on Wi-Fi). */
    fun wifiIpv4(): String {
        try {
            for (intf in NetworkInterface.getNetworkInterfaces()) {
                if (!intf.isUp || intf.isLoopback || intf.isVirtual) continue
                for (addr in intf.inetAddresses) {
                    // isSiteLocalAddress = exactly the RFC1918 private blocks (10/8, 172.16/12, 192.168/16)
                    // — avoids the old startsWith("172.") over-match (172.0–15 / 172.32–255 are PUBLIC), which
                    // could surface an undialable public 172.x as the manual-connect hint.
                    if (addr is Inet4Address && addr.isSiteLocalAddress) return addr.hostAddress ?: continue
                }
            }
        } catch (e: Exception) { log("wifiIp err $e") }
        return ""
    }

    /** Advertise `_superconnect._tcp` on the LAN. Call AFTER the socket is listening; only when enabled. */
    fun startAdvertise(serviceName: String, port: Int) {
        if (!enabled() || regListener != null) return
        acquireMulticast()
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName
            serviceType = SERVICE_TYPE
            this.port = port
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: NsdServiceInfo) { log("mDNS registered ${s.serviceName} $SERVICE_TYPE:$port") }
            override fun onRegistrationFailed(s: NsdServiceInfo, err: Int) { log("mDNS register failed $err") }
            override fun onServiceUnregistered(s: NsdServiceInfo) { log("mDNS unregistered") }
            override fun onUnregistrationFailed(s: NsdServiceInfo, err: Int) { log("mDNS unregister failed $err") }
        }
        try { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l); regListener = l }
        catch (e: Exception) { log("mDNS register err $e"); releaseMulticast() }
    }

    fun stopAdvertise() {
        regListener?.let { try { nsd.unregisterService(it) } catch (e: Exception) { log("mDNS stop err $e") } }
        regListener = null
        releaseMulticast()
    }

    // ── TOFU pairing gate (async; mirrors HarmonyOS evaluatePairing / respondPairing / cancelPairing) ──
    private val lock = Any()
    private val sessionDenied = HashSet<String>()             // peers refused THIS run (no re-prompt until restart)
    private var pendingResolve: ((Boolean) -> Unit)? = null   // resolver of the one in-flight prompt
    private var pendingPeerId: String = ""
    private var pendingOwnerId: Int = 0                       // transport clientId — only it may cancel its prompt
    private var pendingPromptId: Int = 0                      // monotonic — the user's tap must echo it
    private var promptSeq: Int = 0
    private var pendingTimeout: ScheduledFuture<*>? = null
    private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "sc-pairing-timeout").apply { isDaemon = true }
    }

    /**
     * ASYNC TOFU gate, called on the transport read thread during `hello`. It DOES NOT block the read
     * loop — so a client disconnect is noticed immediately and the single-active slot frees at once (the
     * old blocking design held it for up to 60s, starving even the wired adb client). Loopback (wired) and
     * trusted peers resolve true synchronously; an unknown LAN peer raises the 允许/拒绝 prompt and resolves
     * on the user's tap, or false on 60s timeout / owner-disconnect. Mirrors HarmonyOS evaluatePairing.
     */
    fun evaluate(peerId: String, deviceName: String, isLocalhost: Boolean, ownerId: Int, onResult: (Boolean) -> Unit) {
        if (isLocalhost) { onResult(true); return }            // wired/adb (loopback) → always trusted
        if (peerId.isEmpty()) { onResult(false); return }      // can't TOFU an anonymous peer
        if (pairing.isTrusted(peerId)) { onResult(true); return }
        val cb = onPairingRequest
        if (cb == null) { onResult(false); return }            // no UI wired up ⇒ refuse LAN (fail safe)
        var promptId = -1   // stays -1 ⇒ refused under the lock (denied this run, or a prompt already in flight)
        synchronized(lock) {
            if (!sessionDenied.contains(peerId) && pendingResolve == null) {   // else: one prompt at a time (anti-hijack)
                pendingResolve = onResult
                pendingPeerId = peerId
                pendingOwnerId = ownerId
                pendingPromptId = ++promptSeq
                promptId = pendingPromptId
                // Timeout matches on promptId so a late-firing timer can never settle a LATER prompt that
                // reused the slot (the timer is also cancelled on any tap/cancel). Wrap as Runnable to pick
                // the schedule(Runnable,…) overload (a Unit lambda is otherwise ambiguous vs Callable).
                pendingTimeout = scheduler.schedule(
                    Runnable { settleIf({ promptId == pendingPromptId }, allow = false, deny = false) },
                    PAIR_TIMEOUT_SEC, TimeUnit.SECONDS)
            }
        }
        if (promptId < 0) { onResult(false); return }          // refuse OUTSIDE the lock (no blocking send under lock)
        cb(peerId, deviceName, promptId)
    }

    /** User tapped 允许(true)/拒绝(false). `promptId` binds the answer to the shown dialog (a stale tap is ignored). */
    fun respondPairing(promptId: Int, allow: Boolean) = settleIf({ promptId == pendingPromptId }, allow, deny = !allow)

    /** Owning connection (by transport ownerId) closed/gave up → free the slot + dismiss the dialog (no late trust). */
    fun cancelPairing(ownerId: Int) = settleIf({ ownerId == pendingOwnerId }, allow = false, deny = false)

    /** App teardown: drop any in-flight prompt, stop advertising, release the timer thread. */
    fun dispose() {
        settleIf({ true }, allow = false, deny = false)
        stopAdvertise()
        scheduler.shutdownNow()
    }

    /** Resolve the in-flight prompt iff [matches]. Single source of truth: cancels the timeout and clears
     *  pending state under [lock], then trusts/denies + dismisses the dialog + resolves OUTSIDE the lock
     *  (the resolver re-enters Session→transport.send, never back into WirelessService). No-op if nothing
     *  is pending or [matches] is false (e.g. a stale tap, or a cancel for a different owner). */
    private fun settleIf(matches: () -> Boolean, allow: Boolean, deny: Boolean) {
        var resolve: ((Boolean) -> Unit)? = null
        var peerId = ""
        synchronized(lock) {
            if (pendingResolve == null || !matches()) return
            resolve = pendingResolve
            peerId = pendingPeerId
            pendingTimeout?.cancel(false); pendingTimeout = null
            pendingResolve = null; pendingPeerId = ""; pendingOwnerId = 0; pendingPromptId = 0
            if (deny && peerId.isNotEmpty()) sessionDenied.add(peerId)
        }
        if (allow && peerId.isNotEmpty()) pairing.trust(peerId)
        onPairingDismiss?.invoke()
        resolve?.invoke(allow)
    }

    fun trustedPeers(): Set<String> = pairing.list()
    fun forgetPeer(peerId: String) = pairing.forget(peerId)

    private fun acquireMulticast() {
        if (multicastLock != null) return
        try {
            val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("sc-nsd").apply { setReferenceCounted(false); acquire() }
        } catch (e: Exception) { log("multicast lock err $e") }
    }

    private fun releaseMulticast() {
        try { multicastLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        multicastLock = null
    }

    private companion object {
        const val PREFS = "sc_wireless"
        const val KEY_ENABLED = "enabled"
        const val PAIR_TIMEOUT_SEC = 60L                 // auto-reject an unanswered pairing prompt after 60s
        const val SERVICE_TYPE = "_superconnect._tcp"   // MUST match the Mac NWBrowser + HarmonyOS advertiser
    }
}
