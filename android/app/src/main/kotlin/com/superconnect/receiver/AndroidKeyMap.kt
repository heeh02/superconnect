package com.superconnect.receiver

import android.view.KeyEvent

/**
 * Android `KeyEvent.KEYCODE_*` → HarmonyOS keycode. **Load-bearing:** the Mac's `KeyMap.mac()` switches
 * on HARMONYOS codes (A=2017, SPACE=2050, DEL=2055, arrows 2012-15, F1-12 2090-2101, Meta 2076/77, …)
 * and returns nil for anything else — so an Android code (A=29, SPACE=62, DEL=67 …) forwarded raw would
 * be SILENTLY DROPPED. This table is the tablet-side translation, keeping the Mac the single mature
 * consumer (mirrors how HarmonyOS forwards its native codes).
 *
 * Modifier keys (shift/ctrl/alt) are intentionally absent → return 0: their effect rides in the `flags`
 * bitmask on the keys they modify, never as injected keys. Returns 0 for any unmapped key (the caller
 * then lets Android handle it — so volume/back/home keep working). Kept table-driven + tablet-side so
 * Android-specific keyboard quirks stay localized to this one file.
 */
object AndroidKeyMap {
    fun toHarmony(a: Int): Int = when (a) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 2017 + (a - KeyEvent.KEYCODE_A)   // A..Z  → 2017..2042
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> 2000 + (a - KeyEvent.KEYCODE_0)   // 0..9  → 2000..2009
        KeyEvent.KEYCODE_DPAD_UP -> 2012
        KeyEvent.KEYCODE_DPAD_DOWN -> 2013
        KeyEvent.KEYCODE_DPAD_LEFT -> 2014
        KeyEvent.KEYCODE_DPAD_RIGHT -> 2015
        KeyEvent.KEYCODE_SPACE -> 2050
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 2054
        KeyEvent.KEYCODE_TAB -> 2049
        KeyEvent.KEYCODE_DEL -> 2055            // Backspace
        KeyEvent.KEYCODE_FORWARD_DEL -> 2071
        KeyEvent.KEYCODE_ESCAPE -> 2070
        KeyEvent.KEYCODE_MOVE_HOME -> 2081
        KeyEvent.KEYCODE_MOVE_END -> 2082
        KeyEvent.KEYCODE_PAGE_UP -> 2068
        KeyEvent.KEYCODE_PAGE_DOWN -> 2069
        KeyEvent.KEYCODE_INSERT -> 2083
        KeyEvent.KEYCODE_COMMA -> 2043
        KeyEvent.KEYCODE_PERIOD -> 2044
        KeyEvent.KEYCODE_GRAVE -> 2056
        KeyEvent.KEYCODE_MINUS -> 2057
        KeyEvent.KEYCODE_EQUALS -> 2058
        KeyEvent.KEYCODE_LEFT_BRACKET -> 2059
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 2060
        KeyEvent.KEYCODE_BACKSLASH -> 2061
        KeyEvent.KEYCODE_SEMICOLON -> 2062
        KeyEvent.KEYCODE_APOSTROPHE -> 2063
        KeyEvent.KEYCODE_SLASH -> 2064
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> 2090 + (a - KeyEvent.KEYCODE_F1)  // F1..F12 → 2090..2101
        KeyEvent.KEYCODE_META_LEFT -> 2076     // ⊙ → Mac Option (injected, so it works standalone)
        KeyEvent.KEYCODE_META_RIGHT -> 2077
        else -> 0
    }
}
