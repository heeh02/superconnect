package com.superconnect.receiver

import android.view.KeyEvent
import com.superconnect.protocol.InputEvent
import com.superconnect.protocol.InputFlags
import com.superconnect.protocol.InputTool
import com.superconnect.protocol.InputType

/**
 * Physical + soft keyboard → Mac, Kotlin port of harmony `input/KeyboardHandler.ets`. Every physical key
 * is forwarded RAW (HarmonyOS keycode via [AndroidKeyMap] + a modifier-flags bitmask) so the Mac's own
 * input method composes (typing/delete/shortcuts unified). Caps Lock switches the Mac input source
 * (Control+Space, one per press); committed IME text + soft backspace come through [commitText]/[backspace]
 * (the CONTROL `{type:text}` path / a Backspace keystroke). All sends go through the [InputSender] seam.
 */
class KeyboardHandler(private val sender: InputSender) {

    private fun flagsOf(meta: Int): Int {
        var f = 0
        if (meta and KeyEvent.META_SHIFT_ON != 0) f = f or InputFlags.SHIFT
        if (meta and KeyEvent.META_CTRL_ON != 0) f = f or InputFlags.CONTROL
        if (meta and KeyEvent.META_ALT_ON != 0) f = f or InputFlags.ALT
        if (meta and KeyEvent.META_META_ON != 0) f = f or InputFlags.META
        return f
    }

    private fun sendKey(type: Int, harmonyCode: Int, flags: Int) {
        sender.send(InputEvent(type = type, tool = InputTool.FINGER.value, buttons = 0,
            flags = flags, keyCode = harmonyCode and 0xffff))
    }

    /**
     * Physical-key delegate (from Activity.dispatchKeyEvent). Returns true when CONSUMED (translated +
     * forwarded), false to let Android handle it (volume/back/home/unmapped — and bare modifiers, whose
     * effect rides in `flags` on the keys they modify).
     */
    fun onKeyEvent(e: KeyEvent): Boolean {
        // Caps Lock → one Control+Space per press (Mac input-source switch); never toggle local caps.
        if (e.keyCode == KeyEvent.KEYCODE_CAPS_LOCK) {
            if (e.action == KeyEvent.ACTION_DOWN && e.repeatCount == 0) {
                sendKey(InputType.KEY_DOWN.value, HM_SPACE, InputFlags.CONTROL)
                sendKey(InputType.KEY_UP.value, HM_SPACE, InputFlags.CONTROL)
            }
            return true
        }
        val hm = AndroidKeyMap.toHarmony(e.keyCode)
        if (hm == 0) return false   // unmapped → Android handles; modifiers ride in flags on other keys
        val type = if (e.action == KeyEvent.ACTION_UP) InputType.KEY_UP.value else InputType.KEY_DOWN.value
        sendKey(type, hm, flagsOf(e.metaState))   // auto-repeat KEY_DOWNs pass through (Mac handles them)
        return true
    }

    /** Soft-keyboard committed text (Unicode / CJK) → CONTROL `{type:text}` (Mac types it verbatim). */
    fun commitText(text: CharSequence) { if (text.isNotEmpty()) sender.sendText(text.toString()) }

    /** Soft-keyboard backspace → Mac Backspace keystroke(s). */
    fun backspace(count: Int) {
        repeat(count) {
            sendKey(InputType.KEY_DOWN.value, HM_DEL, 0)
            sendKey(InputType.KEY_UP.value, HM_DEL, 0)
        }
    }

    private companion object { const val HM_SPACE = 2050; const val HM_DEL = 2055 }
}
