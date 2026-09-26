package com.superconnect.receiver

/** Thin JNI adapter over the canonical Rust capability-intent v2 state and wire ABIs. */
internal object CapabilityIntentV2Native {
    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 2) { "Rust capability intent v2 ABI version mismatch" }
    }

    external fun nativeAbiVersion(): Int
    external fun nativeNew(
        generation: Long,
        productCapabilities: Long,
        peerCapabilities: Long,
        side: Int,
        desiredPeerRole: Int,
        localRole: Int,
        sourceTopology: Int,
        sinkPresentation: Int,
        inputPolicy: Int,
        transportPreference: Int,
        topology: Int,
    ): Long

    external fun nativeApply(
        handle: Long,
        type: Int,
        generation: Long,
        version: Int,
        hasVersion: Boolean,
        offererRole: Int,
        selectorRole: Int,
        projection: Int,
        transport: Int,
        localRole: Int,
        sourceTopology: Int,
        sinkPresentation: Int,
        inputPolicy: Int,
        transportPreference: Int,
        topology: Int,
    ): LongArray

    external fun nativeSnapshot(handle: Long): LongArray
    external fun nativeFree(handle: Long)

    fun encodeWire(message: CapabilityIntentV2WireMessage): ByteArray? {
        return nativeEncodeWire(longArrayOf(
            eventType(message.kind),
            message.generation,
            message.negotiationVersion.toLong(),
            message.offererRole.nativeValue.toLong(),
            message.selectorRole.nativeValue.toLong(),
            message.projection.nativeValue.toLong(),
            message.transport.nativeValue.toLong(),
            message.resolved.localRole.nativeValue.toLong(),
            message.resolved.sourceTopology.nativeValue.toLong(),
            message.resolved.sinkPresentation.nativeValue.toLong(),
            message.resolved.inputPolicy.nativeValue.toLong(),
            message.resolved.transport.nativeValue.toLong(),
            message.resolved.topology.nativeValue.toLong(),
        ))
    }

    fun decodeWire(input: ByteArray): CapabilityIntentV2WireMessage? {
        val record = nativeDecodeWire(input)?.takeIf { it.size == WIRE_RECORD_FIELDS } ?: return null
        val kind = wireKind(record[0]) ?: return null
        val offererRole = IntentV2Role.decode(record[3]) ?: return null
        val selectorRole = IntentV2Role.decode(record[4]) ?: return null
        val projection = IntentV2SourceTopology.decode(record[5]) ?: return null
        val transport = IntentV2Transport.decode(record[6]) ?: return null
        val resolved = IntentV2Resolved(
            localRole = IntentV2Role.decode(record[7]) ?: return null,
            sourceTopology = IntentV2SourceTopology.decode(record[8]) ?: return null,
            sinkPresentation = IntentV2SinkPresentation.decode(record[9]) ?: return null,
            inputPolicy = IntentV2InputPolicy.decode(record[10]) ?: return null,
            transport = IntentV2Transport.decode(record[11]) ?: return null,
            topology = IntentV2Topology.decode(record[12]) ?: return null,
        )
        return CapabilityIntentV2WireMessage(
            kind = kind,
            generation = record[1],
            negotiationVersion = record[2].toInt(),
            offererRole = offererRole,
            selectorRole = selectorRole,
            projection = projection,
            transport = transport,
            resolved = resolved,
        )
    }

    fun encodeProfileWire(message: CapabilityIntentProfileV2ProductAdvertisement): ByteArray? {
        val axes = message.productProfile.axes
        if (message.generation == 0L || message.schemaVersion != ABI_VERSION ||
            !CapabilityIntentProfileV2AxisContract.valid(axes) ||
            !CapabilityIntentProfileV2AxisContract.supportsRole(axes, message.senderRole)) {
            return null
        }
        return nativeEncodeProfileWire(longArrayOf(
            message.generation,
            axes.capabilityBits,
            message.senderRole.nativeValue.toLong(),
        ))
    }

    fun decodeProfileWire(input: ByteArray): CapabilityIntentProfileV2PeerAdvertisement? {
        val record = nativeDecodeProfileWire(input)
            ?.takeIf { it.size == PROFILE_RECORD_FIELDS } ?: return null
        val senderRole = IntentV2Role.decode(record[2]) ?: return null
        val axes = CapabilityIntentProfileV2AxisContract.project(record[1]) ?: return null
        if (!CapabilityIntentProfileV2AxisContract.supportsRole(axes, senderRole)) return null
        return CapabilityIntentProfileV2PeerAdvertisement(
            generation = record[0],
            schemaVersion = ABI_VERSION,
            senderRole = senderRole,
            peerProfile = PeerCapabilityProfileV2.project(axes) ?: return null,
        )
    }

    private external fun nativeEncodeWire(record: LongArray): ByteArray?
    private external fun nativeDecodeWire(input: ByteArray): LongArray?
    private external fun nativeEncodeProfileWire(record: LongArray): ByteArray?
    private external fun nativeDecodeProfileWire(input: ByteArray): LongArray?

    /** Kotlin wire kinds 1/2/3 map explicitly to canonical C event kinds 2/3/4. */
    private fun eventType(kind: CapabilityIntentV2WireKind): Long = when (kind) {
        CapabilityIntentV2WireKind.Offer -> 2L
        CapabilityIntentV2WireKind.Selection -> 3L
        CapabilityIntentV2WireKind.Commit -> 4L
    }

    private fun wireKind(eventType: Long): CapabilityIntentV2WireKind? = when (eventType) {
        2L -> CapabilityIntentV2WireKind.Offer
        3L -> CapabilityIntentV2WireKind.Selection
        4L -> CapabilityIntentV2WireKind.Commit
        else -> null
    }

    private const val ABI_VERSION = 2
    private const val WIRE_RECORD_FIELDS = 13
    private const val PROFILE_RECORD_FIELDS = 3
}
