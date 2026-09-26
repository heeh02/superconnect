package com.superconnect.receiver

import java.net.Socket
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

enum class ListenerOrigin {
    Wired,
    Wireless,
}

@JvmInline
value class WriteOperationId(val value: Long) {
    init { require(value > 0) { "write operation identifier must be positive" } }
}

data class WriteCompletionBinding(
    val operation: Long,
    val sessionGeneration: Long,
) {
    init {
        require(operation > 0) { "reducer operation must be positive" }
        require(sessionGeneration > 0) { "session generation must be positive" }
    }
}

enum class WriteCompletionResult {
    Written,
    Failed,
    Closed,
}

data class WriteCompletion(
    val writeOperation: WriteOperationId,
    val binding: WriteCompletionBinding,
    val result: WriteCompletionResult,
)

/**
 * Ordered frame writer whose completion means the whole frame was written and flushed.
 * [send] borrows its byte array only until return; an implementation must copy before retaining it.
 */
fun interface OrderedFrameWriter {
    fun send(
        bytes: ByteArray,
        binding: WriteCompletionBinding?,
        completion: ((WriteCompletion) -> Unit)?,
    ): WriteOperationId?
}

/** One accepted socket with independent read and ordered-write ownership. */
class TcpPeer internal constructor(
    val id: Int,
    val origin: ListenerOrigin,
    val remoteAddress: String,
    private val socket: Socket,
    private val log: (String) -> Unit = {},
    private val writeOverride: ((ByteArray) -> Unit)? = null,
    private val onOwnedBytesReleased: ((ByteArray) -> Unit)? = null,
    initialWriteOperationForTesting: Long = 1L,
) : OrderedFrameWriter {
    @Volatile var onBytes: ((ByteArray) -> Unit)? = null
    @Volatile var onClosed: (() -> Unit)? = null
    internal var onFinished: ((TcpPeer) -> Unit)? = null

    private val reading = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private enum class OutboundClass { Reliable, ReceiverProgress }
    private data class Outbound(
        val operation: WriteOperationId,
        val bytes: ByteArray,
        val classification: OutboundClass,
        val binding: WriteCompletionBinding? = null,
        val completion: ((WriteCompletion) -> Unit)? = null,
        val closeAfter: Boolean = false,
        val closeOnly: Boolean = false,
    ) {
        val completionDelivered = AtomicBoolean(false)
        private val bytesReleased = AtomicBoolean(false)
        fun releaseBytes(): Boolean {
            if (!bytesReleased.compareAndSet(false, true)) return false
            bytes.fill(0)
            return true
        }
    }
    private val queueLock = ReentrantLock()
    private val queueReady = queueLock.newCondition()
    private val outbound = ArrayDeque<Outbound>()
    private var inFlight: Outbound? = null
    private var nextWriteOperation = initialWriteOperationForTesting
    private val writer = thread(name = "sc-peer-$id-send", isDaemon = true) { writeLoop() }

    init {
        require(initialWriteOperationForTesting > 0)
        if (writeOverride == null) socket.tcpNoDelay = true
    }

    fun startReading() {
        if (!reading.compareAndSet(false, true)) return
        thread(name = "sc-peer-$id-read", isDaemon = true) {
            val buffer = ByteArray(64 * 1024)
            try {
                val input = socket.getInputStream()
                while (!closed.get()) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        val owned = buffer.copyOf(count)
                        try {
                            onBytes?.invoke(owned)
                        } finally {
                            // The callback is synchronous; Session's FrameDecoder has copied the bytes.
                            owned.fill(0)
                        }
                    }
                }
            } catch (error: Exception) {
                if (!closed.get()) safeLog("peer $id read error: $error")
            } finally {
                buffer.fill(0)
                finish()
            }
        }
    }

    fun send(bytes: ByteArray): WriteOperationId? = enqueue(bytes, OutboundClass.Reliable)

    override fun send(
        bytes: ByteArray,
        binding: WriteCompletionBinding?,
        completion: ((WriteCompletion) -> Unit)?,
    ): WriteOperationId? {
        require((binding == null) == (completion == null)) {
            "write completion binding and callback must be supplied together"
        }
        return enqueue(bytes, OutboundClass.Reliable, binding = binding, completion = completion)
    }

    /** True means the exact bytes were admitted to this peer's ordered writer. */
    fun trySend(bytes: ByteArray): Boolean {
        return send(bytes) != null
    }

    /**
     * Reliable but replaceable diagnostics lane. At most one unsent progress record exists and the
     * writer always drains reliable CONTROL/INPUT before it, so telemetry cannot delay user input.
     */
    internal fun trySendReceiverProgress(bytes: ByteArray): Boolean {
        return enqueue(bytes, OutboundClass.ReceiverProgress) != null
    }

    internal fun sendAndClose(bytes: ByteArray) {
        if (enqueue(bytes, OutboundClass.Reliable, closeAfter = true) == null) finish()
    }

    internal fun closeAfterWrites() {
        if (closed.get()) return
        var exhausted = false
        queueLock.withLock {
            if (closed.get()) return
            val operation = allocateWriteOperationLocked() ?: run {
                exhausted = true
                return@withLock
            }
            outbound.addLast(Outbound(operation, ByteArray(0), OutboundClass.Reliable,
                closeAfter = true, closeOnly = true))
            queueReady.signalAll()
        }
        if (exhausted) finish()
    }

    private fun enqueue(
        bytes: ByteArray,
        classification: OutboundClass,
        binding: WriteCompletionBinding? = null,
        completion: ((WriteCompletion) -> Unit)? = null,
        closeAfter: Boolean = false,
    ): WriteOperationId? {
        if (closed.get()) return null
        val owned = bytes.copyOf()
        var admitted = false
        val replaced = ArrayList<Outbound>(1)
        var result: WriteOperationId? = null
        try {
            result = queueLock.withLock {
                if (closed.get()) return@withLock null
                if (classification == OutboundClass.ReceiverProgress) {
                    // Replacement moves the newest sample behind all reliable work already admitted.
                    val iterator = outbound.iterator()
                    while (iterator.hasNext()) {
                        val pending = iterator.next()
                        if (pending.classification == OutboundClass.ReceiverProgress) {
                            iterator.remove()
                            replaced.add(pending)
                        }
                    }
                    if (outbound.size >= PROGRESS_SOFT_QUEUE_LIMIT) return@withLock null
                }
                val operation = allocateWriteOperationLocked() ?: return@withLock null
                outbound.addLast(Outbound(
                    operation = operation,
                    bytes = owned,
                    classification = classification,
                    binding = binding,
                    completion = completion,
                    closeAfter = closeAfter,
                ))
                admitted = true
                queueReady.signalAll()
                operation
            }
        } finally {
            if (!admitted) releaseOwnedBytes(owned)
            replaced.forEach(::releaseBytes)
        }
        return result
    }

    private fun allocateWriteOperationLocked(): WriteOperationId? {
        if (nextWriteOperation <= 0) return null
        val operation = WriteOperationId(nextWriteOperation)
        nextWriteOperation = if (nextWriteOperation == Long.MAX_VALUE) 0 else nextWriteOperation + 1
        return operation
    }

    private fun writeLoop() {
        while (true) {
            val item = queueLock.withLock {
                while (!closed.get() && outbound.isEmpty()) {
                    try { queueReady.await() } catch (_: InterruptedException) {}
                }
                if (closed.get()) null else takeNextLocked().also { inFlight = it }
            } ?: return
            val result = try {
                if (!item.closeOnly) {
                    val override = writeOverride
                    if (override != null) {
                        override(item.bytes)
                    } else {
                        val output = socket.getOutputStream()
                        output.write(item.bytes)
                        output.flush()
                    }
                }
                if (closed.get()) WriteCompletionResult.Closed else WriteCompletionResult.Written
            } catch (error: Throwable) {
                if (!closed.get()) safeLog("peer $id send error: $error")
                if (closed.get()) WriteCompletionResult.Closed else WriteCompletionResult.Failed
            }
            if (result != WriteCompletionResult.Written) {
                queueLock.withLock {
                    if (inFlight === item) inFlight = null
                }
                // A failed/closed completion is externally visible only after the physical socket
                // has been closed. The I/O already returned, so this remains the sole safe point to
                // release the in-flight bytes.
                finish()
                retire(item, result)
                return
            }
            retire(item, result)
            queueLock.withLock {
                if (inFlight === item) inFlight = null
            }
            if (item.closeAfter) {
                finish()
                return
            }
        }
    }

    /** Preserve reliable order while allowing diagnostics to wait behind every reliable record. */
    private fun takeNextLocked(): Outbound {
        val iterator = outbound.iterator()
        while (iterator.hasNext()) {
            val item = iterator.next()
            if (item.classification == OutboundClass.Reliable) {
                iterator.remove()
                return item
            }
        }
        return outbound.removeFirst()
    }

    fun close() {
        finish()
    }

    private fun finish() {
        if (!closed.compareAndSet(false, true)) return
        val cancelled = queueLock.withLock {
            // The writer alone releases in-flight bytes after write/flush has actually returned.
            // Clearing them here would race a native socket write or a test writeOverride.
            val pending = ArrayList<Outbound>(outbound.size)
            pending.addAll(outbound)
            outbound.clear()
            queueReady.signalAll()
            pending
        }
        // Physical close must happen before any external completion callback. Queued writes can be
        // cancelled now; the writer remains the sole authority that settles an in-flight write only
        // after its write/flush call has actually returned or thrown.
        try { socket.close() } catch (_: Exception) {}
        if (Thread.currentThread() !== writer) writer.interrupt()
        cancelled.forEach { retire(it, WriteCompletionResult.Closed) }
        invokeLifecycle("finished") { onFinished?.invoke(this) }
        invokeLifecycle("closed") { onClosed?.invoke() }
    }

    private fun retire(item: Outbound, result: WriteCompletionResult) {
        releaseBytes(item)
        completeOnly(item, result)
    }

    private fun completeOnly(item: Outbound, result: WriteCompletionResult) {
        val binding = item.binding ?: return
        val callback = item.completion ?: return
        if (!item.completionDelivered.compareAndSet(false, true)) return
        try {
            callback(WriteCompletion(item.operation, binding, result))
        } catch (error: Throwable) {
            safeLog("peer $id write completion error: $error")
        }
    }

    private fun releaseBytes(item: Outbound) {
        if (item.releaseBytes()) notifyOwnedBytesReleased(item.bytes)
    }

    private fun releaseOwnedBytes(bytes: ByteArray) {
        bytes.fill(0)
        notifyOwnedBytesReleased(bytes)
    }

    private fun notifyOwnedBytesReleased(bytes: ByteArray) {
        try {
            onOwnedBytesReleased?.invoke(bytes)
        } catch (error: Throwable) {
            safeLog("peer $id owned-bytes observer error: $error")
        }
    }

    /** Lifecycle observers are diagnostics/coordination only and can never block terminal retire. */
    private fun invokeLifecycle(name: String, callback: () -> Unit) {
        try {
            callback()
        } catch (error: Throwable) {
            safeLog("peer $id $name callback error: $error")
        }
    }

    private fun safeLog(message: String) {
        try { log(message) } catch (_: Throwable) {}
    }

    private companion object {
        const val PROGRESS_SOFT_QUEUE_LIMIT = 32
    }
}
