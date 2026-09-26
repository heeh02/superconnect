package com.superconnect.receiver

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * One TCP listener. Accept never enters a peer read loop: every socket becomes an independent
 * [TcpPeer], allowing silent pre-auth clients to coexist until admission decides their fate.
 */
class TcpServerTransport(
    private val port: Int = 8888,
    private val bindAddress: String = "127.0.0.1",
    private val log: (String) -> Unit = {},
) {
    var onPeer: ((TcpPeer) -> Unit)? = null
    var onListening: ((address: String, port: Int) -> Unit)? = null
    var onListenFailed: ((address: String, firstPort: Int) -> Unit)? = null

    @Volatile private var running = false
    @Volatile private var server: ServerSocket? = null
    private val peers = ConcurrentHashMap<Int, TcpPeer>()
    private val generation = AtomicInteger(0)

    fun start() {
        val address = InetAddress.getByName(bindAddress)
        val origin = if (address.isLoopbackAddress) ListenerOrigin.Wired else ListenerOrigin.Wireless
        start(bindAddress, port, origin, 1)
    }

    @Synchronized
    fun start(address: String, port: Int, origin: ListenerOrigin, portAttempts: Int = 1) {
        if (running) return
        running = true
        val expectedGeneration = generation.incrementAndGet()
        thread(name = "sc-tcp-${origin.name.lowercase()}-listener", isDaemon = true) {
            serveLoop(address, port, origin, portAttempts.coerceAtLeast(1), expectedGeneration)
        }
    }

    private fun serveLoop(address: String, requestedPort: Int, origin: ListenerOrigin, portAttempts: Int,
                          expectedGeneration: Int) {
        var listener: ServerSocket? = null
        try {
            var lastBindError: Exception? = null
            for (offset in 0 until portAttempts) {
                val candidate = ServerSocket()
                val candidatePort = if (requestedPort == 0) 0 else requestedPort + offset
                try {
                    candidate.reuseAddress = true
                    candidate.bind(InetSocketAddress(address, candidatePort))
                    listener = candidate
                    break
                } catch (error: Exception) {
                    lastBindError = error
                    try { candidate.close() } catch (_: Exception) {}
                    log("bind failed $address:$candidatePort: $error")
                }
            }
            val candidate = listener ?: throw lastBindError ?: IllegalStateException("no listen candidate")
            synchronized(this) {
                if (!running || generation.get() != expectedGeneration) {
                    candidate.close()
                    return
                }
                server = candidate
            }
            if (!running || generation.get() != expectedGeneration) {
                candidate.close()
                return
            }
            val actualPort = candidate.localPort
            log("listening $address:$actualPort origin=$origin")
            onListening?.invoke(address, actualPort)
            while (running && generation.get() == expectedGeneration) {
                val socket = try {
                    candidate.accept()
                } catch (error: Exception) {
                    if (running && generation.get() == expectedGeneration) log("accept error: $error")
                    break
                }
                if (!running || generation.get() != expectedGeneration) {
                    socket.close()
                    break
                }
                val id = ownerSequence.incrementAndGet()
                val peer = TcpPeer(
                    id = id,
                    origin = origin,
                    remoteAddress = socket.inetAddress?.hostAddress ?: "",
                    socket = socket,
                    log = log,
                )
                peers[id] = peer
                peer.onFinished = ::peerFinished
                val handler = onPeer
                if (handler == null) {
                    log("no peer handler; closing owner=$id")
                    peer.close()
                    continue
                }
                try {
                    handler(peer)
                    peer.startReading()
                } catch (error: Exception) {
                    log("peer setup error: $error")
                    peer.close()
                }
            }
        } catch (error: Exception) {
            if (running && generation.get() == expectedGeneration) {
                log("server error: $error")
                onListenFailed?.invoke(address, requestedPort)
            }
        } finally {
            try { listener?.close() } catch (_: Exception) {}
            synchronized(this) {
                if (server === listener) server = null
                if (generation.get() == expectedGeneration && server == null) running = false
            }
        }
    }

    private fun peerFinished(peer: TcpPeer) {
        peers.remove(peer.id)
    }

    @Synchronized
    fun stop() {
        if (!running) return
        running = false
        generation.incrementAndGet()
        try { server?.close() } catch (_: Exception) {}
        server = null
        peers.forEach { _, peer -> peer.close() }
        peers.clear()
    }

    private companion object {
        // Multiple listener instances feed one ReceiverSessionHost, so IDs must be process-unique.
        val ownerSequence = AtomicInteger(0)
    }
}
