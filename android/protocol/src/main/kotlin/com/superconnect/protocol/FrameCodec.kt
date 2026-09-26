package com.superconnect.protocol

/**
 * Wire framing value adapter. Its public Kotlin surface stays platform-neutral while the sole codec
 * authority is Rust via JNI and host tests bind the adapter to canonical bytes.
 * Layout: `channel:u8 | flags:u8 | length:u32-LE | payload`.
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

    fun encode(channel: Int, flags: Int, payload: ByteArray): ByteArray =
        WireNative.withDirect(payload) { direct ->
            WireNative.nativeEncodeFrame(channel, flags, direct, 0, payload.size)
        }

    fun encode(channel: Channel, flags: Int, payload: ByteArray): ByteArray =
        encode(channel.value, flags, payload)
}

/**
 * Accumulates incoming bytes and yields complete frames as they arrive — tolerant of arbitrary
 * fragmentation (one frame split across reads, or many frames in one read). Mirrors the Swift decoder.
 */
class FrameDecoder : AutoCloseable {
    private var handle: Long = WireNative.nativeDecoderNew().also {
        check(it != 0L) { "failed to create Rust frame decoder" }
    }

    @Synchronized fun push(data: ByteArray): List<Frame> {
        check(handle != 0L) { "frame decoder is closed" }
        val records = WireNative.withDirect(data) { direct ->
            WireNative.nativeDecoderPush(handle, direct, 0, data.size)
        }
        return framesFromNativeRecords(records)
    }

    @Synchronized fun reset() {
        check(handle != 0L) { "frame decoder is closed" }
        WireNative.nativeDecoderReset(handle)
    }

    @Synchronized override fun close() {
        if (handle != 0L) {
            WireNative.nativeDecoderFree(handle)
            handle = 0
        }
    }
}

/**
 * Copies payload ownership out of JNI records and overwrites every temporary copy. If a later
 * record is malformed, payloads already copied from earlier records are also released before the
 * exception escapes; a partially built batch must never survive only until GC.
 */
internal fun framesFromNativeRecords(records: Array<ByteArray>): List<Frame> {
    val frames = ArrayList<Frame>(records.size)
    var completed = false
    try {
        records.forEach { record ->
            check(record.size >= 2) { "invalid native frame" }
            frames += Frame(record[0].toInt() and 0xff, record[1].toInt() and 0xff,
                record.copyOfRange(2, record.size))
        }
        completed = true
        return frames
    } finally {
        records.forEach { it.fill(0) }
        if (!completed) frames.forEach { it.payload.fill(0) }
    }
}
