package com.superconnect.protocol

data class VideoMetaFields(
    val wireVersion: Int = 2,
    val isSynthetic: Boolean = false,
    val isKeyframe: Boolean = false,
    val sourceFrameId: Long = 0,
    val captureTimeMs: Long = 0,
    val accessUnitSeq: Long = 0,
    val streamEpoch: Long = 0,
)

data class VideoMetaParse(val fields: VideoMetaFields, val payload: ByteArray)

object VideoFrameMeta {
    const val ABSENT = 1
    const val VALID = 2
    const val MALFORMED = 3

    fun hasMagic(payload: ByteArray): Boolean = payload.size >= 2 && payload[0] == 0x53.toByte() &&
        payload[1] == 0x4d.toByte()

    fun encode(fields: VideoMetaFields): ByteArray = WireNative.nativeEncodeVideoMeta(
        fields.wireVersion, fields.isSynthetic, fields.isKeyframe, fields.sourceFrameId,
        fields.captureTimeMs, fields.accessUnitSeq, fields.streamEpoch,
    )

    fun parse(payload: ByteArray): VideoMetaParse? {
        val values = WireNative.withDirect(payload) { direct ->
            WireNative.nativeDecodeVideoMeta(direct, 0, payload.size)
        }
        check(values.size == 9) { "invalid native video metadata result" }
        if (values[0].toInt() != VALID) return null
        val offset = values[7].toInt()
        check(offset in 0..payload.size) { "invalid native video metadata offset" }
        return VideoMetaParse(
            VideoMetaFields(
                wireVersion = values[1].toInt(), isSynthetic = values[2] != 0L,
                isKeyframe = values[3] != 0L, sourceFrameId = values[4],
                captureTimeMs = values[5], accessUnitSeq = values[6], streamEpoch = values[8],
            ),
            payload.copyOfRange(offset, payload.size),
        )
    }
}
