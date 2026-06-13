package com.superconnect.protocol

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Android (Kotlin) is the 4th cross-language conformance target: FrameCodec + InputCodec must encode
 * AND decode the golden vectors in proto/vectors.json byte-identically with Swift, C++, and ArkTS — so
 * the Android receiver can never silently diverge on the wire. Pure-JVM (no Android), runs off-device:
 *   ./gradlew :protocol:test
 */
class WireConformanceTest {

    private fun vectors(): JSONObject {
        // Walk up from the test's working dir to the repo root (which holds proto/vectors.json).
        var dir: File? = File(System.getProperty("user.dir"))
        while (dir != null && !File(dir, "proto/vectors.json").exists()) dir = dir.parentFile
        requireNotNull(dir) { "proto/vectors.json not found above ${System.getProperty("user.dir")}" }
        return JSONObject(File(dir, "proto/vectors.json").readText())
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = ByteArray(s.length / 2) {
        ((Character.digit(s[it * 2], 16) shl 4) or Character.digit(s[it * 2 + 1], 16)).toByte()
    }

    @Test fun frameHeaderSize() {
        assertEquals(vectors().getInt("frameHeaderSize"), FrameCodec.HEADER_SIZE)
    }

    @Test fun frameVectors() {
        val arr = vectors().getJSONArray("vectors")
        for (i in 0 until arr.length()) {
            val v = arr.getJSONObject(i)
            // encode → exact bytes
            val enc = FrameCodec.encode(v.getInt("channel"), v.getInt("flags"), unhex(v.getString("payloadHex")))
            assertEquals("frame encode ${v.getString("name")}", v.getString("frameHex"), hex(enc))
            // decode → the same triple
            val frames = FrameDecoder().push(unhex(v.getString("frameHex")))
            assertEquals("one frame ${v.getString("name")}", 1, frames.size)
            assertEquals(v.getInt("channel"), frames[0].channel)
            assertEquals(v.getInt("flags"), frames[0].flags)
            assertEquals(v.getString("payloadHex"), hex(frames[0].payload))
        }
    }

    @Test fun frameDecoderHandlesFragmentation() {
        // A frame delivered one byte at a time must reassemble.
        val full = unhex("0000020000006869")
        val dec = FrameDecoder()
        val collected = ArrayList<Frame>()
        for (byte in full) collected += dec.push(byteArrayOf(byte))
        assertEquals(1, collected.size)
        assertEquals(0, collected[0].channel)
        assertEquals("6869", hex(collected[0].payload))
    }

    @Test fun frameDecoderHandlesCoalescing() {
        // Two whole frames arriving in ONE push must both decode, in order (parity with Swift/C++).
        val two = unhex("0000020000006869" + "020104000000deadbeef")
        val frames = FrameDecoder().push(two)
        assertEquals(2, frames.size)
        assertEquals(0, frames[0].channel); assertEquals("6869", hex(frames[0].payload))
        assertEquals(2, frames[1].channel); assertEquals(1, frames[1].flags)
        assertEquals("deadbeef", hex(frames[1].payload))
    }

    @Test fun frameDecoderRejectsOversizeLength() {
        // The u32 length is UNSIGNED: a length above 16 MiB — including one with bit 31 set, which a signed
        // Int would read negative — must be rejected the same way as Swift/C++/ArkTS, not silently accepted.
        val b = 0xFF.toByte()
        // header = channel 00, flags 00, length (4 bytes, little-endian):
        val cases = mapOf(
            "16MiB+1 (0x01000001)" to byteArrayOf(0, 0, /*len*/ 0x01, 0x00, 0x00, 0x01),
            "0xFFFFFFFF (bit31 set)" to byteArrayOf(0, 0, /*len*/ b, b, b, b),
        )
        for ((name, header) in cases) {
            var threw = false
            try { FrameDecoder().push(header) } catch (_: IllegalStateException) { threw = true }
            assertEquals("oversize length $name must be rejected", true, threw)
        }
    }

    @Test fun inputRecordSize() {
        assertEquals(vectors().getInt("inputRecordSize"), InputCodec.RECORD_SIZE)
    }

    @Test fun inputVectors() {
        val arr = vectors().getJSONArray("inputVectors")
        for (i in 0 until arr.length()) {
            val v = arr.getJSONObject(i)
            val e = InputEvent(
                type = v.getInt("type"), tool = v.getInt("tool"), buttons = v.getInt("buttons"), flags = v.getInt("flags"),
                timestampMs = v.getLong("timestampMs"),
                x = v.getDouble("x").toFloat(), y = v.getDouble("y").toFloat(), pressure = v.getDouble("pressure").toFloat(),
                tiltX = v.getDouble("tiltX").toFloat(), tiltY = v.getDouble("tiltY").toFloat(),
                scrollX = v.getDouble("scrollX").toFloat(), scrollY = v.getDouble("scrollY").toFloat(),
                keyCode = v.getInt("keyCode"), pointerId = v.getInt("pointerId"),
            )
            assertEquals("input encode ${v.getString("name")}", v.getString("recordHex"), hex(InputCodec.encode(e)))
            assertEquals("input round-trip ${v.getString("name")}", e, InputCodec.decode(InputCodec.encode(e)))
        }
    }
}
