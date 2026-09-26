package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Owns pending sessions, the one authenticated active peer, and authentication deadlines across
 * every listener. Decoder callbacks are routed only for the peer that atomically claimed the slot.
 */
class ReceiverSessionHost(
    private val caps: ReceiverCaps,
    private val deviceName: String,
    private val peerId: String,
    private val authorizedCapabilities: Long = CapabilityNegotiation.BASELINE_RECEIVER_CAPABILITIES,
    private val intentProductProfileV2: ProductCapabilityProfileV2 =
        ProductCapabilityProfileV2.baselineReceiver(),
    private val trustGate: ((peerId: String, deviceName: String, ownerId: Int,
                             hasMacEphPub: Boolean, onPromptStarted: () -> Unit,
                             onResult: (Session.TrustDecision) -> Unit) -> Unit)? = null,
    private val log: (String) -> Unit = {},
) {
    /** True means the UI/decoder accepted ownership of the exact payload array. */
    var onVideo: ((generation: Long, frame: ReceivedVideoAccessUnit) -> Boolean)? = null
    var onVideoConfig: ((generation: Long, width: Int, height: Int, codec: String,
                         hdr: String, lowLatency: Boolean) -> Unit)? = null
    var onAuthorized: ((authorized: Boolean, generation: Long) -> Unit)? = null
    var onPeerClosed: ((ownerId: Int) -> Unit)? = null

    private val lock = Any()
    private val admission = SessionAdmission()
    private val peers = mutableMapOf<Int, TcpPeer>()
    private val sessions = mutableMapOf<Int, Session>()
    private data class Deadline(val token: Long, val future: ScheduledFuture<*>)
    private val deadlines = mutableMapOf<Int, Deadline>()
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "sc-admission-deadline").apply { isDaemon = true }
    }
    @Volatile private var activePeer: TcpPeer? = null
    private val authorizationRouter = ActiveSessionAuthorizationRouter(
        activeOwnerId = { activePeer?.id ?: -1 },
        downstream = { authorized, generation -> onAuthorized?.invoke(authorized, generation) },
    )
    private var disposed = false

    fun accept(peer: TcpPeer) {
        val actions = synchronized(lock) {
            if (disposed) null else admission.apply(AdmissionEvent(AdmissionEventKind.Accepted, peer.id))
        }
        if (actions == null) { peer.close(); return }
        val timer = actions.firstOrNull { it.kind == AdmissionActionKind.StartAuthTimer }
        if (timer == null) {
            val capacity = actions.any { it.kind == AdmissionActionKind.RejectCapacity }
            val reason = if (capacity) {
                "session_capacity"
            } else {
                "session_busy"
            }
            log("reject peer=${peer.id} origin=${peer.origin} reason=$reason")
            peer.sendAndClose(errorFrame(if (capacity) ControlEnvelopeErrorReason.SessionCapacity
                else ControlEnvelopeErrorReason.SessionBusy))
            return
        }

        val session = Session(
            frameWriter = peer,
            ownerId = peer.id,
            caps = caps,
            deviceName = deviceName,
            peerId = peerId,
            authorizedCapabilities = authorizedCapabilities,
            productProfileV2 = intentProductProfileV2,
            log = log,
        )
        session.trustGate = trustGate
        session.onAuthenticationReady = { claim(peer) }
        session.onPairingPromptStarted = {
            extendPairingDeadline(peer.id)
        }
        session.onAdmissionRejected = { peer.closeAfterWrites() }
        session.onVideo = { frame ->
            if (activePeer?.id != peer.id) false else onVideo?.invoke(session.generation, frame) == true
        }
        session.onVideoConfig = { width, height, codec, hdr, lowLatency ->
            if (activePeer?.id == peer.id) {
                onVideoConfig?.invoke(session.generation, width, height, codec, hdr, lowLatency)
            }
        }
        session.onAuthorized = { authorized, generation ->
            authorizationRouter.route(peer.id, authorized, generation)
        }
        session.onFatal = { log("session fatal owner=${peer.id}") }
        session.onReady = { log("session ready owner=${peer.id}") }

        val installed = synchronized(lock) {
            if (disposed) {
                false
            } else {
                peers[peer.id] = peer
                sessions[peer.id] = session
                replaceDeadlineLocked(peer.id, timer.token, timer.timeoutMs)
                true
            }
        }
        if (!installed) { session.dispose(); peer.close(); return }
        peer.onBytes = session::onBytes
        peer.onClosed = { peerClosed(peer.id) }
    }

    fun requestKeyframeFromActive() {
        val session = synchronized(lock) {
            activePeer?.id?.let { sessions[it] }
        }
        session?.requestKeyframe()
    }

    fun sendPointer(payload: ByteArray) {
        try {
            val session = synchronized(lock) { activePeer?.id?.let { sessions[it] } }
            session?.sendPointer(payload)
        } finally { payload.fill(0) }
    }

    fun sendText(text: String) {
        val session = synchronized(lock) { activePeer?.id?.let { sessions[it] } }
        session?.sendText(text)
    }

    /** IDs are derived from platform-owned timer resources; capacity/state remain Rust-authoritative. */
    internal fun pendingIds(): List<Int> = synchronized(lock) {
        if (disposed) emptyList() else deadlines.keys.sorted()
    }

    internal fun activePeerId(): Int = activePeer?.id ?: -1

    private fun claim(peer: TcpPeer): Boolean = synchronized(lock) {
        if (disposed) return@synchronized false
        val actions = admission.apply(AdmissionEvent(AdmissionEventKind.Authenticated, peer.id))
        cancelDeadlinesLocked(actions)
        if (actions.any { it.kind == AdmissionActionKind.Claim }) {
            activePeer = peer
            true
        } else {
            false
        }
    }

    private fun extendPairingDeadline(ownerId: Int) {
        synchronized(lock) {
            if (disposed) return
            val actions = admission.apply(AdmissionEvent(AdmissionEventKind.PairingPrompt, ownerId))
            cancelDeadlinesLocked(actions)
            val timer = actions.firstOrNull { it.kind == AdmissionActionKind.StartPairingTimer } ?: return
            replaceDeadlineLocked(ownerId, timer.token, timer.timeoutMs)
        }
    }

    private fun replaceDeadlineLocked(ownerId: Int, token: Long, timeoutMs: Long) {
        check(token > 0)
        deadlines.remove(ownerId)?.future?.cancel(false)
        val future = scheduler.schedule(
            { admissionTimedOut(ownerId, token) },
            timeoutMs,
            TimeUnit.MILLISECONDS,
        )
        deadlines[ownerId] = Deadline(token, future)
    }

    private fun cancelDeadlinesLocked(actions: List<AdmissionAction>) {
        actions.filter { it.kind == AdmissionActionKind.CancelTimer }.forEach { action ->
            val deadline = deadlines[action.id]
            if (deadline?.token == action.token) {
                deadlines.remove(action.id)?.future?.cancel(false)
            }
        }
    }

    private fun admissionTimedOut(ownerId: Int, token: Long) {
        var peer: TcpPeer? = null
        var session: Session? = null
        var released = false
        synchronized(lock) {
            if (disposed) return
            val actions = admission.apply(AdmissionEvent(AdmissionEventKind.TimedOut, ownerId, token))
            if (actions.any { it.kind == AdmissionActionKind.Close }) {
                check(actions.any { it.kind == AdmissionActionKind.PendingReleased })
                if (deadlines[ownerId]?.token == token) deadlines.remove(ownerId)
                peer = peers.remove(ownerId)
                session = sessions.remove(ownerId)
                peer?.onClosed = null
                released = true
            }
        }
        session?.dispose()
        peer?.close()
        if (released) onPeerClosed?.invoke(ownerId)
    }

    private fun peerClosed(ownerId: Int) {
        var session: Session? = null
        var closedGeneration = 0L
        var activeClosed = false
        var released = false
        synchronized(lock) {
            if (disposed) return
            peers.remove(ownerId)
            session = sessions.remove(ownerId)
            closedGeneration = session?.generation ?: 0
            val actions = admission.apply(AdmissionEvent(AdmissionEventKind.Closed, ownerId))
            cancelDeadlinesLocked(actions)
            activeClosed = actions.any { it.kind == AdmissionActionKind.ActiveReleased }
            released = activeClosed || actions.any { it.kind == AdmissionActionKind.PendingReleased }
            if (activeClosed) {
                check(activePeer?.id == ownerId)
                activePeer = null
            }
        }
        session?.dispose()
        if (released || session != null) onPeerClosed?.invoke(ownerId)
        if (activeClosed && closedGeneration > 0) onAuthorized?.invoke(false, closedGeneration)
    }

    fun dispose() {
        val ownedPeers: List<TcpPeer>
        val ownedSessions: List<Session>
        var activeGeneration = 0L
        synchronized(lock) {
            if (disposed) return
            disposed = true
            deadlines.values.forEach { it.future.cancel(false) }
            deadlines.clear()
            ownedPeers = peers.values.toList()
            ownedSessions = sessions.values.toList()
            activeGeneration = activePeer?.id?.let { sessions[it]?.generation } ?: 0
            sessions.keys.toList().forEach { ownerId ->
                admission.apply(AdmissionEvent(AdmissionEventKind.Closed, ownerId))
            }
            peers.clear()
            sessions.clear()
            activePeer = null
            admission.close()
        }
        ownedSessions.forEach { it.dispose() }
        ownedPeers.forEach { it.close() }
        scheduler.shutdownNow()
        if (activeGeneration > 0) onAuthorized?.invoke(false, activeGeneration)
    }

    private fun errorFrame(reason: Int): ByteArray {
        val payload = ControlEnvelopeNative.nativeEncodeError(reason)
            ?: throw IllegalStateException("unsupported typed error reason")
        return FrameCodec.encode(Channel.CONTROL, 0, payload)
    }
}
