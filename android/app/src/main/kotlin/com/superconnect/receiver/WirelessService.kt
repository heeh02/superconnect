package com.superconnect.receiver

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.CountDownLatch
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

    /** Set by the UI: show the 允许/拒绝 prompt for an unknown LAN Mac; the user's tap calls `resolve`. */
    var onPairingRequest: ((peerId: String, deviceName: String, resolve: (Boolean) -> Unit) -> Unit)? = null

    fun enabled(): Boolean = prefs.getBoolean(KEY_ENABLED, true)   // default ON: wireless is the point of the receiver
    fun setEnabled(on: Boolean) { prefs.edit().putBoolean(KEY_ENABLED, on).apply() }

    /** '0.0.0.0' (LAN; also serves the wired adb-forwarded loopback client) when on, else loopback only. */
    fun bindAddress(): String = if (enabled()) "0.0.0.0" else "127.0.0.1"

    /** The device's private IPv4 (Wi-Fi), dotted, for the manual-connect hint; "" if none (not on Wi-Fi). */
    fun wifiIpv4(): String {
        try {
            for (intf in NetworkInterface.getNetworkInterfaces()) {
                if (!intf.isUp || intf.isLoopback || intf.isVirtual) continue
                for (addr in intf.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        val ip = addr.hostAddress ?: continue
                        if (ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("172.")) return ip
                    }
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

    /**
     * TOFU gate, called on the transport's read thread during the `hello` handshake. Loopback (wired)
     * → always allow. LAN + already trusted → allow. LAN + unknown → prompt the user and BLOCK this
     * single-client thread until they decide (allow → persist + true; deny / 60s timeout → false).
     * Mirrors the HarmonyOS pairing gate (no gate / loopback ⇒ wired behaviour is byte-unchanged).
     */
    fun allowClient(peerId: String, deviceName: String, isLocalhost: Boolean): Boolean {
        if (isLocalhost) return true
        if (pairing.isTrusted(peerId)) return true
        val cb = onPairingRequest ?: return false   // no UI wired up ⇒ refuse LAN (fail safe)
        val latch = CountDownLatch(1)
        val allowed = java.util.concurrent.atomic.AtomicBoolean(false)
        cb(peerId, deviceName) { ok -> allowed.set(ok); latch.countDown() }
        val answered = try { latch.await(60, TimeUnit.SECONDS) } catch (e: InterruptedException) { false }
        if (answered && allowed.get()) { pairing.trust(peerId); return true }
        return false
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
        const val SERVICE_TYPE = "_superconnect._tcp"   // MUST match the Mac NWBrowser + HarmonyOS advertiser
    }
}
