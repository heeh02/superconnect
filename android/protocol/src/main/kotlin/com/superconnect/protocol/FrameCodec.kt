package com.superconnect.protocol

/**
 * Wire framing — Android/Kotlin mirror of mac SuperconnectCore/FrameCodec.swift (and the ArkTS / C++
 * impls). Pure Kotlin (no Android deps) so it lives in a JVM library module and is conformance-tested
 * against proto/vectors.json off-device. Layout: `channel:u8 | flags:u8 | length:u32-LE | payload`.
 * This is the single most important interop surface — it must stay byte-identical across all platforms.
 */

/** Logical multiplexing channels. proto/protocol.md §2. */
enum class Channel(val value: Int) {
    CONTROL(0), VIDEO(1), INPUT(2), AUDIO(3), STATS(4);
    companion object { fun from(v: Int): Channel? = entries.firstOrNull { it.value == v } }
}

/** Per-frame flag bits. proto/protocol.md §3. */
object FrameFlags {
    const val KEYFRAME = 0x01
    const val CODEC_CONFIG = 0x02
}

/** One protocol message: a channel, flags, and a payload. */
class Frame(val channel: Int, val flags: Int, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Frame && channel == other.channel && flags == other.flags && payload.contentEquals(other.payload)
    override fun hashCode(): Int = (channel * 31 + flags) * 31 + payload.contentHashCode()
}

object FrameCodec {
    const val HEADER_SIZE = 6
    const val MAX_PAYLOAD = 16 * 1024 * 1024   // 16 MiB

    fun encode(channel: Int, flags: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        out[0] = channel.toByte()
        out[1] = flags.toByte()
        val len = payload.size
        out[2] = (len and 0xff).toByte()
        out[3] = ((len ushr 8) and 0xff).toByte()
        out[4] = ((len ushr 16) and 0xff).toByte()
        out[5] = ((len ushr 24) and 0xff).toByte()
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    fun encode(channel: Channel, flags: Int, payload: ByteArray): ByteArray =
        encode(channel.value, flags, payload)
}

/**
 * Accumulates incoming bytes and yields complete frames as they arrive — tolerant of arbitrary
 * fragmentation (one frame split across reads, or many frames in one read). Mirrors the Swift decoder.
 */
class FrameDecoder {
    private var buffer = ByteArray(0)

    fun push(data: ByteArray): List<Frame> {
        buffer += data
        val frames = ArrayList<Frame>()
        var cursor = 0
        while (buffer.size - cursor >= FrameCodec.HEADER_SIZE) {
            val b = cursor
            val channel = buffer[b].toInt() and 0xff
            val flags = buffer[b + 1].toInt() and 0xff
            val len = (buffer[b + 2].toInt() and 0xff) or
                ((buffer[b + 3].toInt() and 0xff) shl 8) or
                ((buffer[b + 4].toInt() and 0xff) shl 16) or
                ((buffer[b + 5].toInt() and 0xff) shl 24)
            if (len > FrameCodec.MAX_PAYLOAD) throw IllegalStateException("frame payload too large: $len")
            val total = FrameCodec.HEADER_SIZE + len
            if (buffer.size - b < total) break   // wait for more bytes
            val start = b + FrameCodec.HEADER_SIZE
            frames.add(Frame(channel, flags, buffer.copyOfRange(start, start + len)))
            cursor += total
        }
        if (cursor > 0) buffer = buffer.copyOfRange(cursor, buffer.size)
        return frames
    }
}
