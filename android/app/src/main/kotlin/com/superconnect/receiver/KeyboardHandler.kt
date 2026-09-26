package com.superconnect.receiver

import android.os.SystemClock
import android.view.KeyEvent

/** Public key mapping with Rust encoding; never writes a legacy plaintext frame. */
internal class KeyboardHandler(
    private val send: (ByteArray) -> Unit,
    private val sendText: (String) -> Unit,
    private val active: () -> Boolean,
) {
    private val held = mutableMapOf<Int, Int>()

    fun onKeyEvent(event: KeyEvent): Boolean {
        if (!active()) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        if (event.keyCode == KeyEvent.KEYCODE_CAPS_LOCK) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                key(4, 2050, 2); key(5, 2050, 2)
            }
            return true
        }
        val code = AndroidKeyMap.toHarmony(event.keyCode)
        if (code == 0) return false
        val flags = (if (event.isShiftPressed) 1 else 0) or
            (if (event.isCtrlPressed) 2 else 0) or
            (if (event.isAltPressed) 4 else 0) or
            (if (event.isMetaPressed) 8 else 0)
        if (event.action == KeyEvent.ACTION_UP) held.remove(code) else held[code] = flags
        key(if (event.action == KeyEvent.ACTION_UP) 5 else 4, code, flags)
        return true
    }

    fun commitText(text: CharSequence) { if (active() && text.isNotEmpty()) sendText(text.toString()) }
    fun backspace(count: Int) {
        if (active()) repeat(count) { key(4, 2055, 0); key(5, 2055, 0) }
    }
    fun release() {
        held.toMap().forEach { (code, flags) -> key(5, code, flags) }
        held.clear()
    }
    private fun key(type: Int, code: Int, flags: Int) {
        PointerInputNative.encodeKey(type, code, flags, SystemClock.uptimeMillis())?.let(send)
    }
}
