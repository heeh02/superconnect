import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import SuperconnectCore

/// Injects received InputEvents into macOS as CGEvents.
///
/// Pen and finger are deliberately separated (for a note-taking workflow):
///  • PEN  → draws: left-mouse down/drag/up tagged with the tablet-pointer
///    subtype + pressure/tilt (apps that read the tablet mouse subtype honor it;
///    a DriverKit virtual digitizer is the next step for pro apps).
///  • FINGER → iPad-trackpad-like; the tablet's GestureController decides intent
///    and tags events, so the Mac just obeys: 1 finger = left press/drag/click
///    (moves windows, selects), 2-finger tap = right click (buttons.secondary),
///    2-finger drag = scroll. Finger never draws.
///
/// Normalized [0,1] coordinates map into the virtual display's GLOBAL desktop
/// rectangle (CGDisplayBounds, top-left origin = CGEvent's space, no flip).
public final class InputInjector {
    private let displayID: CGDirectDisplayID
    private let boundsLock = NSLock()
    private var cachedBounds: CGRect          // refreshed only on display reconfiguration
    private let source: CGEventSource?
    private let pen: PenInjector            // pen pressure/tilt + proximity (self-contained)
    private let keyboard: KeyboardInjector  // raw keys + committed text (self-contained)

    // The finger button currently held. The tablet's GestureController owns all
    // tap / drag / right-click discrimination and sends buttons=0 on release; here
    // we just press/drag/release whatever button it tells us so Move maps to the
    // matching *Dragged and Up releases the correct button.
    private var heldButton: CGMouseButton? = nil

    // Click-count aggregation. The window server does NOT coalesce synthesized CGEvents into
    // double/triple clicks, so without this a double-tap arrives as two single clicks and
    // title-bar double-click-to-zoom, word/line select, etc. never fire. We count clicks
    // ourselves: a same-button down within the system double-click interval AND within
    // `clickSlop` of the previous one bumps the count (1→2→3); otherwise it resets to 1. The
    // count is stamped on the down / drag / up via .mouseEventClickState so macOS treats it as
    // a real multi-click. Shared by finger + trackpad (one cursor, one tool at a time).
    private var clickState: Int64 = 1
    private var lastDownTime: CFTimeInterval = 0
    private var lastDownPos: CGPoint = .zero
    private var lastDownButton: CGMouseButton? = nil
    private let clickSlop: CGFloat = 12   // global points; generous for finger taps
    private lazy var doubleClickInterval: CFTimeInterval = NSEvent.doubleClickInterval

    private func beginClick(_ button: CGMouseButton, at p: CGPoint) -> Int64 {
        let now = CFAbsoluteTimeGetCurrent()
        let near = hypot(p.x - lastDownPos.x, p.y - lastDownPos.y) <= clickSlop
        if button == lastDownButton, now - lastDownTime <= doubleClickInterval, near {
            clickState += 1
        } else {
            clickState = 1
        }
        lastDownTime = now; lastDownPos = p; lastDownButton = button
        return clickState
    }

    // Scroll: the tablet sends raw vp centroid deltas; scale to wheel pixels.
    private let scrollGain: CGFloat = 2.5 // TUNE on device
    // Magnify gesture: tablet sends a per-frame magnification ratio delta; scale it.
    private let magnifyGain: Double = 1.0 // TUNE on device

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.cachedBounds = CGDisplayBounds(displayID)
        self.source = CGEventSource(stateID: .combinedSessionState)
        self.pen = PenInjector(source: self.source)
        self.keyboard = KeyboardInjector(source: self.source)
        // Refresh the cached bounds ONLY when displays are reconfigured (monitor
        // plug/unplug, rearrange, resolution change) — not on every event.
        CGDisplayRegisterReconfigurationCallback(InputInjector.reconfigCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(InputInjector.reconfigCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    // Non-capturing C callback: recover the injector from userInfo and refresh bounds
    // on the post-change call (skip the "begin configuration" phase, bounds still stale).
    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<InputInjector>.fromOpaque(userInfo).takeUnretainedValue().refreshBounds()
    }

    private func refreshBounds() {
        let b = CGDisplayBounds(displayID)
        boundsLock.lock()
        let changed = (b != cachedBounds)
        cachedBounds = b
        boundsLock.unlock()
        if changed {
            print("[superconnect-mac] display bounds updated → origin=(\(Int(b.minX)),\(Int(b.minY))) size=\(Int(b.width))×\(Int(b.height))")
        }
    }

    // Re-read the display layout at most ~4x/sec WHILE input is flowing (negligible
    // cost, zero when idle). This catches a System-Settings rearrange promptly even if
    // the reconfiguration callback doesn't fire for this CLI process.
    private var lastBoundsRefresh: Double = 0
    private func maybeRefreshBounds() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBoundsRefresh < 0.25 { return }
        lastBoundsRefresh = now
        refreshBounds()
    }

    private func currentBounds() -> CGRect {
        boundsLock.lock(); defer { boundsLock.unlock() }; return cachedBounds
    }

