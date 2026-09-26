package com.superconnect.receiver

import com.superconnect.protocol.Channel

/** Native input shares the session lock and authenticated ordered writer with CONTROL. */
internal class SessionInputWriter(
    private val lock: Any,
    private val writable: () -> Boolean,
    private val seal: (Int, Int, ByteArray) -> ByteArray,
    private val writer: OrderedFrameWriter,
    private val control: SessionControlWriter,
    private val failed: () -> Unit,
) {
    fun send(payload: ByteArray) = synchronized(lock) {
        if (!writable()) return@synchronized
        try {
            val frame = seal(Channel.INPUT.value, 0, payload)
            try { if (writer.send(frame, null, null) == null) failed() }
            finally { frame.fill(0) }
        } catch (_: Exception) { failed() }
    }
    fun text(text: String) = synchronized(lock) {
        if (writable()) ControlEnvelopeNative.encodeText(text)?.let(control::send)
    }
}
