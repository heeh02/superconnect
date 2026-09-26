import XCTest
import SuperconnectCore
import SuperconnectProducer

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
}
