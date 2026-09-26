package com.superconnect.receiver

/** MotionEvent facts enter the canonical Rust input encoder, then the active SC-RECORD writer. */
internal object PointerInputNative {
    external fun encodeKey(type: Int, keyCode: Int, flags: Int, timestamp: Long): ByteArray?
    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
    }
    external fun encode(type: Int, tool: Int, buttons: Int, timestamp: Long,
                        x: Float, y: Float, pressure: Float, tiltX: Float, tiltY: Float): ByteArray?
}
