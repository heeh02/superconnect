package com.superconnect.receiver

internal enum class CapabilityProjection(val wire: String, val nativeValue: Int) {
    Extend("extend", 1), Mirror("mirror", 2), Primary("primary", 3);

    companion object {
        fun fromWire(value: String): CapabilityProjection? = entries.firstOrNull { it.wire == value }
        fun fromNative(value: Int): CapabilityProjection? = entries.firstOrNull { it.nativeValue == value }
    }
}

internal enum class CapabilityMessageKind(val wire: String, val nativeValue: Int) {
    Offer("offer", 2), Selection("selection", 3), Commit("commit", 4);

    companion object {
        fun fromWire(value: String): CapabilityMessageKind? = entries.firstOrNull { it.wire == value }
        fun fromNative(value: Int): CapabilityMessageKind? = entries.firstOrNull { it.nativeValue == value }
    }
}

internal data class CapabilityMessage(
    val kind: CapabilityMessageKind,
    val generation: Long,
    val version: Int,
    val capabilities: Long,
    val offererRole: Int,
    val selectorRole: Int,
    val projection: CapabilityProjection,
)

internal data class CapabilityBinding(
    val localRole: Int,
    val peerRole: Int,
    val projection: CapabilityProjection,
    val negotiated: Boolean,
)

internal sealed class CapabilityEffect {
    data class Send(val message: CapabilityMessage) : CapabilityEffect()
    data class Committed(val binding: CapabilityBinding) : CapabilityEffect()
    data class Connected(val binding: CapabilityBinding) : CapabilityEffect()
    data class Rejected(val reason: Int) : CapabilityEffect()
    data class Fatal(val reason: Int) : CapabilityEffect()
}

/** Single-owner adapter. Product bits are injected; Rust alone advances negotiation state. */
internal class CapabilityNegotiation(
    val generation: Long,
    authorizedCapabilities: Long,
    projection: CapabilityProjection,
) : AutoCloseable {
    private var handle = CapabilityNative.nativeNew(generation, authorizedCapabilities, projection.nativeValue)

    init { check(handle != 0L) { "Rust capability handle was not created" } }

    @Synchronized
    fun peerHello(version: Int?): List<CapabilityEffect> {
        val effects = apply(
            type = EVENT_PEER_HELLO, generation = generation, capabilities = 0,
            version = version ?: 0, hasVersion = version != null,
            offererRole = 0, selectorRole = 0, projection = 0, transport = 0,
        )
        return effects
    }

    @Synchronized
    fun message(value: CapabilityMessage): List<CapabilityEffect> {
        val effects = apply(
            type = value.kind.nativeValue, generation = value.generation,
            capabilities = value.capabilities, version = value.version, hasVersion = true,
            offererRole = value.offererRole, selectorRole = value.selectorRole,
            projection = value.projection.nativeValue, transport = TRANSPORT_TCP,
        )
        return effects
    }

    private fun apply(
        type: Int, generation: Long, capabilities: Long, version: Int, hasVersion: Boolean,
        offererRole: Int, selectorRole: Int, projection: Int, transport: Int,
    ): List<CapabilityEffect> {
        check(handle != 0L) { "capability handle is closed" }
        val raw = CapabilityNative.nativeApply(
            handle, type, generation, capabilities, version, hasVersion,
            offererRole, selectorRole, projection, transport,
        )
        check(raw.size == 1 + MAX_EFFECTS * EFFECT_FIELDS && raw[0] in 0..MAX_EFFECTS.toLong()) {
            "invalid Rust capability effect record"
        }
        return (0 until raw[0].toInt()).map { index ->
            val offset = 1 + index * EFFECT_FIELDS
            decode(raw, offset)
        }
    }

    private fun decode(raw: LongArray, offset: Int): CapabilityEffect {
        val type = raw[offset].toInt()
        if (type in EFFECT_SEND_OFFER..EFFECT_SEND_COMMIT) {
            val kind = when (type) {
                EFFECT_SEND_OFFER -> CapabilityMessageKind.Offer
                EFFECT_SEND_SELECTION -> CapabilityMessageKind.Selection
                else -> CapabilityMessageKind.Commit
            }
            check(raw[offset + 5].toInt() == ROLE_HOST &&
                raw[offset + 6].toInt() == ROLE_RECEIVER &&
                raw[offset + 10].toInt() == TRANSPORT_TCP &&
                raw[offset + 11] == 0L) { "invalid Rust capability message binding" }
            return CapabilityEffect.Send(CapabilityMessage(
                kind, raw[offset + 2], raw[offset + 4].toInt(), raw[offset + 3],
                raw[offset + 5].toInt(), raw[offset + 6].toInt(),
                CapabilityProjection.fromNative(raw[offset + 9].toInt())
                    ?: error("invalid Rust capability projection"),
            ))
        }
        if (type == EFFECT_COMMITTED || type == EFFECT_CONNECTED) {
            check(raw[offset + 7].toInt() == ROLE_RECEIVER &&
                raw[offset + 8].toInt() == ROLE_HOST &&
                raw[offset + 10].toInt() == TRANSPORT_TCP &&
                raw[offset + 11] in 0L..1L) { "invalid Rust capability binding" }
            val binding = CapabilityBinding(
                raw[offset + 7].toInt(), raw[offset + 8].toInt(),
                CapabilityProjection.fromNative(raw[offset + 9].toInt())
                    ?: error("invalid Rust binding projection"),
                raw[offset + 11] == 1L,
            )
            return if (type == EFFECT_COMMITTED) CapabilityEffect.Committed(binding)
            else CapabilityEffect.Connected(binding)
        }
        return when (type) {
            EFFECT_REJECTED -> CapabilityEffect.Rejected(raw[offset + 1].toInt())
            EFFECT_FATAL -> CapabilityEffect.Fatal(raw[offset + 1].toInt())
            else -> error("invalid Rust capability effect")
        }
    }

    @Synchronized
    override fun close() {
        if (handle == 0L) return
        val owned = handle
        handle = 0
        CapabilityNative.nativeFree(owned)
    }

    companion object {
        const val ROLE_HOST = 1
        const val ROLE_RECEIVER = 2
        const val TRANSPORT_TCP = 1
        const val BASELINE_RECEIVER_CAPABILITIES =
            (1L shl 1) or (1L shl 8) or (1L shl 16)
        private const val EVENT_PEER_HELLO = 1
        private const val EFFECT_SEND_OFFER = 1
        private const val EFFECT_SEND_SELECTION = 2
        private const val EFFECT_SEND_COMMIT = 3
        private const val EFFECT_COMMITTED = 4
        private const val EFFECT_CONNECTED = 5
        private const val EFFECT_REJECTED = 6
        private const val EFFECT_FATAL = 7
        private const val MAX_EFFECTS = 3
        private const val EFFECT_FIELDS = 12
    }
}
