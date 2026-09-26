package com.superconnect.receiver

/** One fully reassembled VIDEO frame after optional SM metadata validation. */
data class ReceivedVideoAccessUnit(
    val payload: ByteArray,
    val isKeyframe: Boolean,
    /** Zero means the legacy stream carried no trustworthy source identity. */
    val sourceFrameId: Long,
    val streamEpoch: Long,
)
