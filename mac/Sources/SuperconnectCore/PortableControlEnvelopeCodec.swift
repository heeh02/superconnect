import Foundation
import SuperconnectCoreFFI

public struct PortableControlEnvelope: Equatable, Sendable {
    public let kind: UInt32
    public let presence: UInt32
    public let generation: UInt64
    public let operation: UInt64
    public let value0: UInt64
    public let value1: UInt64
    public let detail: UInt32

    public func has(_ field: UInt32) -> Bool { presence & field != 0 }
}

public enum PortableControlEnvelopeCodec {
    public static func decode(_ payload: Data) -> PortableControlEnvelope? {
        var value = ScControlEnvelopeV1()
        value.struct_size = UInt32(MemoryLayout<ScControlEnvelopeV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = payload.withUnsafeBytes { bytes in
            sc_control_envelope_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)
        }
        guard status == SC_OK, value.reserved0 == 0, value.reserved1 == 0 else { return nil }
        return .init(
            kind: value.kind, presence: value.presence, generation: value.generation,
            operation: value.operation, value0: value.value0, value1: value.value1,
            detail: value.detail)
    }

    public static func decodeCapsUpdate(_ payload: Data) -> [String: Any]? {
        var value = ScControlCapsUpdateV1()
        value.struct_size = UInt32(MemoryLayout<ScControlCapsUpdateV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = payload.withUnsafeBytes { bytes in
            sc_control_caps_update_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)
        }
        guard status == SC_OK, value.reserved0 == 0, value.reserved1 == 0,
              value.reserved2 == 0 else { return nil }
        var result: [String: Any] = [
            "codecs": [
                value.codecs & 1 != 0 ? "h264" : nil,
                value.codecs & 2 != 0 ? "hevc" : nil,
            ].compactMap { $0 },
            "screenWidth": value.screen_width,
            "screenHeight": value.screen_height,
        ]
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_SCALE_V1) != 0 {
            result["scale"] = value.scale
        }
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_REFRESH_RATE_V1) != 0 {
            result["refreshRate"] = value.refresh_rate
        }
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1) != 0 {
            result["refreshRateMax"] = value.refresh_rate_max
        }
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_PEN_V1) != 0 {
            result["pen"] = value.values & UInt32(SC_CONTROL_CAPS_VALUE_PEN_V1) != 0
        }
        var hdr: [String: Bool] = [:]
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_HDR_HLG_V1) != 0 {
            hdr["hlg"] = value.values & UInt32(SC_CONTROL_CAPS_VALUE_HDR_HLG_V1) != 0
        }
        if value.presence & UInt32(SC_CONTROL_CAPS_FIELD_HDR_PQ_V1) != 0 {
            hdr["pq"] = value.values & UInt32(SC_CONTROL_CAPS_VALUE_HDR_PQ_V1) != 0
        }
        if !hdr.isEmpty { result["hdr"] = hdr }
        return result
    }

    public static func decodeText(_ payload: Data) -> String? {
        var needed = 0
        let query = payload.withUnsafeBytes { bytes in
            sc_control_text_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil, 0, &needed)
        }
        guard query == SC_BUFFER_TOO_SMALL, needed > 0, needed <= 4096 else { return nil }
        var output = Data(count: needed)
        let status = payload.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                sc_control_text_wire_decode_v1(
                    input.bindMemory(to: UInt8.self).baseAddress, input.count,
                    destination.bindMemory(to: UInt8.self).baseAddress,
                    destination.count, &needed)
            }
        }
        guard status == SC_OK, needed == output.count else { return nil }
        return String(data: output, encoding: .utf8)
    }

    public static func errorReason(_ detail: UInt32) -> String {
        if detail == SC_CONTROL_ERROR_REASON_VERSION_MISMATCH_V1 { return "version_mismatch" }
        if detail == SC_CONTROL_ERROR_REASON_AUTH_REQUIRED_V1 { return "auth_required" }
        if detail == SC_CONTROL_ERROR_REASON_AUTH_FAILED_V1 { return "auth_failed" }
        if detail == SC_CONTROL_ERROR_REASON_PAIRING_REJECTED_V1 { return "pairing_rejected" }
        if detail == SC_CONTROL_ERROR_REASON_AUTH_TIMEOUT_V1 { return "auth_timeout" }
        if detail == SC_CONTROL_ERROR_REASON_SESSION_BUSY_V1 { return "session_busy" }
        if detail == SC_CONTROL_ERROR_REASON_SESSION_CAPACITY_V1 { return "session_capacity" }
        if detail == SC_CONTROL_ERROR_REASON_CAPABILITY_FAILED_V1 { return "capability_failed" }
        if detail == SC_CONTROL_ERROR_REASON_CREDENTIAL_UNAVAILABLE_V1 {
            return "credential_unavailable"
        }
        if detail == SC_CONTROL_ERROR_REASON_ACK_FAILED_V1 { return "ack_failed" }
        return "protocol_error"
    }

    public static func encodeVideoEpoch(_ epoch: UInt32, firstFrameSequence: UInt32) -> Data? {
        var needed = 0
        guard sc_control_video_epoch_wire_encode_v1(
            epoch, firstFrameSequence, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0, needed <= 256 else { return nil }
        var output = Data(count: needed)
        let status = output.withUnsafeMutableBytes { bytes in
            sc_control_video_epoch_wire_encode_v1(
                epoch, firstFrameSequence, bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count, &needed)
        }
        return status == SC_OK && needed == output.count ? output : nil
    }
}