    // MARK: - Accessibility (TCC) permission

    public static func hasAccessibilityPermission() -> Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Injection

    public func inject(_ e: InputEvent) {
        guard let type = InputType(rawValue: e.type) else { return }
        maybeRefreshBounds()
        let point = globalPoint(e)
        if type == .scroll { postScroll(dx: e.scrollX, dy: e.scrollY); return }
        if type == .zoom { postZoom(e); return }
        if type == .keyDown || type == .keyUp { keyboard.injectKey(type == .keyDown, e); return }
        let isPen = e.tool == InputTool.pen.rawValue || e.tool == InputTool.eraser.rawValue
        if e.tool == InputTool.mouse.rawValue { injectMouse(type, e); return }
        if isPen { pen.inject(type, point, e) } else { injectFinger(type, point, e) }
    }

    // FINGER: direct manipulation. The tablet already classified the gesture and
    // tagged the button (primary=left, secondary=right; 0 = release/no-button).
    // Down presses, Move drags with the held button, Up releases it.
    private func injectFinger(_ type: InputType, _ point: CGPoint, _ e: InputEvent) {
        let secondary = (e.buttons & InputButtons.secondary.rawValue) != 0
        let primary   = (e.buttons & InputButtons.primary.rawValue) != 0
        switch type {
        case .touchDown:
            if secondary { heldButton = .right; post(.rightMouseDown, point, .right, clickState: beginClick(.right, at: point)) }
            else if primary { heldButton = .left; post(.leftMouseDown, point, .left, clickState: beginClick(.left, at: point)) }
            else { post(.mouseMoved, point, .left) }       // buttons=0: cursor warp only
        case .touchMove:
            if heldButton == .right { post(.rightMouseDragged, point, .right, clickState: clickState) }
            else if heldButton == .left { post(.leftMouseDragged, point, .left, clickState: clickState) }
            else { post(.mouseMoved, point, .left) }
        case .hover:
            post(.mouseMoved, point, .left)                 // pending-window cursor tracking
        case .touchUp:
            if heldButton == .right { post(.rightMouseUp, point, .right, clickState: clickState) }
            else if heldButton == .left { post(.leftMouseUp, point, .left, clickState: clickState) }
            else { post(.mouseMoved, point, .left) }        // tracked-only finger lifting
            heldButton = nil
        default: break
        }
    }

    private func globalPoint(_ e: InputEvent) -> CGPoint {
        // Cached bounds, refreshed only on display reconfiguration (see reconfigCallback),
        // so a monitor plug/unplug can't leave touches mapping onto the wrong screen.
        let bounds = currentBounds()
        let nx = e.x.isFinite ? min(1, max(0, e.x)) : 0
        let ny = e.y.isFinite ? min(1, max(0, e.y)) : 0
        return CGPoint(x: bounds.minX + CGFloat(nx) * bounds.width,
                       y: bounds.minY + CGFloat(ny) * bounds.height)
    }

