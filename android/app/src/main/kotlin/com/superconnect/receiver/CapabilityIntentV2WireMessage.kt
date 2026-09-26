package com.superconnect.receiver

/** Transaction-only wire value. Generation is an opaque UInt64 bit pattern carried in a Long. */
internal enum class CapabilityIntentV2WireKind(val nativeValue: Int) {
    Offer(1), Selection(2), Commit(3),
}

internal data class CapabilityIntentV2WireMessage(
    val kind: CapabilityIntentV2WireKind,
    val generation: Long,
    val negotiationVersion: Int,
    val offererRole: IntentV2Role,
    val selectorRole: IntentV2Role,
    val projection: IntentV2SourceTopology,
    val transport: IntentV2Transport,
    val resolved: IntentV2Resolved,
)
