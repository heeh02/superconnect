import XCTest
@testable import SuperconnectCore

final class InputCodecTests: XCTestCase {

    /// Canonical sample event used as the cross-language golden vector.
    /// type=touchMove(1), tool=pen(1), x=0.5, y=0.25, pressure=1.0
    private func sample() -> InputEvent {
        InputEvent(type: InputType.touchMove.rawValue,
                   tool: InputTool.pen.rawValue,
                   buttons: InputButtons.primary.rawValue,
                   flags: 0, timestampMs: 0,
                   x: 0.5, y: 0.25, pressure: 1.0,
                   scrollX: 0, scrollY: 0, keyCode: 0, reserved: 0)
    }

    func testRecordSize() {
        XCTAssertEqual(InputCodec.encode(sample()).count, InputCodec.recordSize)
    }

    func testRoundTrip() {
        let e = sample()
        let decoded = InputCodec.decode(InputCodec.encode(e))
        XCTAssertEqual(decoded, e)
    }

    func testRoundTripVariety() {
        let events = [
            InputEvent(type: 0, tool: 3, buttons: 1, flags: 0, timestampMs: 123456789,
                       x: 0.0, y: 1.0, pressure: 0.0, scrollX: -3.5, scrollY: 2.25,
                       keyCode: 42, reserved: 7),
            InputEvent(type: 6, tool: 0, x: 0.999, y: 0.001, scrollX: 10, scrollY: -10),
            InputEvent(type: 2, tool: 1, x: 0.3333, y: 0.6667, pressure: 0.42),
        ]
        for e in events {
            XCTAssertEqual(InputCodec.decode(InputCodec.encode(e)), e)
        }
    }

    func testGoldenVector() {
        // Frozen 44-byte wire bytes for `sample()` (tiltX/tiltY = 0). Keep in
        // sync with proto/vectors.json `inputVectors` and ArkTS InputCodec.ets.
        let golden = "010101000000000000000000"   // type,tool,buttons,flags + ts(8)
            + "0000003f"   // x = 0.5
            + "0000803e"   // y = 0.25
            + "0000803f"   // pressure = 1.0
            + "00000000"   // tiltX = 0
            + "00000000"   // tiltY = 0
            + "00000000"   // scrollX = 0
            + "00000000"   // scrollY = 0
            + "0000" + "0000"   // keyCode, reserved
        XCTAssertEqual(InputCodec.encode(sample()).hexEncodedString, golden)
    }
}
