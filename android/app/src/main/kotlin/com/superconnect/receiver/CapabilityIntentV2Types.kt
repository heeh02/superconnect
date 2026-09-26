package com.superconnect.receiver

internal enum class IntentV2Role(val nativeValue: Int) {
    Source(1), Sink(2), Relay(3);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class IntentV2SourceTopology(val nativeValue: Int) {
    Extend(1), Mirror(2), Primary(3), Application(4);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class IntentV2SinkPresentation(val nativeValue: Int) {
    Windowed(1), Fullscreen(2), PictureInPicture(3);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class IntentV2InputPolicy(val nativeValue: Int) {
    ViewOnly(1), RemoteControl(2), RequestControl(3);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class IntentV2Transport(val nativeValue: Int) {
    Reliable(1), LowestLatency(2), Automatic(3);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class IntentV2Topology(val nativeValue: Int) {
    Direct(1), LocalMultiPeer(2), Relayed(3);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal data class IntentV2Resolved(
    val localRole: IntentV2Role,
    val sourceTopology: IntentV2SourceTopology,
    val sinkPresentation: IntentV2SinkPresentation,
    val inputPolicy: IntentV2InputPolicy,
    val transport: IntentV2Transport,
    val topology: IntentV2Topology,
)

internal enum class CapabilityIntentV2EffectKind(val nativeValue: Int) {
    SendOffer(1), SendSelection(2), SendCommit(3), Committed(4), Connected(5),
    Rejected(6), Fatal(7);
    companion object { fun decode(value: Long) = entries.firstOrNull { it.nativeValue.toLong() == value } }
}

internal enum class CapabilityIntentSemanticReason {
    OutOfOrder, StaleGeneration, UnsupportedVersion, UnsupportedCapability, RoleMismatch,
    ProjectionMismatch, TransportMismatch, IntentMismatch, CommitMismatch, LegacyIntentMismatch,
}

internal data class CapabilityIntentV2Effect(
    val kind: CapabilityIntentV2EffectKind,
    val reason: CapabilityIntentSemanticReason?,
    val generation: Long,
    val expectedGeneration: Long,
    val receivedGeneration: Long,
    val negotiationVersion: Int,
    val expectedVersion: Int,
    val receivedVersion: Int,
    val offererRole: IntentV2Role?,
    val selectorRole: IntentV2Role?,
    val localRole: IntentV2Role?,
    val peerRole: IntentV2Role?,
    val projection: IntentV2SourceTopology?,
    val transport: IntentV2Transport?,
    val negotiated: Boolean,
    val resolved: IntentV2Resolved?,
    val expectedRole: IntentV2Role?,
    val receivedRole: IntentV2Role?,
    val expectedProjection: IntentV2SourceTopology?,
    val receivedProjection: IntentV2SourceTopology?,
    val expectedTransport: IntentV2Transport?,
    val receivedTransport: IntentV2Transport?,
)

internal data class CapabilityIntentV2Binding(
    val intent: IntentV2Resolved,
    val peerRole: IntentV2Role,
    val negotiated: Boolean,
)

internal data class CapabilityIntentV2Snapshot(
    val generation: Long,
    val productCapabilities: Long,
    val peerCapabilities: Long,
    val side: Int,
    val desiredPeerRole: IntentV2Role,
    val resolved: IntentV2Resolved,
    val binding: CapabilityIntentV2Binding?,
)

internal object IntentV2Bits {
    const val ROLE_SOURCE = 1L shl 0
    const val ROLE_SINK = 1L shl 1
    const val ROLE_RELAY = 1L shl 2
    const val SOURCE_EXTEND = 1L shl 8
    const val SOURCE_MIRROR = 1L shl 9
    const val SOURCE_PRIMARY = 1L shl 10
    const val SOURCE_APPLICATION = 1L shl 11
    const val SINK_WINDOWED = 1L shl 16
    const val SINK_FULLSCREEN = 1L shl 17
    const val SINK_PICTURE_IN_PICTURE = 1L shl 18
    const val INPUT_VIEW_ONLY = 1L shl 24
    const val INPUT_REMOTE_CONTROL = 1L shl 25
    const val INPUT_REQUEST_CONTROL = 1L shl 26
    const val TRANSPORT_RELIABLE = 1L shl 32
    const val TRANSPORT_LOWEST_LATENCY = 1L shl 33
    const val TRANSPORT_AUTOMATIC = 1L shl 34
    const val TOPOLOGY_DIRECT = 1L shl 40
    const val TOPOLOGY_LOCAL_MULTI_PEER = 1L shl 41
    const val TOPOLOGY_RELAYED = 1L shl 42
}
