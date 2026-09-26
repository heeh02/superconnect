package com.superconnect.receiver

internal data class CanonicalVideoConfig(
    val codec: String,
    val width: Int,
    val height: Int,
    val refreshRate: Int,
    val lowLatency: Boolean,
)

/** Thin projection over the canonical Rust video_config CONTROL codec. */
internal object VideoConfigWireNative {
    internal const val CODEC_H264 = 1
    internal val advertisedCodecs: List<String> = listOf("h264")
    private const val HDR_OFF = 1

    internal fun wireCodec(codec: String): Int? = when (codec.lowercase()) {
        "h264" -> CODEC_H264
        else -> null
    }

    fun encode(value: CanonicalVideoConfig): ByteArray? {
        val codec = wireCodec(value.codec) ?: return null
        return ReceiverProgressNative.nativeEncodeVideoConfig(intArrayOf(
            codec, HDR_OFF, value.width, value.height, value.refreshRate,
            if (value.lowLatency) 1 else 0,
        ))
    }

    fun decode(wire: ByteArray): CanonicalVideoConfig? =
        ReceiverProgressNative.nativeDecodeVideoConfig(wire)?.let(::decodeRecord)

    internal fun decodeRecord(record: IntArray): CanonicalVideoConfig? {
        if (record.size != 6 || record[0] != CODEC_H264 || record[1] != HDR_OFF ||
            record[5] !in 0..1) return null
        return CanonicalVideoConfig(
            codec = "h264",
            width = record[2], height = record[3], refreshRate = record[4],
            lowLatency = record[5] == 1,
        )
    }
}
