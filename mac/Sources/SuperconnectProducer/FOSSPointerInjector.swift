import Foundation
import CoreGraphics
import ApplicationServices
import SuperconnectCore

/// Consent-gated native input effects. Wire decoding stays in Rust.
public final class FOSSPointerInjector {
    public static let enabledKey = "sc.foss.allowPointerControl"
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
    private var last: InputEvent?
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
              [.touchDown, .touchMove, .touchUp, .hover, .keyDown, .keyUp].contains(type) else {
            releaseLocked()
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
            let kind: CGEventType = switch type {
                case .touchDown: .leftMouseDown
                case .touchUp: .leftMouseUp
                case .touchMove: last == nil ? .mouseMoved : .leftMouseDragged
                default: .mouseMoved
            }
            post(kind, point)
        } else { pen.inject(type, point, event) }
        last = type == .touchUp || (type == .hover && event.tool == InputTool.finger.rawValue) ? nil : event
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
        guard var event = last else { return }
        event.type = InputType.touchUp.rawValue; event.buttons = 0; event.pressure = 0
        if event.tool == InputTool.finger.rawValue { post(.leftMouseUp, position(event)) }
        else { pen.inject(.touchUp, position(event), event) }
        last = nil
    }
    private func position(_ event: InputEvent) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + CGFloat(event.x) * bounds.width,
                       y: bounds.minY + CGFloat(event.y) * bounds.height)
    }
    private func post(_ type: CGEventType, _ point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
    }
}
