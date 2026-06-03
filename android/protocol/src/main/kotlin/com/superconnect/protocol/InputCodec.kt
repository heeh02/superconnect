package com.superconnect.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Input event codec — Android/Kotlin mirror of mac SuperconnectCore/InputCodec.swift. Fixed-size
 * 44-byte little-endian record so every platform encodes it identically. On Android the receiver
 * captures MotionEvent/KeyEvent → InputEvent → FrameCodec(INPUT) → Mac. Pure Kotlin (no Android deps).
 *
 * Layout (LE): type:u8 tool:u8 buttons:u8 flags:u8 | timestampMs:u64 | x:f32 y:f32 pressure:f32 |
 *              tiltX:f32 tiltY:f32 | scrollX:f32 scrollY:f32 | keyCode:u16 pointerId:u16
 */

enum class InputType(val value: Int) {
    TOUCH_DOWN(0), TOUCH_MOVE(1), TOUCH_UP(2), HOVER(3), KEY_DOWN(4), KEY_UP(5), SCROLL(6), ZOOM(7)
}

enum class InputTool(val value: Int) { FINGER(0), PEN(1), ERASER(2), MOUSE(3) }

object InputButtons { const val PRIMARY = 0x01; const val SECONDARY = 0x02 }

/** Keyboard modifiers carried in the `flags` byte for key events. The tablet reports which physical
 *  modifiers are held; the Mac maps their MEANING (e.g. tablet Ctrl → macOS Cmd). */
object InputFlags { const val SHIFT = 0x01; const val CONTROL = 0x02; const val ALT = 0x04; const val META = 0x08 }

data class InputEvent(
    val type: Int,
    val tool: Int = InputTool.FINGER.value,
    val buttons: Int = 0,
    val flags: Int = 0,
    val timestampMs: Long = 0,
    val x: Float = 0f,
    val y: Float = 0f,
    val pressure: Float = 0f,
    val tiltX: Float = 0f,
    val tiltY: Float = 0f,
    val scrollX: Float = 0f,
    val scrollY: Float = 0f,
    val keyCode: Int = 0,
    val pointerId: Int = 0,
)

object InputCodec {
    const val RECORD_SIZE = 44

    fun encode(e: InputEvent): ByteArray {
        val b = ByteBuffer.allocate(RECORD_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        b.put(e.type.toByte()); b.put(e.tool.toByte()); b.put(e.buttons.toByte()); b.put(e.flags.toByte())
        b.putLong(e.timestampMs)
        b.putFloat(e.x); b.putFloat(e.y); b.putFloat(e.pressure)
        b.putFloat(e.tiltX); b.putFloat(e.tiltY)
        b.putFloat(e.scrollX); b.putFloat(e.scrollY)
        b.putShort(e.keyCode.toShort()); b.putShort(e.pointerId.toShort())
        return b.array()
    }

    fun decode(data: ByteArray): InputEvent? {
        if (data.size < RECORD_SIZE) return null
        val b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        return InputEvent(
            type = b.get().toInt() and 0xff,
            tool = b.get().toInt() and 0xff,
            buttons = b.get().toInt() and 0xff,
            flags = b.get().toInt() and 0xff,
            timestampMs = b.long,
            x = b.float, y = b.float, pressure = b.float,
            tiltX = b.float, tiltY = b.float,
            scrollX = b.float, scrollY = b.float,
            keyCode = b.short.toInt() and 0xffff,
            pointerId = b.short.toInt() and 0xffff,
        )
    }
}
