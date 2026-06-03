package com.superconnect.receiver

import com.superconnect.protocol.FrameDecoder
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
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
    var onClientChange: ((connected: Boolean) -> Unit)? = null

    @Volatile private var running = false
    private var server: ServerSocket? = null
    @Volatile private var client: Socket? = null
    private val sendLock = Any()

    fun start() {
        if (running) return
        running = true
        thread(name = "sc-tcp-server", isDaemon = true) { serveLoop() }
    }

    private fun serveLoop() {
        try {
            val s = ServerSocket()
            s.reuseAddress = true
            s.bind(InetSocketAddress(bindAddress, port))
            server = s
            log("listening $bindAddress:$port")
            while (running) {
                val sock = try { s.accept() } catch (e: Exception) { if (running) log("accept err $e"); break }
                if (client != null) {                 // single-active: keep the incumbent, drop the newcomer
                    log("rejecting 2nd client")
                    try { sock.close() } catch (_: Exception) {}
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

    private fun handleClient(sock: Socket) {
        client = sock
        sock.tcpNoDelay = true
        onClientChange?.invoke(true)
        log("client connected ${sock.inetAddress}")
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
            log("client gone")
        }
    }

    /** Frame already encoded by the caller (FrameCodec). No-op if no client. */
    fun send(bytes: ByteArray) {
        val c = client ?: return
        synchronized(sendLock) {
            try {
                val out = c.getOutputStream()
                out.write(bytes); out.flush()
            } catch (e: Exception) { log("send err $e") }
        }
    }

    fun stop() {
        running = false
        try { client?.close() } catch (_: Exception) {}
        try { server?.close() } catch (_: Exception) {}
        client = null; server = null
    }
}
