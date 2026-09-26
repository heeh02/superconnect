package com.superconnect.receiver

/** Private JNI declarations for the portable Rust ScAdmission reducer ABI. */
internal object AdmissionNative {
    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1) { "unsupported Superconnect admission ABI" }
    }

    external fun nativeAbiVersion(): Int
    external fun nativeNew(maxPending: Int): Long
    external fun nativeApply(handle: Long, kind: Int, owner: Long, token: Long): LongArray
    external fun nativeSnapshot(handle: Long): LongArray
    external fun nativeFree(handle: Long)
}
