package com.superconnect.receiver

import android.util.Base64
import com.superconnect.protocol.AuthCrypto
import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import com.superconnect.protocol.FrameFlags
import org.json.JSONArray
import org.json.JSONObject

/**
 * Receiver session — SERVER side of the hello/hello_ack handshake + SC-AUTH-v1 wireless trust
 * (proto/AUTH-SPEC.md §2/§3). The Mac (TCP CLIENT) dials in and sends `hello`; we reply `hello_ack`.
 * Wired/loopback stays byte-compatible (exempt). Wireless peers MUST prove possession of the shared
 * per-pair secret via an HMAC challenge-response before we claim the single-active slot / start video
 * (slot/onAuthenticated moves to AFTER `auth` verifies — stronger anti-DoS). Mirrors the Mac client in
 * SuperconnectCore/Session.swift and the HarmonyOS receiver. Crypto/secret-store are decoupled leaves
 * (AuthCrypto / SecretStore via the gate); FrameCodec is CONTROL-channel JSON only and untouched.
 */
class Session(
    private val transport: TcpServerTransport,
    private val caps: ReceiverCaps,
    private val deviceName: String,
    private val peerId: String,
    private val log: (String) -> Unit = {},
) {
    var onVideo: ((payload: ByteArray, isKeyframe: Boolean) -> Unit)? = null
    var onVideoConfig: ((width: Int, height: Int, codec: String, hdr: String) -> Unit)? = null
    var onStatus: ((String) -> Unit)? = null
    /** SC-AUTH-v1 pre-auth input gate toggle: TRUE on claimSlot() (post-auth / wired-exempt), FALSE on
     *  resetAuth() (per-connection reset). MainActivity wires this to InputSender.authorized. */
    var onAuthorized: ((Boolean) -> Unit)? = null

    /** SC-AUTH-v1 trust gate (null ⇒ no gate ⇒ wired-only behaviour, ack immediately — used by tests).
     *  ASYNC: given the Mac's (peerId, deviceName, isLocalhost, ownerId) it resolves a [TrustDecision]:
     *  Exempt (loopback) → ack WITHOUT a nonce + claim now (wired byte-compatible); Steady(secret) →
     *  challenge with a nonce; Enroll(secret, tabletEphPriv, macEphPub) → user approved, mint+pair;
     *  Reject → refuse. Non-blocking so the read loop keeps freeing the slot on a client disconnect.
     *  The minted secret in Enroll has ALREADY been persisted (keyed by macPeerId) by the gate. */
    var trustGate: ((peerId: String, deviceName: String, isLocalhost: Boolean, ownerId: Int,
                     macEphPub: ByteArray?, onResult: (TrustDecision) -> Unit) -> Unit)? = null

    /** The gate's verdict for an incoming `hello` (mirror of the Mac client's hello_ack branch logic). */
    sealed class TrustDecision {
        /** Loopback / wired: pairing-exempt. Ack WITHOUT a nonce and claim the slot now (unchanged wired path). */
        object Exempt : TrustDecision()
        /** A secret already exists for this Mac → challenge it (steady state). */
        data class Steady(val secret: ByteArray) : TrustDecision()
        /** Unknown Mac, user tapped 允许 → tablet minted [secret] (already persisted) + an ephemeral keypair
         *  ([tabletEphPriv] scalar 32B, [tabletEphPub] x9.63 65B); send `pair_secret` sealed under
         *  ECDH(tabletEphPriv, macEphPub) and advertise [tabletEphPub] in hello_ack so the Mac learns the same secret. */
        data class Enroll(val secret: ByteArray, val tabletEphPriv: ByteArray, val tabletEphPub: ByteArray) : TrustDecision()
        /** Refuse (denied / timeout / no UI / anonymous / un-upgraded Mac). */
        object Reject : TrustDecision()
    }

    // ── per-connection auth state (reset each hello; one client at a time via single-active transport) ──
    private var pendingSecret: ByteArray? = null      // the per-pair secret in play (steady or freshly enrolled)
    private var pendingNonce: ByteArray? = null       // OUR fresh 32B challenge to the Mac (contextMac uses it)
    private var pendingMacPeerId: String = ""         // the Mac's peerId from `hello`
    private var slotClaimed = false                   // onStatus("投屏中") fired? (moves to AFTER `auth` verifies)

    fun attach() {
        transport.onClientChange = { connected ->
            if (!connected) resetAuth()
            onStatus?.invoke(if (connected) "已连接 · 握手中…" else "等待 Mac 连接…")
        }
        transport.onFrame = { channel, flags, payload -> route(channel, flags, payload) }
    }

    private fun resetAuth() {
        pendingSecret = null; pendingNonce = null; pendingMacPeerId = ""; slotClaimed = false
        onAuthorized?.invoke(false)   // pre-auth input gate: revoke input on every per-connection reset
    }

    private fun route(channel: Int, flags: Int, payload: ByteArray) {
        when (channel) {
            Channel.CONTROL.value -> handleControl(payload)
            Channel.VIDEO.value -> { if (slotClaimed) onVideo?.invoke(payload, (flags and FrameFlags.KEYFRAME) != 0) }   // pre-auth gate
            else -> {}   // INPUT/AUDIO/STATS not received by a receiver
        }
    }

    private fun handleControl(payload: ByteArray) {
        val msg = try { JSONObject(String(payload, Charsets.UTF_8)) } catch (e: Exception) { log("bad control json: $e"); return }
        when (msg.optString("type")) {
            "hello" -> onHello(msg)
            "auth" -> onAuth(msg)
            "video_config" -> { if (slotClaimed) onVideoConfig?.invoke(   // pre-auth gate: ignore until authorized
                msg.optInt("width"), msg.optInt("height"),
                msg.optString("codec", "h264"), msg.optString("hdr", "off")) }
            "ping" -> sendControl(JSONObject().put("type", "pong").put("seq", msg.optInt("seq")))
            else -> {}
        }
    }

    /** SC-AUTH-v1 server step 1 (mirror of Mac Session.sendHello → tablet decision). Decide via the gate
     *  whether this client is exempt (wired), already paired (challenge), needs enrollment (prompt), or
     *  must be refused. The slot is NOT claimed here for wireless — only after `auth` verifies. */
    private fun onHello(msg: JSONObject) {
        resetAuth()
        val gate = trustGate
        // No gate ⇒ tests / pure-wired bring-up ⇒ ack immediately (byte-compatible, no nonce). Mirrors the
        // old behaviour exactly when wireless trust isn't wired in.
        if (gate == null) { log("received hello → sending hello_ack (no gate)"); sendHelloAck(); claimSlot(); return }

        // Fail closed if the Mac is un-upgraded (no authVersion) UNLESS it's loopback (the gate exempts
        // loopback regardless). We can't tell loopback from JSON, so let the gate decide exempt first; for a
        // non-loopback peer that omitted authVersion, refuse with auth_required (never peerId fallback).
        val authVersion = if (msg.has("authVersion")) msg.optInt("authVersion") else null
        // FAIL CLOSED BEFORE MINT: a NON-loopback peer that omitted authVersion can't satisfy a challenge.
        // Refuse here, BEFORE the gate runs, so WirelessService never mints+persists a phantom secret for an
        // un-upgraded Mac (mirrors the Mac, which decides purely from hello content). Loopback stays exempt.
        if (authVersion == null && !transport.clientIsLocalhost) { refuse("auth_required"); return }
        val macPeerId = msg.optString("peerId")
        val macName = msg.optString("deviceName", "Mac")
        val macEphPub = (msg.optString("ephPub").takeIf { it.isNotEmpty() })
            ?.let { try { Base64.decode(it, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { null } }
        pendingMacPeerId = macPeerId

        gate(macPeerId, macName, transport.clientIsLocalhost, transport.clientOwnerId, macEphPub) { decision ->
            when (decision) {
                is TrustDecision.Exempt -> {
                    // Wired/loopback: reply hello_ack WITHOUT a nonce (and no needsPairing) and claim NOW —
                    // byte-for-byte the old wired path. The Mac sees no nonce ⇒ connects without auth.
                    log("auth-exempt (wired/loopback) → hello_ack (no nonce) + claim slot")
                    sendHelloAck()
                    claimSlot()
                }
                is TrustDecision.Steady -> {
                    // Un-upgraded wireless Mac can't satisfy a challenge → fail closed (never peerId trust).
                    if (authVersion == null) { refuse("auth_required"); return@gate }
                    pendingSecret = decision.secret
                    val nonce = AuthCrypto.randomBytes(32)
                    pendingNonce = nonce
                    log("steady → hello_ack with nonce (awaiting auth)")
                    sendHelloAck(nonce = nonce, needsPairing = false)   // slot NOT claimed yet
                }
                is TrustDecision.Enroll -> {
                    if (authVersion == null) { refuse("auth_required"); return@gate }
                    val ephPub = macEphPub
                    if (ephPub == null) { refuse("auth_required"); return@gate }   // can't enroll without the Mac's ephPub
                    pendingSecret = decision.secret
                    val nonce = AuthCrypto.randomBytes(32)
                    pendingNonce = nonce
                    val pair = try {
                        // Seal the minted secret to the Mac under ECDH(ourScalar, macEphPub): the Mac derives the
                        // same key from (its scalar, our pub) and opens it. Slot NOT claimed until `auth` verifies.
                        val salt = AuthCrypto.randomBytes(16)
                        val aeadNonce = AuthCrypto.randomBytes(12)
                        val key = AuthCrypto.deriveEcdhKey(decision.tabletEphPriv, ephPub, salt)
                        val enc = AuthCrypto.seal(decision.secret, key, aeadNonce, AuthCrypto.PAIR_INFO)
                        Triple(b64(enc), b64(salt), b64(aeadNonce))
                    } catch (e: Exception) {
                        log("enroll seal failed: $e"); refuse("auth_failed"); return@gate
                    }
                    log("enroll (user 允许) → hello_ack(needsPairing) + pair_secret (awaiting auth)")
                    sendHelloAck(nonce = nonce, needsPairing = true, ephPub = decision.tabletEphPub)
                    val (enc, salt, aeadNonce) = pair
                    sendControl(JSONObject()
                        .put("type", "pair_secret")
                        .put("encSecret", enc).put("salt", salt).put("aeadNonce", aeadNonce))
                }
                is TrustDecision.Reject -> refuse("pairing_rejected")
            }
        }
    }

    /** SC-AUTH-v1 server step 3: verify the Mac's `auth` proof; on success reply auth_ack + CLAIM SLOT. */
    private fun onAuth(msg: JSONObject) {
        if (slotClaimed) { log("duplicate auth (slot already claimed) → ignore"); return }
        val secret = pendingSecret
        val nonce = pendingNonce
        if (secret == null || nonce == null) { refuse("auth_failed"); return }
        val proof = (msg.optString("proof").takeIf { it.isNotEmpty() })
            ?.let { try { Base64.decode(it, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { null } }
        val macNonce = (msg.optString("macNonce").takeIf { it.isNotEmpty() })
            ?.let { try { Base64.decode(it, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { null } }
        if (proof == null || macNonce == null) { refuse("auth_failed"); return }

        // contextMac uses the MAC's peerId FIRST then the tablet, with the nonce WE sent.
        val nonceB64 = b64(nonce)
        val ctx = AuthCrypto.contextMac(macPeerId = pendingMacPeerId, tabletPeerId = peerId, nonceB64 = nonceB64)
        if (!AuthCrypto.verify(proof, secret, ctx)) {
            log("auth FAILED (proof mismatch) → error, claim nothing")
            refuse("auth_failed")
            return
        }
        // OK → prove WE hold the secret too: HMAC over contextPad (tablet-first, the Mac's macNonce).
        val macNonceB64 = b64(macNonce)
        val padCtx = AuthCrypto.contextPad(macPeerId = pendingMacPeerId, tabletPeerId = peerId, macNonceB64 = macNonceB64)
        val ackProof = AuthCrypto.hmac(secret, padCtx)
        sendControl(JSONObject().put("type", "auth_ack").put("proof", b64(ackProof)))
        log("auth ok → auth_ack + claim slot")
        claimSlot()
    }

    /** Single-active slot / "投屏中" — fires onAuthenticated. For wireless this is now AFTER `auth` verifies. */
    private fun claimSlot() {
        if (slotClaimed) return
        slotClaimed = true
        onAuthorized?.invoke(true)   // pre-auth input gate: authorize input only after auth (wired-exempt claims too)
        onStatus?.invoke("已连接 · 投屏中")
    }

    private fun refuse(reason: String) {
        log("refuse: $reason")
        sendControl(JSONObject().put("type", "error").put("reason", reason).put("message", reason))
    }

    private fun sendHelloAck(nonce: ByteArray? = null, needsPairing: Boolean = false, ephPub: ByteArray? = null) {
        val c = JSONObject()
            .put("codecs", JSONArray(caps.codecs))
            .put("pen", caps.pen)
            .put("screenWidth", caps.screenWidth)
            .put("screenHeight", caps.screenHeight)
            .put("scale", caps.scale.toDouble())
            .put("refreshRate", caps.refreshRate.toDouble())
        val ack = JSONObject()
            .put("type", "hello_ack")
            .put("role", "pad")
            .put("protocolVersion", 2)
            .put("peerId", peerId)
            .put("platform", "android")
            .put("deviceName", deviceName)
            .put("supportedRoles", JSONArray(listOf("receiver")))
            .put("acceptedRole", "receiver")
            .put("caps", c)
        // SC-AUTH-v1: a nonce ⇒ the Mac must prove the secret before we connect. Omitted ⇒ wired-exempt.
        if (nonce != null) {
            ack.put("authVersion", 1)
            ack.put("nonce", b64(nonce))
            ack.put("needsPairing", needsPairing)
            if (ephPub != null) ack.put("ephPub", b64(ephPub))
        }
        sendControl(ack)
    }

    private fun sendControl(obj: JSONObject) {
        transport.send(FrameCodec.encode(Channel.CONTROL, 0, obj.toString().toByteArray(Charsets.UTF_8)))
    }

    private fun b64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)
}
