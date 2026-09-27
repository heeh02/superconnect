import Foundation
import XCTest
import SuperconnectCore
@testable import superconnect_app_foss_preview

final class FOSSQualityPresetTests: XCTestCase {
    func testFriendlyPresetsKeepExistingRetinaBackingAndH264VideoConfig() throws {
        XCTAssertEqual(FOSSQualityPreset.allCases.map(\.rawValue), [25, 50, 80])
        XCTAssertEqual(FOSSQualityPreset.extreme.title, "极致 · 80 Mbps")

        let caps: [String: Any] = [
            "screenWidth": NSNumber(value: 2_880),
            "screenHeight": NSNumber(value: 1_920),
            "refreshRate": NSNumber(value: 60),
            "codecs": ["h264"],
        ]
        let display = HostMediaConfiguration.displayConfig(from: caps)
        XCTAssertEqual(display.pointWidth, 1_440)
        XCTAssertEqual(display.pointHeight, 960)
        XCTAssertEqual(display.scale, 2)
        let width = display.pointWidth * display.scale
        let height = display.pointHeight * display.scale
        XCTAssertEqual(width, 2_880)
        XCTAssertEqual(height, 1_920)
        XCTAssertEqual(HostMediaConfiguration.codec(from: caps), .h264)

        let message = try XCTUnwrap(VideoConfigControl(
            width: width, height: height, refreshRate: 60
        ))
        let payload = try XCTUnwrap(message.wirePayload)
        XCTAssertEqual(VideoConfigControl(wirePayload: payload), message)
    }
}
