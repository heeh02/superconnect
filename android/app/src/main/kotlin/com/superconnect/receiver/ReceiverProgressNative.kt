package com.superconnect.receiver

/** JNI boundary for the portable Rust video/control codecs. */
internal object ReceiverProgressNative {
    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
        check(nativeAbiVersion() == 1) { "unsupported Superconnect receiver progress ABI" }
    }

    external fun nativeAbiVersion(): Int
    external fun nativeEncodeWire(record: LongArray): ByteArray?
    external fun nativeDecodeWire(source: ByteArray): LongArray?
    external fun nativeEncodeKeyframeRequest(reason: Int): ByteArray?
    external fun nativeDecodeKeyframeRequest(source: ByteArray): Int
    external fun nativeEncodeVideoConfig(record: IntArray): ByteArray?
    external fun nativeDecodeVideoConfig(source: ByteArray): IntArray?
}
