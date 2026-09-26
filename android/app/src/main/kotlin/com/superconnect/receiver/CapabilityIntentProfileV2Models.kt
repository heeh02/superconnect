package com.superconnect.receiver

internal data class CapabilityIntentProfileV2Axes(
    val localRoleBits: Long,
    val sourceTopologyBits: Long,
    val sinkPresentationBits: Long,
    val inputPolicyBits: Long,
    val transportPreferenceBits: Long,
    val topologyBits: Long,
) {
    val capabilityBits: Long
        get() = localRoleBits or sourceTopologyBits or sinkPresentationBits or inputPolicyBits or
            transportPreferenceBits or topologyBits
}

/** A local product-composition fact. Only this type is accepted by the sender encoder. */
class ProductCapabilityProfileV2 private constructor(
    internal val axes: CapabilityIntentProfileV2Axes,
) {
    companion object {
        fun create(
            localRoleBits: Long,
            sourceTopologyBits: Long,
            sinkPresentationBits: Long,
            inputPolicyBits: Long,
            transportPreferenceBits: Long,
            topologyBits: Long,
        ): ProductCapabilityProfileV2? = CapabilityIntentProfileV2Axes(
            localRoleBits,
            sourceTopologyBits,
            sinkPresentationBits,
            inputPolicyBits,
            transportPreferenceBits,
            topologyBits,
        ).takeIf(CapabilityIntentProfileV2AxisContract::valid)?.let(::ProductCapabilityProfileV2)

        /** Fail-closed receiver baseline. The free composition also injects an explicit profile. */
        fun baselineReceiver(): ProductCapabilityProfileV2 = create(
            localRoleBits = IntentV2Bits.ROLE_SINK,
            sourceTopologyBits = IntentV2Bits.SOURCE_EXTEND or IntentV2Bits.SOURCE_MIRROR,
            sinkPresentationBits = IntentV2Bits.SINK_WINDOWED or IntentV2Bits.SINK_FULLSCREEN,
            inputPolicyBits = IntentV2Bits.INPUT_VIEW_ONLY,
            transportPreferenceBits = IntentV2Bits.TRANSPORT_RELIABLE,
            topologyBits = IntentV2Bits.TOPOLOGY_DIRECT,
        ) ?: error("invalid receiver baseline capability intent profile")
    }
}

/** An immutable remote fact. It cannot be passed to the sender encoder as a product grant. */
internal class PeerCapabilityProfileV2 private constructor(
    internal val axes: CapabilityIntentProfileV2Axes,
) {
    val capabilityBits: Long get() = axes.capabilityBits

    companion object {
        internal fun project(axes: CapabilityIntentProfileV2Axes): PeerCapabilityProfileV2? =
            axes.takeIf(CapabilityIntentProfileV2AxisContract::valid)?.let(::PeerCapabilityProfileV2)
    }
}

internal data class CapabilityIntentProfileV2ProductAdvertisement(
    val generation: Long,
    val schemaVersion: Int,
    val senderRole: IntentV2Role,
    val productProfile: ProductCapabilityProfileV2,
)

internal data class CapabilityIntentProfileV2PeerAdvertisement(
    val generation: Long,
    val schemaVersion: Int,
    val senderRole: IntentV2Role,
    val peerProfile: PeerCapabilityProfileV2,
)

internal object CapabilityIntentProfileV2AxisContract {
    private const val ROLE_MASK = 0x7L
    private const val SOURCE_MASK = 0xf00L
    private const val SINK_MASK = 0x70000L
    private const val INPUT_MASK = 0x7000000L
    private const val TRANSPORT_MASK = 0x700000000L
    private const val TOPOLOGY_MASK = 0x70000000000L

    /** The sole split point from the canonical combined mask into Android axis values. */
    fun project(capabilities: Long): CapabilityIntentProfileV2Axes? {
        val axes = CapabilityIntentProfileV2Axes(
            localRoleBits = capabilities and ROLE_MASK,
            sourceTopologyBits = capabilities and SOURCE_MASK,
            sinkPresentationBits = capabilities and SINK_MASK,
            inputPolicyBits = capabilities and INPUT_MASK,
            transportPreferenceBits = capabilities and TRANSPORT_MASK,
            topologyBits = capabilities and TOPOLOGY_MASK,
        )
        return axes.takeIf { it.capabilityBits == capabilities && valid(it) }
    }

    fun valid(axes: CapabilityIntentProfileV2Axes): Boolean =
        validAxis(axes.localRoleBits, ROLE_MASK) &&
            validAxis(axes.sourceTopologyBits, SOURCE_MASK) &&
            validAxis(axes.sinkPresentationBits, SINK_MASK) &&
            validAxis(axes.inputPolicyBits, INPUT_MASK) &&
            validAxis(axes.transportPreferenceBits, TRANSPORT_MASK) &&
            validAxis(axes.topologyBits, TOPOLOGY_MASK)

    fun supportsRole(axes: CapabilityIntentProfileV2Axes, role: IntentV2Role): Boolean =
        axes.localRoleBits and (1L shl (role.nativeValue - 1)) != 0L

    private fun validAxis(value: Long, mask: Long): Boolean = value != 0L && value and mask == value
}
