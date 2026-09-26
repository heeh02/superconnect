package com.superconnect.receiver

/**
 * Advances the Core inbound decoder one frame at a time.
 *
 * A socket read may contain a handshake transition and a subsequent record in the same byte
 * array. Core therefore exposes at most one frame per push; the next buffered frame is opened
 * only after the caller has routed the current frame and completed its synchronous effects.
 */
internal class SessionInboundPump(
    private val reducer: SessionReducer,
    private val router: SessionFrameRouter,
    private val canAdvance: () -> Boolean,
    private val isDisposed: () -> Boolean,
) : AutoCloseable {
    private var stagedInput = ByteArray(0)
    private var closed = false

    fun push(bytes: ByteArray) {
        if (closed || isDisposed()) return
        if (stagedInput.isNotEmpty() || !canAdvance()) {
            stage(bytes)
            if (canAdvance()) drain(EMPTY_INPUT)
            return
        }
        drain(bytes)
    }

    private fun drain(initialInput: ByteArray) {
        var input = initialInput
        var ownedInput: ByteArray? = null
        while (true) {
            val frames = try {
                reducer.push(input)
            } finally {
                ownedInput?.fill(0)
                ownedInput = null
            }
            check(frames.size <= 1) { "Core exposed more than one inbound frame per push" }
            if (frames.isEmpty()) {
                if (!canAdvance() || stagedInput.isEmpty()) return
                ownedInput = takeStaged()
                input = checkNotNull(ownedInput)
                continue
            }
            frames.single().let { frame ->
                if (!router.route(frame)) frame.payload.fill(0)
            }
            if (isDisposed() || !canAdvance()) return
            input = EMPTY_INPUT
        }
    }

    private fun stage(bytes: ByteArray) {
        check(bytes.size <= MAX_STAGED_INPUT_BYTES - stagedInput.size) {
            "staged secure ingress exceeded its pre-Record bound"
        }
        if (bytes.isEmpty()) return
        val combined = ByteArray(stagedInput.size + bytes.size)
        stagedInput.copyInto(combined)
        bytes.copyInto(combined, stagedInput.size)
        stagedInput.fill(0)
        stagedInput = combined
    }

    private fun takeStaged(): ByteArray = stagedInput.also { stagedInput = ByteArray(0) }

    override fun close() {
        if (closed) return
        closed = true
        stagedInput.fill(0)
        stagedInput = ByteArray(0)
    }

    private companion object {
        /** Empty input advances bytes already buffered by Core without splitting socket reads. */
        val EMPTY_INPUT = ByteArray(0)
        const val MAX_STAGED_INPUT_BYTES = 1024 * 1024
    }
}
