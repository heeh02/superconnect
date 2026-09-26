package com.superconnect.receiver

import com.superconnect.protocol.Channel

/** Advances final authentication only after the writer reports this exact generation and write. */
internal class SessionFinalAckWriter(
    private val frameWriter: OrderedFrameWriter,
    private val sessionLock: Any,
    private val sessionGeneration: () -> Long,
    private val frame: (Int, Int, ByteArray) -> ByteArray,
    private val isDisposed: () -> Boolean,
    private val complete: (operation: Long, success: Boolean, generation: Long) -> Unit,
    private val failTransport: () -> Unit,
    private val log: (String) -> Unit,
) {
    private data class PendingWrite(
        val binding: WriteCompletionBinding,
        var writeOperation: WriteOperationId? = null,
        var earlyCompletion: WriteCompletion? = null,
        var duplicateEarlyCompletion: Boolean = false,
    )

    private var pendingWrite: PendingWrite? = null

    fun hasPending(): Boolean = pendingWrite != null

    fun cancel() {
        pendingWrite = null
    }

    /** Consumes [payload] on acceptance, rejection, completion races, and exceptions. */
    fun submit(operation: Long, payload: ByteArray) {
        if (pendingWrite != null) {
            payload.fill(0)
            return failTransport()
        }
        val binding = WriteCompletionBinding(operation, sessionGeneration())
        val pending = PendingWrite(binding)
        pendingWrite = pending
        val writeOperation = try {
            val frame = frame(Channel.CONTROL.value, 0, payload)
            try {
                frameWriter.send(frame, binding, ::onWriteCompleted)
            } finally {
                // OrderedFrameWriter borrows this array only for send(); TcpPeer owns a copy.
                frame.fill(0)
            }
        } catch (error: Throwable) {
            log("final ACK writer rejected operation=$operation: $error")
            null
        } finally {
            payload.fill(0)
        }
        if (writeOperation == null) {
            if (pendingWrite === pending) pendingWrite = null
            complete(operation, false, binding.sessionGeneration)
            return
        }
        if (pendingWrite !== pending) return
        pending.writeOperation = writeOperation
        if (pending.duplicateEarlyCompletion) {
            pendingWrite = null
            complete(operation, false, binding.sessionGeneration)
            return
        }
        pending.earlyCompletion?.let(::acceptCompletion)
        pending.earlyCompletion = null
    }

    private fun onWriteCompleted(completion: WriteCompletion) {
        synchronized(sessionLock) {
            if (isDisposed()) return
            val pending = pendingWrite ?: return
            if (completion.binding != pending.binding) return
            if (pending.writeOperation == null) {
                if (pending.earlyCompletion == null) pending.earlyCompletion = completion
                else pending.duplicateEarlyCompletion = true
                return
            }
            acceptCompletion(completion)
        }
    }

    private fun acceptCompletion(completion: WriteCompletion) {
        val pending = pendingWrite ?: return
        val writeOperation = pending.writeOperation ?: return
        if (completion.binding != pending.binding || completion.writeOperation != writeOperation) return
        pendingWrite = null
        complete(
            completion.binding.operation,
            completion.result == WriteCompletionResult.Written,
            completion.binding.sessionGeneration,
        )
    }
}
