import CoreGraphics

/// Maps HarmonyOS key codes (`@ohos.multimodalInput.keyCode`) to macOS virtual key
/// codes (`CGKeyCode`, the layout-independent positional codes from Carbon's Events.h).
///
/// The tablet sends raw HarmonyOS key codes; this single table — unit-testable, one
/// place — owns the translation. Returns nil for unmapped keys (the injector then
/// ignores them; printable characters arrive via the committed-text path instead, so
/// only named/shortcut keys ever need this map). Modifier keys are intentionally absent:
/// we never inject the modifier key itself, it only sets the `flags` bitmask.
public enum KeyMap {
    public static func mac(_ hm: UInt16) -> CGKeyCode? {
        switch hm {
        // Letters A..Z (HarmonyOS 2017..2042)
        case 2017: return 0;  case 2018: return 11; case 2019: return 8;  case 2020: return 2
        case 2021: return 14; case 2022: return 3;  case 2023: return 5;  case 2024: return 4
        case 2025: return 34; case 2026: return 38; case 2027: return 40; case 2028: return 37
        case 2029: return 46; case 2030: return 45; case 2031: return 31; case 2032: return 35
        case 2033: return 12; case 2034: return 15; case 2035: return 1;  case 2036: return 17
        case 2037: return 32; case 2038: return 9;  case 2039: return 13; case 2040: return 7
        case 2041: return 16; case 2042: return 6
        // Digits 0..9 (HarmonyOS 2000..2009), top row
        case 2000: return 29; case 2001: return 18; case 2002: return 19; case 2003: return 20
        case 2004: return 21; case 2005: return 23; case 2006: return 22; case 2007: return 26
        case 2008: return 28; case 2009: return 25
        // Arrows (HarmonyOS 2012..2015: UP/DOWN/LEFT/RIGHT)
        case 2012: return 126; case 2013: return 125; case 2014: return 123; case 2015: return 124
        // Whitespace / editing
        case 2050: return 49   // SPACE → kVK_Space
        case 2054: return 36   // ENTER → kVK_Return
        case 2049: return 48   // TAB   → kVK_Tab
        case 2055: return 51   // DEL (Backspace) → kVK_Delete
        case 2071: return 117  // FORWARD_DEL → kVK_ForwardDelete
        case 2070: return 53   // ESCAPE → kVK_Escape
        // Navigation
        case 2081: return 115  // MOVE_HOME → kVK_Home
        case 2082: return 119  // MOVE_END  → kVK_End
        case 2068: return 116  // PAGE_UP   → kVK_PageUp
        case 2069: return 121  // PAGE_DOWN → kVK_PageDown
        case 2083: return 114  // INSERT    → kVK_Help/Insert
        // Punctuation
        case 2043: return 43   // ,
        case 2044: return 47   // .
        case 2056: return 50   // `
        case 2057: return 27   // -
        case 2058: return 24   // =
        case 2059: return 33   // [
        case 2060: return 30   // ]
        case 2061: return 42   // \
        case 2062: return 41   // ;
        case 2063: return 39   // '
        case 2064: return 44   // /
        // Function keys F1..F12 (HarmonyOS 2090..2101)
        case 2090: return 122; case 2091: return 120; case 2092: return 99;  case 2093: return 118
        case 2094: return 96;  case 2095: return 97;  case 2096: return 98;  case 2097: return 100
        case 2098: return 101; case 2099: return 109; case 2100: return 103; case 2101: return 111
        // ⊙ (Meta/Super) key → macOS Option, injected as the real Option modifier key
        // (so it works standalone / double-tap, not only as a flag on other keys).
        case 2076: return 58   // KEYCODE_META_LEFT  → kVK_Option
        case 2077: return 61   // KEYCODE_META_RIGHT → kVK_RightOption
        case 2074: return 57   // KEYCODE_CAPS_LOCK  → kVK_CapsLock
        default: return nil
        }
    }
}
