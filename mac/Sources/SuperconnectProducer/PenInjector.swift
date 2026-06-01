import CoreGraphics
import SuperconnectCore

/// PEN injection: draws with the tablet-pointer CGEvent subtype + pressure/tilt, and brackets each
/// stroke with tablet PROXIMITY enter/leave so apps recognize a real stylus and actually read
/// pressure. Self-contained — the dispatcher passes the already-mapped global point, and pen shares
/// no mouse/click state with finger/trackpad, so this lifts cleanly out of InputInjector. Logic is
/// verbatim; only `source` is injected.
final class PenInjector {
    private let source: CGEventSource?
    private let tabletPointSubtype: Int64 = 1     // kCGEventMouseSubtypeTabletPoint
    private let tabletProximitySubtype: Int64 = 2 // kCGEventMouseSubtypeTabletProximity
    private let penDeviceID: Int64 = 0x01
    private var penInProximity = false

    init(source: CGEventSource?) { self.source = source }

    // Bracket each stroke with TABLET PROXIMITY enter/leave events so apps recognize a real pen.
    func inject(_ type: InputType, _ point: CGPoint, _ e: InputEvent) {
        switch type {
        case .touchDown:
            enterProximity(point)             // announce a pen entered range → pen mode
            postPen(.leftMouseDown, point, e)
        case .touchUp:
            postPen(.leftMouseUp, point, e)
            leaveProximity(point)
        case .touchMove, .hover:
            if !penInProximity { enterProximity(point) }
            let down = (e.buttons & InputButtons.primary.rawValue) != 0
            postPen(down ? .leftMouseDragged : .mouseMoved, point, e)
        default: break
        }
    }

    private func enterProximity(_ point: CGPoint) {
        if penInProximity { return }
        penInProximity = true
        postProximity(true, point)
    }

    private func leaveProximity(_ point: CGPoint) {
        if !penInProximity { return }
        penInProximity = false
        postProximity(false, point)
    }

    // A tablet PROXIMITY event tells macOS a stylus device is entering/leaving range
    // (→ NSEvent .tabletProximity). Most apps gate pressure on having seen this with
    // pointerType = pen; without it they treat our points as a plain mouse. Needs no
    // special entitlement — it's a normal synthesized CGEvent.
    private func postProximity(_ enter: Bool, _ point: CGPoint) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventSubtype, value: tabletProximitySubtype)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: 1) // NX_TABLET_POINTER_PEN
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: penDeviceID)
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: 0x534B) // 'SK'
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        ev.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0000FFFF) // advertise pressure/tilt/etc.
        ev.post(tap: .cghidEventTap)
    }

    private func postPen(_ type: CGEventType, _ point: CGPoint, _ e: InputEvent) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventSubtype, value: tabletPointSubtype)
        event.setIntegerValueField(.tabletEventDeviceID, value: penDeviceID) // tie points to the proximity device
        event.setDoubleValueField(.tabletEventPointPressure, value: Double(normalizePressure(e.pressure)))
        event.setDoubleValueField(.tabletEventTiltX, value: Double(normalizeTilt(e.tiltX)))
        event.setDoubleValueField(.tabletEventTiltY, value: Double(normalizeTilt(e.tiltY)))
        event.post(tap: .cghidEventTap)
    }

    private func normalizePressure(_ p: Float) -> Float {
        guard p.isFinite else { return 0 }
        if p > 1.5 { return min(1, p / 65535) }
        return min(1, max(0, p))
    }

    private func normalizeTilt(_ t: Float) -> Float {
        guard t.isFinite else { return 0 }
        return max(-1, min(1, t / 90))
    }
}
