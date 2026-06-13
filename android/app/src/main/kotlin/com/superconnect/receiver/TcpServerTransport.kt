package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import com.superconnect.protocol.FrameDecoder
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.concurrent.thread

/**
 * TCP server — the Android receiver LISTENS; the Mac host dials in (wired via `adb forward` to
 * 127.0.0.1:8888, or wireless to the LAN IP later). Mirrors HarmonyOS TcpServerTransport: SINGLE
 * active client (a 2nd is rejected so two Macs can't fight one decoder), a frame read loop, and a
 * send back-channel (for hello_ack / pong / INPUT). Accept + read run on a daemon thread; callbacks
 * fire on that thread, so the UI marshals to the main thread.
 *
 * Default bind is loopback (the wired adb path). Wireless (0.0.0.0 + TOFU pairing) is a later increment.
 */
class TcpServerTransport(
    private val port: Int = 8888,
    private val bindAddress: String = "127.0.0.1",
    private val log: (String) -> Unit = {},
) {
    var onFrame: ((channel: Int, flags: Int, payload: ByteArray) -> Unit)? = null
    /** Fired on the server thread right AFTER the listen socket is bound (never if bind fails). The
     *  wireless layer advertises over mDNS from here so it never publishes a not-yet-listening (or
     *  failed) service. Mirrors HarmonyOS onListening. Null on the wired path. */
    var onListening: ((address: String, port: Int) -> Unit)? = null
    var onClientChange: ((connected: Boolean) -> Unit)? = null

    /** Fired when a client disconnects, with its transport-assigned [clientOwnerId]. Lets WirelessService
     *  cancel a pairing prompt owned by a peer that went away — keyed on the (unspoofable) ownerId so only
     *  the owning connection can clear its prompt. Null on the wired path. Mirrors HarmonyOS onClientGone. */
    var onClientGone: ((ownerId: Int) -> Unit)? = null

    /** True while the connected client came in over loopback (wired / adb-forwarded). The wireless TOFU
     *  pairing gate exempts loopback and only challenges LAN clients. Set on connect, before frames flow. */
    @Volatile var clientIsLocalhost: Boolean = false
        private set

    /** Identity of the current client (monotonic, transport-assigned). The pairing gate carries it so a
     *  disconnect can cancel ONLY this connection's in-flight prompt (peerId is spoofable; this isn't). */
    @Volatile var clientOwnerId: Int = 0
        private set
    private var ownerSeq = 0

    @Volatile private var running = false
    private var server: ServerSocket? = null
    @Volatile private var client: Socket? = null
    private val sendLock = Any()
    // All back-channel writes (INPUT / pong / hello_ack / request_keyframe) run here, NOT on the caller's
    // thread. INPUT and keyboard are dispatched from the UI/main thread, and Android forbids a socket write
    // on the main thread (NetworkOnMainThreadException) — which silently dropped every input event. A single
    // worker keeps writes ordered and off whatever thread enqueued them.
    @Volatile private var sender: ExecutorService? = null

    fun start() {
        if (running) return
        running = true
        sender = Executors.newSingleThreadExecutor { r -> Thread(r, "sc-tcp-send").apply { isDaemon = true } }
        thread(name = "sc-tcp-server", isDaemon = true) { serveLoop() }
    }

    private fun serveLoop() {
        try {
            val s = ServerSocket()
            s.reuseAddress = true
            s.bind(InetSocketAddress(bindAddress, port))
            server = s
            log("listening $bindAddress:$port")
            onListening?.invoke(bindAddress, port)   // advertise only now (bind succeeded), not before
            while (running) {
                val sock = try { s.accept() } catch (e: Exception) { if (running) log("accept err $e"); break }
                if (client != null) {                 // single-active: keep the incumbent, drop the newcomer
                    log("rejecting 2nd client (session_busy)")
                    rejectBusy(sock)                   // explicit error ⇒ Mac fails fast (no reconnect storm)
                    continue
                }
                handleClient(sock)                     // blocks until this client goes away, then we accept again
            }
        } catch (e: Exception) {
            log("server err $e")
        } finally {
            try { server?.close() } catch (_: Exception) {}
        }
    }

    /** Reject a surplus client (single-active guard): send a framed `{type:error,message:session_busy}`
     *  CONTROL frame, THEN close. The explicit error lets the Mac fail fast (HostConnection treats it
     *  fatal — no reconnect loop) instead of treating a silent close as a drop. Mirrors HarmonyOS rejectBusy. */
    private fun rejectBusy(sock: Socket) {
        try {
            val json = "{\"type\":\"error\",\"message\":\"session_busy\"}".toByteArray(Charsets.UTF_8)
            val frame = FrameCodec.encode(Channel.CONTROL, 0, json)
            sock.getOutputStream().apply { write(frame); flush() }
        } catch (_: Exception) {}
        try { sock.close() } catch (_: Exception) {}
    }

    private fun handleClient(sock: Socket) {
        client = sock
        clientOwnerId = ++ownerSeq          // single accept thread ⇒ no race; identifies THIS connection
        val myOwner = clientOwnerId
        sock.tcpNoDelay = true
        clientIsLocalhost = sock.inetAddress?.isLoopbackAddress ?: false   // wired/adb (loopback) is pairing-exempt; LAN needs TOFU
        onClientChange?.invoke(true)
        log("client connected ${sock.inetAddress} (localhost=$clientIsLocalhost, owner=$myOwner)")
        val decoder = FrameDecoder()
        val buf = ByteArray(64 * 1024)
        try {
            val input = sock.getInputStream()
            while (running) {
                val n = input.read(buf)
                if (n < 0) break
                if (n == 0) continue
                for (f in decoder.push(buf.copyOf(n))) onFrame?.invoke(f.channel, f.flags, f.payload)
            }
        } catch (e: Exception) {
            if (running) log("client read err $e")
        } finally {
            try { sock.close() } catch (_: Exception) {}
            client = null
            onClientChange?.invoke(false)
            onClientGone?.invoke(myOwner)   // free any in-flight pairing prompt owned by this connection
            log("client gone (owner=$myOwner)")
        }
    }

    /** Frame already encoded by the caller (FrameCodec). The write is handed to the sender thread so it
     *  never runs on the caller's thread (INPUT/keyboard come from the UI thread). No-op if no client. */
    fun send(bytes: ByteArray) {
        if (client == null) return
        val ex = sender ?: return
        try {
            ex.execute {
                val c = client ?: return@execute
                synchronized(sendLock) {
                    try {
                        val out = c.getOutputStream()
                        out.write(bytes); out.flush()
                    } catch (e: Exception) { log("send err $e") }
                }
            }
        } catch (_: RejectedExecutionException) { /* transport stopping — drop */ }
    }

    fun stop() {
        running = false
        sender?.shutdownNow(); sender = null
        try { client?.close() } catch (_: Exception) {}
        try { server?.close() } catch (_: Exception) {}
        client = null; server = null
    }
}
