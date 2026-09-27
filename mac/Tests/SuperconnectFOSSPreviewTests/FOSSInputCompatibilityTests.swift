import XCTest
import SuperconnectCore
@testable import SuperconnectProducer

final class FOSSInputCompatibilityTests: XCTestCase {
    func testPenPressureTiltAndKeyboardUseCanonicalCodec() throws {
        let pen = InputEvent(type: InputType.touchDown.rawValue, tool: InputTool.pen.rawValue,
                             buttons: 1, timestampMs: 1234, x: 0.25, y: 0.75,
                             pressure: 0.6, tiltX: 12, tiltY: -8)
        XCTAssertEqual(InputCodec.decode(InputCodec.encode(pen)), pen)
        for type in [InputType.keyDown, .keyUp] {
            let key = InputEvent(type: type.rawValue, flags: 6, keyCode: 2017)
            XCTAssertEqual(InputCodec.decode(InputCodec.encode(key)), key)
        }
    }

    func testExistingPublicKeyboardMappingIsPreserved() {
        XCTAssertEqual(KeyMap.mac(2017), 0) // A
        XCTAssertEqual(KeyMap.mac(2054), 36) // Return
        XCTAssertEqual(KeyMap.mac(2055), 51) // Backspace
        XCTAssertEqual(KeyMap.mac(2012), 126) // Up
        XCTAssertEqual(KeyMap.mac(2076), 58) // Tablet Meta -> Option
        XCTAssertNil(KeyMap.mac(29)) // Android codes must be mapped before transmission.
    }

    func testCanonicalScrollAndZoomReachFOSSNativeGestureProjection() {
        XCTAssertTrue(FOSSPointerInjector.supportedTypes.contains(.scroll))
        XCTAssertTrue(FOSSPointerInjector.supportedTypes.contains(.zoom))

        let scroll = InputEvent(type: InputType.scroll.rawValue, tool: InputTool.finger.rawValue,
                                scrollX: 12, scrollY: -20)
        let decodedScroll = InputCodec.decode(InputCodec.encode(scroll))
        XCTAssertEqual(decodedScroll, scroll)
        let wheel = FOSSGestureProjection.scroll(
            dx: decodedScroll!.scrollX, dy: decodedScroll!.scrollY
        )
        XCTAssertEqual(wheel.vertical, 50)
        XCTAssertEqual(wheel.horizontal, -30)

        var active = false
        let began = InputEvent(type: InputType.zoom.rawValue, buttons: 1, x: 0.5, y: 0.5)
        let changed = InputEvent(type: InputType.zoom.rawValue, scrollY: 0.3)
        let ended = InputEvent(type: InputType.zoom.rawValue, buttons: 2)
        XCTAssertEqual(FOSSGestureProjection.zoomPhase(
            buttons: InputCodec.decode(InputCodec.encode(began))!.buttons, active: &active
        ), 1)
        XCTAssertEqual(FOSSGestureProjection.zoomPhase(
            buttons: InputCodec.decode(InputCodec.encode(changed))!.buttons, active: &active
        ), 2)
        XCTAssertEqual(FOSSGestureProjection.zoomDelta(changed.scrollY), 0.2)
        XCTAssertEqual(FOSSGestureProjection.zoomPhase(
            buttons: InputCodec.decode(InputCodec.encode(ended))!.buttons, active: &active
        ), 4)
        XCTAssertFalse(active)
        XCTAssertNil(FOSSGestureProjection.zoomPhase(buttons: 0, active: &active))

        XCTAssertEqual(FOSSGestureProjection.zoomPhase(buttons: 1, active: &active), 1)
        XCTAssertEqual(FOSSGestureProjection.endZoom(active: &active), 4)
        XCTAssertFalse(active)
        XCTAssertNil(FOSSGestureProjection.endZoom(active: &active))
        XCTAssertEqual(FOSSGestureProjection.zoomDelta(-.infinity), 0)
    }
}
