package com.superconnect.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Typed projection of the portable Rust CONTROL envelope authority. */
internal data class ControlEnvelopeEvent(
    val kind: Int,
    val presence: Int,
    val generation: Long,
    val operation: Long,
    val value0: Long,
    val value1: Long,
    val detail: Int,
)

internal object ControlEnvelopeNative {
    private external fun nativeDecode(source: ByteArray): LongArray?
    private external fun nativeEncodeText(text: ByteArray): ByteArray?
    external fun nativeEncodeError(reason: Int): ByteArray?
    external fun nativeEncodeSessionFatalError(reason: Int): ByteArray?
    external fun nativeEncodeUdpAux(kind: Int, operation: Long): ByteArray?

    fun decode(source: ByteArray): ControlEnvelopeEvent? {
        val values = nativeDecode(source)?.takeIf { it.size == 7 } ?: return null
        return ControlEnvelopeEvent(
            kind = values[0].toInt(), presence = values[1].toInt(),
            generation = values[2], operation = values[3], value0 = values[4],
            value1 = values[5], detail = values[6].toInt(),
        )
    }

    /** Projects an already classified ScControlEnvelopeV1 without parsing CONTROL wire again. */
    fun decodeRecord(record: ByteArray): ControlEnvelopeEvent? {
        if (record.size != 64) return null
        val view = ByteBuffer.wrap(record).order(ByteOrder.LITTLE_ENDIAN)
        if (view.getInt(0) != 64 || view.getInt(4) != 1 || view.getInt(52) != 0 ||
            view.getLong(56) != 0L) return null
        return ControlEnvelopeEvent(
            kind = view.getInt(8), presence = view.getInt(12),
            generation = view.getLong(16), operation = view.getLong(24),
            value0 = view.getLong(32), value1 = view.getLong(40), detail = view.getInt(48),
        ).takeIf { it.kind in ControlEnvelopeKind.Hello..ControlEnvelopeKind.UdpUnavailable }
    }

    fun encodeText(text: String): ByteArray? {
        val bytes = text.toByteArray(Charsets.UTF_8)
        return try { nativeEncodeText(bytes) } finally { bytes.fill(0) }
    }

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
    }
}
