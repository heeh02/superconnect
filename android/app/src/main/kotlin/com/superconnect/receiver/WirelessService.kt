package com.superconnect.receiver

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import com.superconnect.protocol.AuthCrypto
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Wireless (Wi-Fi LAN) support for the FOSS ViewOnly Android receiver.
 *
 * Owns: the wireless on/off preference; the concrete Wi-Fi address; the mDNS/NSD advertisement of
 * `_superconnect._tcp` so the Mac's
 * WirelessDiscovery (an NWBrowser for the SAME type that already finds HarmonyOS) auto-discovers this
 * device; the Wi-Fi IPv4 for the manual-connect hint; and the SC-AUTH-v1 trust gate (delegates to
 * SecretStore + an on-screen 允许/拒绝 prompt). Every route, including loopback/forwarded sockets,
 * proves the shared per-pair secret before the slot is claimed.
 *
 * Deliberately uses only STANDARD Android APIs (NsdManager / ConnectivityManager) so it works across
 * brands; brand-specific quirks (background limits, vendor NSD oddities) are a later adaptation layer.
 * The service type + hello_ack caps must match HarmonyOS so the same Mac discovers both.
 */
class WirelessService(
    private val context: Context,
    private val log: (String) -> Unit = {},
) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    /** SC-AUTH-v1: trust is now possession of a per-pair SECRET (HMAC-proven on every connect), not a
     *  bare peerId allow-list. The old PairingStore (spoofable peerId set) is retired — a matching peerId
     *  (or a BLE discovery token) NO LONGER auto-trusts; the Mac must prove the secret. */
    private val secrets = SecretStore(app)
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var regListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Set by the UI: show the 允许/拒绝 prompt for an unknown LAN Mac. `promptId` binds the dialog to
     *  THIS prompt — the user's tap must echo it via [respondPairing] so a stale tap (its prompt already
     *  timed out / was cancelled) can't settle a prompt that replaced it (anti-hijack, mirrors HarmonyOS). */
    var onPairingRequest: ((peerId: String, deviceName: String, promptId: Int) -> Unit)? = null
    /** Set by the UI: dismiss the live pairing dialog (fired on tap / timeout / owner-disconnect / teardown). */
    var onPairingDismiss: (() -> Unit)? = null
    var onEnabledChanged: ((Boolean) -> Unit)? = null
    var onWifiAddressChanged: ((String) -> Unit)? = null

    @Volatile private var currentWifiAddress: String = ""
    @Volatile private var currentWifiNetwork: Network? = null
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val changedNetwork = currentWifiNetwork != network
            currentWifiNetwork = network
            updateWifiAddress(network, force = changedNetwork)
        }
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            if (currentWifiNetwork == network) updateWifiAddress(linkProperties, force = false)
        }
        override fun onLost(network: Network) {
            val wasCurrent = currentWifiNetwork == network
            if (wasCurrent) {
                currentWifiNetwork = null
                publishWifiAddress("", force = true)
            }
        }
    }

    init {
        try {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            connectivity.registerNetworkCallback(request, networkCallback)
            refreshWifiAddress()
        } catch (error: Exception) {
            log("Wi-Fi network callback err $error")
        }
    }

    // FOSS Preview defaults ON so a 卓易通 container can be reached over the tablet's Wi-Fi
    // interface when its HDC loopback is isolated. The Mac still must complete SC-AUTH-v1 and
    // SC-RECORD-v1; no unauthenticated media path is opened.
    fun enabled(): Boolean = prefs.getBoolean(KEY_ENABLED, true)
    /** Persist and live-apply the LAN choice. MainActivity restarts only the listener binding. */
    fun setEnabled(on: Boolean) {
        if (on == enabled()) return
        prefs.edit().putBoolean(KEY_ENABLED, on).apply()
        if (on) synchronized(lock) { sessionDenied.clear() }   // re-enabling → fresh prompt for denied peers
        if (!on) stopAdvertise()
        onEnabledChanged?.invoke(on)
    }

    /** The device's private IPv4 (Wi-Fi), dotted, for the manual-connect hint; "" if none (not on Wi-Fi). */
    fun wifiIpv4(): String {
        if (currentWifiAddress.isNotEmpty()) return currentWifiAddress
        try {
            return wifiIpv4FromNetwork(currentWifiNetwork ?: connectivity.activeNetwork)
        } catch (e: Exception) { log("wifiIp err $e") }
        return ""
    }

    private fun updateWifiAddress(network: Network, force: Boolean) {
        updateWifiAddress(connectivity.getLinkProperties(network), force)
    }

    private fun updateWifiAddress(properties: LinkProperties?, force: Boolean) {
        val address = addressFrom(properties)
        // Empty is a real fact: DHCP/roam may temporarily remove IPv4. Keeping the old value makes
        // the receiver advertise and bind an address that no longer belongs to this device.
        publishWifiAddress(address, force)
    }

    private fun refreshWifiAddress(force: Boolean = false) {
        val address = try { wifiIpv4FromNetwork(currentWifiNetwork ?: connectivity.activeNetwork) }
        catch (_: Exception) { "" }
        publishWifiAddress(address, force)
    }

    private fun wifiIpv4FromNetwork(network: Network?): String {
        if (network == null) return ""
        val caps = connectivity.getNetworkCapabilities(network) ?: return ""
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return ""
        return addressFrom(connectivity.getLinkProperties(network))
    }

    private fun addressFrom(properties: LinkProperties?): String {
        for (linkAddress in properties?.linkAddresses.orEmpty()) {
            val address = linkAddress.address
            if (address is Inet4Address && address.isSiteLocalAddress) return address.hostAddress ?: ""
        }
        return ""
    }

    private fun publishWifiAddress(address: String, force: Boolean = false) {
        if (!force && address == currentWifiAddress) return
        currentWifiAddress = address
        onWifiAddressChanged?.invoke(address)
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

    // ── SC-AUTH-v1 trust gate (async; mirrors HarmonyOS evaluatePairing / respondPairing / cancelPairing) ──
    private val lock = Any()
    private val sessionDenied = HashSet<String>()             // peers refused THIS run (no re-prompt until restart)
    private var pendingResolve: ((Session.TrustDecision) -> Unit)? = null   // resolver of the one in-flight prompt
    private var pendingPeerId: String = ""
    private var pendingHasMacEphPub: Boolean = false          // presence only; Session owns the actual key bytes
    private var pendingOwnerId: Int = 0                       // transport clientId — only it may cancel its prompt
    private var pendingPromptId: Int = 0                      // monotonic — the user's tap must echo it
    private var promptSeq: Int = 0
    private var pendingTimeout: ScheduledFuture<*>? = null
    private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "sc-pairing-timeout").apply { isDaemon = true }
    }

    /**
     * ASYNC SC-AUTH-v1 gate, called on the transport read thread during `hello`. It DOES NOT block the read
     * loop — so a client disconnect is noticed immediately and the single-active slot frees at once. Resolves
     * a [Session.TrustDecision]:
     *  - a SECRET already stored for this Mac → Steady(secret) (challenge it — no prompt);
     *  - unknown Mac → raise the 允许/拒绝 prompt; on 允许 MINT a candidate and resolve Enroll. The
     *    reducer requests persistence only after proof + admission; on 拒绝/timeout/disconnect → Reject.
     *  - anonymous peer / no UI wired up → Reject (fail safe).
     * A matching peerId NO LONGER auto-trusts (the old isTrusted allow-list is gone); only possession of the
     * secret (proven by the Mac's later `auth`) authenticates. Mirrors HarmonyOS evaluatePairing.
     */
    fun evaluate(peerId: String, deviceName: String, ownerId: Int,
                 hasMacEphPub: Boolean, onPromptStarted: () -> Unit,
                 onResult: (Session.TrustDecision) -> Unit) {
        if (!AuthCrypto.isValidPeerId(peerId)) { onResult(Session.TrustDecision.Reject); return }
        val existing = secrets.secret(peerId)
        if (existing != null) {
            deliverTrustDecision(Session.TrustDecision.Steady(existing), null, onResult, log)
            return
        } // steady state — challenge
        // Enrollment requires the Mac's ephemeral pub (to seal the secret). Without it, refuse.
        if (!hasMacEphPub) { onResult(Session.TrustDecision.Reject); return }
        val cb = onPairingRequest
        if (cb == null) { onResult(Session.TrustDecision.Reject); return }    // no UI wired up ⇒ refuse LAN (fail safe)
        var promptId = -1   // stays -1 ⇒ refused under the lock (denied this run, or a prompt already in flight)
        synchronized(lock) {
            if (!sessionDenied.contains(peerId) && pendingResolve == null) {   // else: one prompt at a time (anti-hijack)
                pendingResolve = onResult
                pendingPeerId = peerId
                pendingHasMacEphPub = true
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
        if (promptId < 0) { onResult(Session.TrustDecision.Reject); return }  // refuse OUTSIDE the lock (no send under lock)
        onPromptStarted()
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
        try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
        scheduler.shutdownNow()
    }

    /** Resolve the in-flight prompt iff [matches]. Single source of truth: cancels the timeout and clears
     *  pending state under [lock], then (on 允许) MINTS a per-pair secret and resolves Enroll,
     *  else resolves Reject — dialog dismiss + resolve happen OUTSIDE the lock (the resolver re-enters
     *  Session→peer send, never back into WirelessService). No-op if nothing is pending or [matches]
     *  is false (e.g. a stale tap, or a cancel for a different owner). */
    private fun settleIf(matches: () -> Boolean, allow: Boolean, deny: Boolean) {
        var resolve: ((Session.TrustDecision) -> Unit)? = null
        var peerId = ""
        var hasMacEphPub = false
        synchronized(lock) {
            if (pendingResolve == null || !matches()) return
            resolve = pendingResolve
            peerId = pendingPeerId
            hasMacEphPub = pendingHasMacEphPub
            pendingTimeout?.cancel(false); pendingTimeout = null
            pendingResolve = null; pendingPeerId = ""; pendingHasMacEphPub = false
            pendingOwnerId = 0; pendingPromptId = 0
            if (deny && peerId.isNotEmpty()) sessionDenied.add(peerId)
        }
        val decision: Session.TrustDecision = if (allow && peerId.isNotEmpty() && hasMacEphPub) {
            try {
                // Persistence remains a typed Session effect; mint/key creation is one ownership transfer.
                mintEnrollmentDecision(peerId, AuthCrypto::newSecret,
                    AuthCrypto::newEphemeralKeyPair) { secret, identity ->
                    secrets.store(secret, identity)
                }
            } catch (error: Throwable) {
                log("pairing enrollment mint failed: $error")
                Session.TrustDecision.Reject
            }
        } else {
            Session.TrustDecision.Reject
        }
        val resolver = resolve ?: run {
            decision.zeroizeSensitive()
            return
        }
        deliverTrustDecision(decision, onPairingDismiss, resolver, log)
    }

    /** Enrolled Macs (those with a stored secret) — drives the control panel's "已配对设备" list. */
    fun trustedPeers(): Set<String> = secrets.peers()
    /** User un-pairs a Mac → drop its secret; the next connect re-enrolls (one 允许 tap). */
    fun forgetPeer(peerId: String) = secrets.remove(peerId)

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
        const val PAIR_TIMEOUT_SEC = 75L                 // matches SessionAdmission's first-enrollment deadline
        const val SERVICE_TYPE = "_superconnect._tcp"   // MUST match the Mac NWBrowser + HarmonyOS advertiser
    }
}
