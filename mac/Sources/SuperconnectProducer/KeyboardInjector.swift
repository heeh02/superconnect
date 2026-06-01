import CoreGraphics
import SuperconnectCore

/// Keyboard injection: raw keys (shortcuts / named / navigation) via KeyMap, and committed Unicode
/// text (Chinese IME + any typed string). Self-contained — no shared mouse/click state, only `source`.
/// The MatePad NearLink modifier remap lives here: tablet Ctrl→Control, Alt→Command (Alt+C = copy),
/// ⊙(Meta)→Option, Shift→Shift; Fn stays local to the tablet. Logic verbatim from InputInjector.
final class KeyboardInjector {
    private let source: CGEventSource?

    init(source: CGEventSource?) { self.source = source }

    private func cgFlags(_ f: UInt8) -> CGEventFlags {
        let m = InputFlags(rawValue: f)
        var out: CGEventFlags = []
        if m.contains(.shift)   { out.insert(.maskShift) }
        if m.contains(.control) { out.insert(.maskControl) }
        if m.contains(.alt)     { out.insert(.maskCommand) }
        if m.contains(.meta)    { out.insert(.maskAlternate) }
        return out
    }

    // RAW key (shortcuts + named/navigation keys). keyCode = HarmonyOS code; modifiers
    // folded into `flags` on BOTH down and up so a dropped event can't stick a modifier.
    func injectKey(_ down: Bool, _ e: InputEvent) {
        guard let vk = KeyMap.mac(e.keyCode) else { return } // unmapped → ignore (text path covers printables)
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        ev.flags = cgFlags(e.flags)
        ev.post(tap: .cghidEventTap)
    }

    // COMMITTED text (Chinese IME + any typed Unicode), from CONTROL {"type":"text"}.
    // Types the string verbatim via the Unicode payload — no keycode, no modifiers.
    func injectText(_ s: String) {
        guard !s.isEmpty else { return }
        let utf16 = Array(s.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.flags = []; up.flags = [] // text must carry NO modifiers, else 'c' → Cmd+C
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
