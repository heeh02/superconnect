package com.superconnect.receiver

/** Receiver-only preview with optional consent-gated input over direct reliable transport. */
internal object FossProductPolicy {
    private const val LEGACY_MIRROR_CAPABILITY = 1L shl 9

    val authorizedCapabilityBits: Long =
        CapabilityNegotiation.BASELINE_RECEIVER_CAPABILITIES or LEGACY_MIRROR_CAPABILITY

    val intentProfileV2: ProductCapabilityProfileV2 = checkNotNull(
        ProductCapabilityProfileV2.create(
            localRoleBits = IntentV2Bits.ROLE_SINK,
            sourceTopologyBits = IntentV2Bits.SOURCE_EXTEND or IntentV2Bits.SOURCE_MIRROR,
            sinkPresentationBits = IntentV2Bits.SINK_WINDOWED or IntentV2Bits.SINK_FULLSCREEN,
            inputPolicyBits = IntentV2Bits.INPUT_REMOTE_CONTROL,
            transportPreferenceBits = IntentV2Bits.TRANSPORT_RELIABLE,
            topologyBits = IntentV2Bits.TOPOLOGY_DIRECT,
        ),
    )
}
