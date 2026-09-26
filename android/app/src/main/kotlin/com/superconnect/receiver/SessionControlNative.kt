package com.superconnect.receiver

internal object SessionControlNative {
    const val KIND_BYE = 1
    const val KIND_PING = 2
    const val KIND_PONG = 3
    const val FIELD_T0 = 1
    const val FIELD_T1 = 2
    const val FIELD_T2 = 4

    external fun nativeEncode(
        kind: Int, presence: Int, sequence: Long, t0: Long, t1: Long, t2: Long,
    ): ByteArray?
    external fun nativeDecode(source: ByteArray): LongArray?

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
    }
}
