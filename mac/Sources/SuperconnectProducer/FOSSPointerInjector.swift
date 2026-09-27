import Foundation
import CoreGraphics
import ApplicationServices
import SuperconnectCore

enum FOSSGestureProjection {
    static func scroll(dx: Float, dy: Float) -> (vertical: Int32, horizontal: Int32) {
        let x = dx.isFinite ? CGFloat(dx) : 0
        let y = dy.isFinite ? CGFloat(dy) : 0
        let gain: CGFloat = 2.5
        func wheel(_ value: CGFloat) -> Int32 {
            Int32(max(-100_000, min(100_000, (-value * gain).rounded())))
        }
        return (wheel(y), wheel(x))
    }

    static func zoomPhase(buttons: UInt8, active: inout Bool) -> Int64? {
        switch buttons {
        case 1:
            active = true
            return 1 // began
        case 2:
            guard active else { return nil }
            active = false
            return 4 // ended
        default:
            return active ? 2 : nil // changed
        }
    }

    static func zoomDelta(_ value: Float) -> Double {
        let raw = value.isFinite ? Double(value) : 0
        return max(-0.2, min(0.2, raw))
    }

    static func endZoom(active: inout Bool) -> Int64? {
        guard active else { return nil }
        active = false
        return 4
    }
}

enum FOSSPointerButton: Equatable {
    case left
    case right
}

enum FOSSPointerAction: Equatable {
    case moved
    case down(FOSSPointerButton)
    case dragged(FOSSPointerButton)
    case up(FOSSPointerButton)

    var eventType: CGEventType {
        switch self {
        case .moved: .mouseMoved
        case .down(.left): .leftMouseDown
        case .down(.right): .rightMouseDown
        case .dragged(.left): .leftMouseDragged
        case .dragged(.right): .rightMouseDragged
        case .up(.left): .leftMouseUp
        case .up(.right): .rightMouseUp
        }
    }

    var mouseButton: CGMouseButton {
        switch self {
        case .down(.right), .dragged(.right), .up(.right): .right
        default: .left
        }
    }
}

struct FOSSPointerButtonProjection {
    private(set) var held: FOSSPointerButton?

    mutating func action(type: InputType, buttons: UInt8) -> FOSSPointerAction? {
        switch type {
        case .touchDown:
            if (buttons & InputButtons.secondary.rawValue) != 0 { held = .right }
            else if (buttons & InputButtons.primary.rawValue) != 0 { held = .left }
            else { held = nil }
            return held.map(FOSSPointerAction.down) ?? .moved
        case .touchMove:
            return held.map(FOSSPointerAction.dragged) ?? .moved
        case .touchUp:
            return release() ?? .moved
        case .hover:
            return .moved
        default:
            return nil
        }
    }

    mutating func release() -> FOSSPointerAction? {
        defer { held = nil }
        return held.map(FOSSPointerAction.up)
    }
}

