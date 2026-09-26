package com.superconnect.receiver

internal object CapabilityNative {
    external fun nativeAbiVersion(): Int
    external fun nativeNew(generation: Long, authorizedCapabilities: Long, projection: Int): Long
    external fun nativeApply(
        handle: Long,
        type: Int,
        generation: Long,
        capabilities: Long,
        version: Int,
        hasVersion: Boolean,
        offererRole: Int,
        selectorRole: Int,
        projection: Int,
        transport: Int,
    ): LongArray
    external fun nativeFree(handle: Long)
    private external fun nativeEncodeWire(record: LongArray): ByteArray?
    private external fun nativeDecodeWire(source: ByteArray): LongArray?

    fun encodeWire(value: CapabilityMessage): ByteArray? = nativeEncodeWire(longArrayOf(
        value.kind.nativeValue.toLong(), value.generation, value.capabilities, value.version.toLong(),
        value.offererRole.toLong(), value.selectorRole.toLong(), value.projection.nativeValue.toLong(),
        CapabilityNegotiation.TRANSPORT_TCP.toLong(),
    ))

    fun decodeWire(source: ByteArray): CapabilityMessage? {
        val value = nativeDecodeWire(source)?.takeIf { it.size == 8 } ?: return null
        return CapabilityMessage(
            CapabilityMessageKind.fromNative(value[0].toInt()) ?: return null,
            value[1], value[3].toInt(), value[2], value[4].toInt(), value[5].toInt(),
            CapabilityProjection.fromNative(value[6].toInt()) ?: return null,
        )
    }

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1) { "Rust capability ABI version mismatch" }
    }
}
