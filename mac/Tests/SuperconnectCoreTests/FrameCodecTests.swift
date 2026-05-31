import XCTest
@testable import SuperconnectCore

/// Cross-language conformance: every frame in proto/vectors.json must
/// encode to exactly `frameHex`, and `frameHex` must decode back to the
/// same (channel, flags, payload). The C++ host test asserts the same file.
final class FrameCodecTests: XCTestCase {

    struct VectorFile: Decodable { let vectors: [Vector] }
    struct Vector: Decodable {
        let name: String
        let channel: UInt8
        let flags: UInt8
        let payloadHex: String
        let frameHex: String
    }

    /// Locate proto/vectors.json relative to this source file:
    /// .../superconnect/mac/Tests/SuperconnectCoreTests/FrameCodecTests.swift
    /// → up 4 → .../superconnect → proto/vectors.json
    private func loadVectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SuperconnectCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // superconnect (repo root)
            .appendingPathComponent("proto/vectors.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VectorFile.self, from: data).vectors
    }

    func testEncodeMatchesGolden() throws {
        for v in try loadVectors() {
            let payload = Data(hexString: v.payloadHex)
            let frame = FrameCodec.encode(channel: v.channel, flags: v.flags, payload: payload)
            XCTAssertEqual(frame.hexEncodedString, v.frameHex, "encode mismatch for \(v.name)")
        }
    }

    func testDecodeMatchesGolden() throws {
        for v in try loadVectors() {
            let decoder = FrameDecoder()
            let frames = try decoder.push(Data(hexString: v.frameHex))
            XCTAssertEqual(frames.count, 1, "expected exactly one frame for \(v.name)")
            let f = frames[0]
            XCTAssertEqual(f.channel, v.channel, "channel mismatch for \(v.name)")
            XCTAssertEqual(f.flags, v.flags, "flags mismatch for \(v.name)")
            XCTAssertEqual(f.payload.hexEncodedString, v.payloadHex, "payload mismatch for \(v.name)")
        }
    }

    /// The decoder must reassemble a frame delivered one byte at a time.
    func testDecodeHandlesFragmentation() throws {
        let decoder = FrameDecoder()
        let full = Data(hexString: "010104000000deadbeef")
        var collected = [Frame]()
        for byte in full {
            collected += try decoder.push(Data([byte]))
        }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected[0].channel, 1)
        XCTAssertEqual(collected[0].flags, 1)
        XCTAssertEqual(collected[0].payload.hexEncodedString, "deadbeef")
    }

    /// Two frames concatenated in one read must both come out.
    func testDecodeHandlesCoalescing() throws {
        let decoder = FrameDecoder()
        let two = Data(hexString: "0000020000006869" + "020000000000")
        let frames = try decoder.push(two)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].channel, 0)
        XCTAssertEqual(frames[1].channel, 2)
        XCTAssertTrue(frames[1].payload.isEmpty)
    }
}
