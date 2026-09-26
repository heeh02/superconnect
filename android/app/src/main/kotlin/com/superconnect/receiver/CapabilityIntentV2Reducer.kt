package com.superconnect.receiver

internal data class CapabilityIntentV2Config(
    val generation: Long,
    val productCapabilities: Long,
    val peerCapabilities: Long,
    val side: Int,
    val desiredPeerRole: IntentV2Role,
    val resolved: IntentV2Resolved,
)

internal data class CapabilityIntentV2Event(
    val type: Int,
    val generation: Long,
    val version: Int,
    val hasVersion: Boolean,
    val offererRole: IntentV2Role? = null,
    val selectorRole: IntentV2Role? = null,
    val projection: IntentV2SourceTopology? = null,
    val transport: IntentV2Transport? = null,
    val resolved: IntentV2Resolved? = null,
)

/** Single-owner pull adapter. It returns copied effects and cannot execute platform work. */
internal class CapabilityIntentV2Reducer(
    private val config: CapabilityIntentV2Config,
    private val freeHandle: (Long) -> Unit = CapabilityIntentV2Native::nativeFree,
) : AutoCloseable {
    private var handle = CapabilityIntentV2Native.nativeNew(
        config.generation, config.productCapabilities, config.peerCapabilities, config.side,
        config.desiredPeerRole.nativeValue, config.resolved.localRole.nativeValue,
        config.resolved.sourceTopology.nativeValue, config.resolved.sinkPresentation.nativeValue,
        config.resolved.inputPolicy.nativeValue, config.resolved.transport.nativeValue,
        config.resolved.topology.nativeValue,
    )

    init { check(handle != 0L) { "Rust capability intent v2 handle was not created" } }

    @Synchronized
    fun apply(event: CapabilityIntentV2Event): List<CapabilityIntentV2Effect> {
        check(handle != 0L) { "capability intent v2 handle is closed" }
        val intent = event.resolved
        val raw = CapabilityIntentV2Native.nativeApply(
            handle, event.type, event.generation, event.version, event.hasVersion,
            event.offererRole?.nativeValue ?: 0, event.selectorRole?.nativeValue ?: 0,
            event.projection?.nativeValue ?: 0, event.transport?.nativeValue ?: 0,
            intent?.localRole?.nativeValue ?: 0, intent?.sourceTopology?.nativeValue ?: 0,
            intent?.sinkPresentation?.nativeValue ?: 0, intent?.inputPolicy?.nativeValue ?: 0,
            intent?.transport?.nativeValue ?: 0, intent?.topology?.nativeValue ?: 0,
        )
        check(raw.size == 1 + MAX_EFFECTS * EFFECT_FIELDS && raw[0] in 0..MAX_EFFECTS.toLong()) {
            "invalid Rust capability intent v2 effect record"
        }
        return (0 until raw[0].toInt()).map { decodeEffect(raw, 1 + it * EFFECT_FIELDS) }
    }

    @Synchronized
    fun snapshot(): CapabilityIntentV2Snapshot {
        check(handle != 0L) { "capability intent v2 handle is closed" }
        val raw = CapabilityIntentV2Native.nativeSnapshot(handle)
        check(raw.size == SNAPSHOT_FIELDS && raw[5] in 0L..1L && raw[6] in 0L..1L) {
            "invalid Rust capability intent v2 snapshot"
        }
        val resolved = decodeResolved(raw, 7)
        val binding = if (raw[5] == 1L) {
            CapabilityIntentV2Binding(
                decodeResolved(raw, 13), role(raw[19]), raw[6] == 1L,
            )
        } else {
            check(raw.sliceArray(13..19).all { it == 0L } && raw[6] == 0L) {
                "unbound Rust capability intent v2 snapshot carried binding fields"
            }
            null
        }
        return CapabilityIntentV2Snapshot(
            raw[0], raw[1], raw[2], exactInt(raw[3]), role(raw[4]), resolved, binding,
        )
    }

    @Synchronized
    override fun close() {
        if (handle == 0L) return
        val owned = handle
        freeHandle(owned)
        handle = 0
    }

    private fun decodeEffect(raw: LongArray, offset: Int): CapabilityIntentV2Effect {
        val kind = CapabilityIntentV2EffectKind.decode(raw[offset])
            ?: error("invalid Rust capability intent v2 effect kind")
        check(raw[offset + 14] in 0L..1L) { "invalid Rust capability intent v2 negotiated flag" }
        val resolved = nullableResolved(raw, offset + 15)
        val value = CapabilityIntentV2Effect(
            kind, reason(kind, exactInt(raw[offset + 1])), raw[offset + 2], raw[offset + 3],
            raw[offset + 4], exactInt(raw[offset + 5]), exactInt(raw[offset + 6]),
            exactInt(raw[offset + 7]), nullableRole(raw[offset + 8]),
            nullableRole(raw[offset + 9]), nullableRole(raw[offset + 10]),
            nullableRole(raw[offset + 11]), nullableSource(raw[offset + 12]),
            nullableTransport(raw[offset + 13]), raw[offset + 14] == 1L, resolved,
            nullableRole(raw[offset + 21]), nullableRole(raw[offset + 22]),
            nullableSource(raw[offset + 23]), nullableSource(raw[offset + 24]),
            nullableTransport(raw[offset + 25]), nullableTransport(raw[offset + 26]),
        )
        when (kind) {
            CapabilityIntentV2EffectKind.SendOffer,
            CapabilityIntentV2EffectKind.SendSelection,
            CapabilityIntentV2EffectKind.SendCommit -> check(
                value.offererRole != null && value.selectorRole != null &&
                    value.projection != null && value.transport != null && value.resolved != null &&
                    value.localRole == null && value.peerRole == null && !value.negotiated,
            ) { "invalid Rust capability intent v2 message effect" }
            CapabilityIntentV2EffectKind.Committed,
            CapabilityIntentV2EffectKind.Connected -> check(
                value.localRole != null && value.peerRole != null && value.projection != null &&
                    value.transport != null && value.resolved != null &&
                    value.offererRole == null && value.selectorRole == null,
            ) { "invalid Rust capability intent v2 binding effect" }
            CapabilityIntentV2EffectKind.Rejected,
            CapabilityIntentV2EffectKind.Fatal -> check(
                value.reason != null && value.offererRole == null && value.selectorRole == null &&
                    value.localRole == null && value.peerRole == null && value.resolved == null,
            ) { "invalid Rust capability intent v2 diagnostic effect" }
        }
        return value
    }

    private fun reason(kind: CapabilityIntentV2EffectKind, value: Int): CapabilityIntentSemanticReason? {
        if (kind != CapabilityIntentV2EffectKind.Rejected &&
            kind != CapabilityIntentV2EffectKind.Fatal) {
            check(value == 0) { "non-diagnostic Rust capability intent v2 effect carried reason" }
            return null
        }
        return when (value) {
            1 -> CapabilityIntentSemanticReason.OutOfOrder
            2 -> CapabilityIntentSemanticReason.StaleGeneration
            3 -> CapabilityIntentSemanticReason.UnsupportedVersion
            4 -> CapabilityIntentSemanticReason.RoleMismatch
            5 -> CapabilityIntentSemanticReason.ProjectionMismatch
            6 -> CapabilityIntentSemanticReason.TransportMismatch
            7 -> CapabilityIntentSemanticReason.IntentMismatch
            8 -> CapabilityIntentSemanticReason.CommitMismatch
            9 -> CapabilityIntentSemanticReason.LegacyIntentMismatch
            else -> error("invalid Rust capability intent v2 reason")
        }
    }

    private fun nullableResolved(raw: LongArray, offset: Int): IntentV2Resolved? =
        if ((offset until offset + 6).all { raw[it] == 0L }) null else decodeResolved(raw, offset)

    private fun decodeResolved(raw: LongArray, offset: Int) = IntentV2Resolved(
        role(raw[offset]), source(raw[offset + 1]), sink(raw[offset + 2]),
        input(raw[offset + 3]), transport(raw[offset + 4]), topology(raw[offset + 5]),
    )

    private fun nullableRole(value: Long) = if (value == 0L) null else role(value)
    private fun nullableSource(value: Long) = if (value == 0L) null else source(value)
    private fun nullableTransport(value: Long) = if (value == 0L) null else transport(value)
    private fun role(value: Long) = IntentV2Role.decode(value) ?: error("invalid Rust v2 role")
    private fun source(value: Long) = IntentV2SourceTopology.decode(value)
        ?: error("invalid Rust v2 source topology")
    private fun sink(value: Long) = IntentV2SinkPresentation.decode(value)
        ?: error("invalid Rust v2 sink presentation")
    private fun input(value: Long) = IntentV2InputPolicy.decode(value)
        ?: error("invalid Rust v2 input policy")
    private fun transport(value: Long) = IntentV2Transport.decode(value)
        ?: error("invalid Rust v2 transport")
    private fun topology(value: Long) = IntentV2Topology.decode(value)
        ?: error("invalid Rust v2 topology")
    private fun exactInt(value: Long): Int {
        check(value in 0..Int.MAX_VALUE.toLong()) { "Rust v2 integer does not fit Kotlin Int" }
        return value.toInt()
    }

    private companion object {
        const val MAX_EFFECTS = 3
        const val EFFECT_FIELDS = 27
        const val SNAPSHOT_FIELDS = 20
    }
}