    private func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton, clickState: Int64 = 0) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) else { return }
        if clickState > 0 { ev.setIntegerValueField(.mouseEventClickState, value: clickState) }
        ev.post(tap: .cghidEventTap)
    }

    // The tablet sends raw vp centroid deltas (NOT normalized — avoids the HiDPI
    // points/pixels ambiguity). Scale by a single gain and negate for natural
    // scrolling (content follows the fingers).
    private func postScroll(dx: Float, dy: Float) {
        let gx = dx.isFinite ? CGFloat(dx) : 0
        let gy = dy.isFinite ? CGFloat(dy) : 0
        let wy = Int32(max(-100_000, min(100_000, (-gy * scrollGain).rounded())))
        let wx = Int32(max(-100_000, min(100_000, (-gx * scrollGain).rounded())))
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: wy, wheel2: wx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) // trackpad-like precise scroll
        event.post(tap: .cghidEventTap)
    }

    // ZOOM: synthesize a REAL trackpad magnify GESTURE (private CGEvent gesture type
    // 29 — the recipe WebKit's EventSenderProxy and Mac Mouse Fix use). This drives a
    // genuine NSEvent.magnify, so it zooms like the trackpad in ANY app (Safari/Chrome
    // web zoom, Preview, Photos, Maps, Finder icon view, Notability). The tablet sends
    // a proper began→changed→ended series: buttons = phase (1 began / 0 changed /
    // 2 ended), scrollY = per-frame magnification ratio delta, x/y = pinch centroid.
    private func postZoom(_ e: InputEvent) {
        // Touch pinch carries a centroid (x/y) → anchor the zoom there. Trackpad pinch
        // sends x=y=0 → zoom at the current cursor (no warp jump).
        let anchored = (e.x != 0 || e.y != 0)
        let point = anchored ? globalPoint(e) : (CGEvent(source: nil)?.location ?? globalPoint(e))
        switch e.buttons {
        case 1: if anchored { warpCursor(point) }; postMagnify(phase: 1, delta: 0, at: point) // CGSGesturePhaseBegan
        case 2: postMagnify(phase: 4, delta: 0, at: point)                       // …Ended
        default:                                                                  // …Changed
            let raw = e.scrollY.isFinite ? Double(e.scrollY) : 0
            let d = max(-0.2, min(0.2, raw * magnifyGain))                        // clamp per-frame
            postMagnify(phase: 2, delta: d, at: point)
        }
    }

    // Build + post a type-29 gesture event carrying a magnify (kIOHIDEventTypeZoom).
    // The private CGEventType / CGEventField raw values aren't named in the Swift
    // enums, so reinterpret the UInt32 ids (both are UInt32-backed, same layout).
    private func postMagnify(phase: Int64, delta: Double, at point: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = unsafeBitCast(UInt32(29), to: CGEventType.self)   // kCGSEventGesture
        ev.setIntegerValueField(cgField(110), value: 8)             // HIDType = kIOHIDEventTypeZoom
        ev.setIntegerValueField(cgField(132), value: phase)         // gesture phase: Began1/Changed2/Ended4
        ev.setDoubleValueField(cgField(113), value: delta)          // magnification delta
        ev.location = point
        ev.flags = []
        ev.post(tap: .cghidEventTap)
    }

    private func cgField(_ id: UInt32) -> CGEventField { unsafeBitCast(id, to: CGEventField.self) }

    // TRACKPAD (tool=Mouse): RELATIVE motion. x/y are device deltas — move the cursor
    // BY them from its current position so it roams ALL displays (not confined to the
    // virtual display). Clicks land at the current cursor position. heldButton (shared
    // with injectFinger) tracks the pressed button so Move maps to the right *Dragged.
    private let mouseGain: CGFloat = 1.0 // TUNE on device (rawDelta units → points)
    // Trackpad has its OWN held-button + virtual cursor, never sharing injectFinger's
    // heldButton (the two HID sources interleave; sharing aborted finger/pen drags).
    private var heldMouseButton: CGMouseButton? = nil
    private var virtualPos: CGPoint? = nil

    private func releaseHeldMouse(_ p: CGPoint) {
        if heldMouseButton == .right { post(.rightMouseUp, p, .right, clickState: clickState) }
        else if heldMouseButton == .left { post(.leftMouseUp, p, .left, clickState: clickState) }
        heldMouseButton = nil
    }

    // Union of all displays, so the virtual cursor can roam every screen but never strand off-desktop.
    private func displayUnion() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success, n > 0 else { return currentBounds() }
        var u = CGRect.null
        for i in 0..<Int(n) { u = u.union(CGDisplayBounds(ids[i])) }
        return u.isNull ? currentBounds() : u
    }

    private func injectMouse(_ type: InputType, _ e: InputEvent) {
        // Authoritative virtual cursor: accumulate deltas ourselves (NO per-event read-back
        // of CGEvent.location, which lags and made the cursor stutter + clicks misalign).
        if virtualPos == nil { virtualPos = CGEvent(source: nil)?.location ?? .zero }
        var p = virtualPos ?? .zero
        let dx = e.x.isFinite ? CGFloat(e.x) : 0
        let dy = e.y.isFinite ? CGFloat(e.y) : 0
        switch type {
        case .touchDown:
            // Click at virtualPos — the TRUE final position the cursor reaches. A read-back of
            // CGEvent.location here is stale (the moves we just posted are still queued), and the
            // tablet now FREEZES the cursor during the press so virtualPos == where you aimed.
            releaseHeldMouse(p)   // a prior up may have been missed — never stack two downs
            let secondary = (e.buttons & InputButtons.secondary.rawValue) != 0
            if secondary { heldMouseButton = .right; post(.rightMouseDown, p, .right, clickState: beginClick(.right, at: p)) }
            else { heldMouseButton = .left; post(.leftMouseDown, p, .left, clickState: beginClick(.left, at: p)) }
        case .touchUp:
            releaseHeldMouse(p)
        case .touchMove:
            p.x += dx * mouseGain; p.y += dy * mouseGain
            p = clampToUnion(p); virtualPos = p
            if heldMouseButton == .right { post(.rightMouseDragged, p, .right, clickState: clickState) }
            else if heldMouseButton == .left { post(.leftMouseDragged, p, .left, clickState: clickState) }
            else { post(.mouseMoved, p, .left) }
        case .hover:
            if heldMouseButton != nil { releaseHeldMouse(p) }   // self-heal a missed release (own state only)
            p.x += dx * mouseGain; p.y += dy * mouseGain
            p = clampToUnion(p); virtualPos = p
            post(.mouseMoved, p, .left)
        default: break
        }
    }

    private func clampToUnion(_ p: CGPoint) -> CGPoint {
        let u = displayUnion()
        return CGPoint(x: min(max(p.x, u.minX), u.maxX - 1), y: min(max(p.y, u.minY), u.maxY - 1))
    }

    private func warpCursor(_ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    // COMMITTED text (Chinese IME + any typed Unicode), from CONTROL {"type":"text"}.
    public func injectText(_ s: String) { keyboard.injectText(s) }
}
