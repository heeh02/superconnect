package com.superconnect.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Executes the production JNI encoder, not a Kotlin copy of the wire format. */
fun main() {
    val pen = checkNotNull(PointerInputNative.encode(0, 1, 1, 1234, 0.25f, 0.75f, 0.6f, 12f, -8f))
    check(pen.size == 44)
    val view = ByteBuffer.wrap(pen).order(ByteOrder.LITTLE_ENDIAN)
    check(view.get(0).toInt() == 0 && view.get(1).toInt() == 1)
    check(view.getLong(4) == 1234L)
    check(view.getFloat(12) == 0.25f && view.getFloat(16) == 0.75f)
    check(view.getFloat(20) == 0.6f && view.getFloat(24) == 12f && view.getFloat(28) == -8f)
    for (type in listOf(4, 5)) {
        val key = checkNotNull(PointerInputNative.encodeKey(type, 2017, 6, 4321))
        val keys = ByteBuffer.wrap(key).order(ByteOrder.LITTLE_ENDIAN)
        check(keys.get(0).toInt() == type && keys.get(3).toInt() == 6)
        check(keys.getShort(40).toInt() == 2017)
        key.fill(0)
    }
    pen.fill(0)
    println("production pointer/pen/key JNI encoding: PASS")
}
