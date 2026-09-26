package com.superconnect.receiver

internal object SessionNative {
    external fun nativeAbiVersion(): Int
    external fun nativeSecureAbiVersion(): Int
    external fun nativeCoreAbiIdentity(): Long
    external fun nativeNew(
        generation: Long,
        firstOperation: Long,
        localEnrollmentKey: Long,
        origin: Int,
        side: Int,
        mediaRole: Int,
        localIdentity: ByteArray,
    ): Long
    external fun nativeApply(
        handle: Long,
        type: Int,
        credentialState: Int,
        generation: Long,
        operation: Long,
        first: Long,
        second: Long,
        third: Long,
        authVersion: Int,
        flag: Boolean,
        identity: ByteArray?,
    ): LongArray
    external fun nativeSnapshot(handle: Long): LongArray
    external fun nativeObserveRecordVersion(handle: Long, version: Int): LongArray
    external fun nativeRecordMaterialPrepared(
        handle: Long,
        operation: Long,
        pairSecret: ByteArray?,
        responderChallenge: ByteArray?,
        initiatorChallenge: ByteArray?,
    ): LongArray
    external fun nativeRecordsActivated(handle: Long, operation: Long, success: Boolean): LongArray
    external fun nativeDrainEffects(handle: Long): LongArray
    external fun nativeSealFrame(handle: Long, channel: Int, flags: Int, payload: ByteArray): ByteArray
    external fun nativePush(handle: Long, bytes: ByteArray): ByteArray
    external fun nativeFree(handle: Long)

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1 && nativeSecureAbiVersion() == 1 &&
            nativeCoreAbiIdentity() == ANDROID_FOSS_ABI_ID) {
            "Rust secure session ABI version mismatch"
        }
    }

    private const val ANDROID_FOSS_ABI_ID = 0x0a1945305a446457L
}
