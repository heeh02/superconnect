import Foundation
import SuperconnectCoreFFI

/// Value-only projection of the canonical Rust `video_config` CONTROL record.
public struct VideoConfigControl: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let refreshRate: UInt32
    public let lowLatency: Bool

    public init?(width: Int, height: Int, refreshRate: Int = 0, lowLatency: Bool = false) {
        guard let width = UInt32(exactly: width), let height = UInt32(exactly: height),
              let refreshRate = UInt32(exactly: refreshRate),
              (16...8_192).contains(width), (16...8_192).contains(height),
              refreshRate <= 240 else { return nil }
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.lowLatency = lowLatency
    }

    public init?(wirePayload: Data) {
        var value = ScVideoConfigWireV1()
        value.struct_size = UInt32(MemoryLayout<ScVideoConfigWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = wirePayload.withUnsafeBytes { bytes in
            sc_video_config_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)
        }
        guard status == SC_OK, value.codec == UInt32(SC_VIDEO_CODEC_H264_V1),
              value.hdr == UInt32(SC_VIDEO_HDR_OFF_V1), value.low_latency <= 1 else { return nil }
        width = value.width
        height = value.height
        refreshRate = value.refresh_rate
        lowLatency = value.low_latency == 1
    }

    public var wirePayload: Data? {
        var value = ScVideoConfigWireV1()
        value.struct_size = UInt32(MemoryLayout<ScVideoConfigWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        value.codec = UInt32(SC_VIDEO_CODEC_H264_V1)
        value.hdr = UInt32(SC_VIDEO_HDR_OFF_V1)
        value.width = width
        value.height = height
        value.refresh_rate = refreshRate
        value.low_latency = lowLatency ? 1 : 0
        var needed = 0
        guard sc_video_config_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { return nil }
        var output = Data(count: needed)
        let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in
            sc_video_config_wire_encode_v1(
                &value, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &needed)
        }
        return status == SC_OK && needed == capacity ? output : nil
    }
}
