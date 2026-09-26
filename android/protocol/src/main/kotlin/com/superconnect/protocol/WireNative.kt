package com.superconnect.protocol

import java.nio.ByteBuffer

/** Thin, fail-closed JNI binding to the portable Rust wire ABI. */
internal object WireNative {
    private val zeroPage = ByteArray(4096)

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1) { "unsupported Superconnect wire ABI" }
    }

    external fun nativeAbiVersion(): Int
    external fun nativeEncodeFrame(channel: Int, flags: Int, bytes: ByteBuffer, offset: Int, length: Int): ByteArray
    external fun nativeDecoderNew(): Long
    external fun nativeDecoderPush(handle: Long, bytes: ByteBuffer, offset: Int, length: Int): Array<ByteArray>
    external fun nativeDecoderReset(handle: Long)
    external fun nativeDecoderFree(handle: Long)
    external fun nativeEncodeVideoMeta(
        version: Int, synthetic: Boolean, keyframe: Boolean, sourceFrameId: Long,
        captureTimeMs: Long, accessUnitSeq: Long, streamEpoch: Long,
    ): ByteArray
    external fun nativeDecodeVideoMeta(bytes: ByteBuffer, offset: Int, length: Int): LongArray

    /**
     * Copies [bytes] into a JNI direct buffer for the duration of one synchronous native call.
     * The block must not retain [ByteBuffer]; its complete capacity is overwritten before return,
     * including exceptional returns from JNI.
     */
    fun <T> withDirect(bytes: ByteArray, block: (ByteBuffer) -> T): T {
        val buffer = ByteBuffer.allocateDirect(bytes.size).apply {
            put(bytes)
            flip()
        }
        return try {
            block(buffer)
        } finally {
            buffer.clear()
            while (buffer.hasRemaining()) {
                val count = minOf(buffer.remaining(), zeroPage.size)
                buffer.put(zeroPage, 0, count)
            }
            buffer.clear()
        }
    }
}