/// Consent-gated native input effects. Wire decoding stays in Rust.
public final class FOSSPointerInjector {
    public static let enabledKey = "sc.foss.allowPointerControl"
    static let supportedTypes: [InputType] = [
        .touchDown, .touchMove, .touchUp, .hover, .keyDown, .keyUp, .scroll, .zoom,
    ]
    public static func hasPermission() -> Bool { AXIsProcessTrusted() }
    public static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .combinedSessionState)
    private lazy var pen = PenInjector(source: source)
    private lazy var keyboard = KeyboardInjector(source: source)
    private var heldKeys: [UInt16: InputEvent] = [:]
    private let lock = NSLock()
    private var lastPen: InputEvent?
    private var finger = FOSSPointerButtonProjection()
    private var lastFingerPoint: CGPoint = .zero
    private var zoomActive = false
    private var zoomPoint: CGPoint = .zero
    private var observer: NSObjectProtocol?

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: nil) { [weak self] _ in
                if !UserDefaults.standard.bool(forKey: Self.enabledKey) { self?.release() }
            }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        release()
    }

    public func inject(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard Self.hasPermission(), UserDefaults.standard.bool(forKey: Self.enabledKey),
              let event = InputCodec.decode(bytes), event.tool <= InputTool.eraser.rawValue,
              let type = InputType(rawValue: event.type),
              Self.supportedTypes.contains(type) else {
            releaseLocked()
            return
        }
        if type == .scroll {
            finishZoomLocked()
            releaseFingerLocked()
            postScroll(dx: event.scrollX, dy: event.scrollY)
            return
        }
        if type == .zoom {
            postZoom(event)
            return
        }
        if type == .keyDown || type == .keyUp {
            if type == .keyDown { heldKeys[event.keyCode] = event }
            else { heldKeys.removeValue(forKey: event.keyCode) }
            keyboard.injectKey(type == .keyDown, event)
            return
        }
        let point = position(event)
        if event.tool == InputTool.finger.rawValue {
            if type == .touchDown { releaseFingerLocked() }
            lastFingerPoint = point
            if let action = finger.action(type: type, buttons: event.buttons) {
                postFinger(action, at: point)
            }
            return
        }
        pen.inject(type, point, event)
        lastPen = type == .touchUp ? nil : event
    }

    public func injectText(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard Self.hasPermission(), UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        keyboard.injectText(text)
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }
    private func releaseLocked() {
        heldKeys.values.forEach { keyboard.injectKey(false, $0) }
        heldKeys.removeAll()
        finishZoomLocked()
        releaseFingerLocked()
        guard var event = lastPen else { return }
        event.type = InputType.touchUp.rawValue; event.buttons = 0; event.pressure = 0
        pen.inject(.touchUp, position(event), event)
        lastPen = nil
    }
    private func position(_ event: InputEvent) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + CGFloat(event.x) * bounds.width,
                       y: bounds.minY + CGFloat(event.y) * bounds.height)
    }
    private func postFinger(_ action: FOSSPointerAction, at point: CGPoint) {
        post(action.eventType, point, button: action.mouseButton)
    }

    private func releaseFingerLocked() {
        if let action = finger.release() { postFinger(action, at: lastFingerPoint) }
    }

    private func post(_ type: CGEventType, _ point: CGPoint,
                      button: CGMouseButton = .left) {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Float, dy: Float) {
        let wheel = FOSSGestureProjection.scroll(dx: dx, dy: dy)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: wheel.vertical,
                                  wheel2: wheel.horizontal, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func postZoom(_ event: InputEvent) {
        guard let phase = FOSSGestureProjection.zoomPhase(
            buttons: event.buttons, active: &zoomActive
        ) else { return }
        if phase == 1 { releaseFingerLocked() }
        let anchored = event.x != 0 || event.y != 0
        let point = anchored ? position(event) : (CGEvent(source: nil)?.location ?? position(event))
        if phase == 1 && anchored { post(.mouseMoved, point) }
        zoomPoint = point
        postMagnify(phase: phase,
                    delta: phase == 2 ? FOSSGestureProjection.zoomDelta(event.scrollY) : 0,
                    at: point)
    }

    private func finishZoomLocked() {
        guard let phase = FOSSGestureProjection.endZoom(active: &zoomActive) else { return }
        postMagnify(phase: phase, delta: 0, at: zoomPoint)
    }

    private func postMagnify(phase: Int64, delta: Double, at point: CGPoint) {
        guard let event = CGEvent(source: source) else { return }
        event.type = unsafeBitCast(UInt32(29), to: CGEventType.self)
        event.setIntegerValueField(cgField(110), value: 8) // HID zoom gesture
        event.setIntegerValueField(cgField(132), value: phase)
        event.setDoubleValueField(cgField(113), value: delta)
        event.location = point
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func cgField(_ id: UInt32) -> CGEventField {
        unsafeBitCast(id, to: CGEventField.self)
    }
}
