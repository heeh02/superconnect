import Foundation
import SuperconnectCoreFFI

enum SessionControlWire: Equatable, Sendable {
    case bye
    case ping(sequence: UInt64, t0: UInt64?)
    case pong(sequence: UInt64, t0: UInt64?, t1: UInt64?, t2: UInt64?)

    init?(wirePayload: Data) {
        guard let value = RustWireRuntime.decodeSessionControl(wirePayload) else { return nil }
        self = value
    }

    var wirePayload: Data? { RustWireRuntime.encodeSessionControl(self) }
}

extension RustWireRuntime {
    static func encodeSessionControl(_ control: SessionControlWire) -> Data? {
        _ = verifiedABI
        var value = ScSessionControlWireV1()
        value.struct_size = UInt32(MemoryLayout<ScSessionControlWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        switch control {
        case .bye:
            value.kind = UInt32(SC_SESSION_CONTROL_KIND_BYE_V1)
        case let .ping(sequence, t0):
            value.kind = UInt32(SC_SESSION_CONTROL_KIND_PING_V1)
            value.sequence = sequence
            if let t0 { value.presence |= UInt32(SC_SESSION_CONTROL_FIELD_T0_V1); value.t0 = t0 }
        case let .pong(sequence, t0, t1, t2):
            value.kind = UInt32(SC_SESSION_CONTROL_KIND_PONG_V1)
            value.sequence = sequence
            if let t0 { value.presence |= UInt32(SC_SESSION_CONTROL_FIELD_T0_V1); value.t0 = t0 }
            if let t1 { value.presence |= UInt32(SC_SESSION_CONTROL_FIELD_T1_V1); value.t1 = t1 }
            if let t2 { value.presence |= UInt32(SC_SESSION_CONTROL_FIELD_T2_V1); value.t2 = t2 }
        }
        var needed = 0
        guard sc_session_control_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { return nil }
        var output = Data(count: needed)
        let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in
            sc_session_control_wire_encode_v1(
                &value, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &needed)
        }
        return status == SC_OK && needed == capacity ? output : nil
    }

    static func decodeSessionControl(_ data: Data) -> SessionControlWire? {
        _ = verifiedABI
        var output = ScSessionControlWireV1()
        output.struct_size = UInt32(MemoryLayout<ScSessionControlWireV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes { bytes in
            sc_session_control_wire_decode_v1(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
        }
        guard status == SC_OK else { return nil }
        let field = { (bit: Int, value: UInt64) -> UInt64? in
            output.presence & UInt32(bit) == 0 ? nil : value
        }
        switch output.kind {
        case UInt32(SC_SESSION_CONTROL_KIND_BYE_V1): return .bye
        case UInt32(SC_SESSION_CONTROL_KIND_PING_V1):
            return .ping(sequence: output.sequence,
                         t0: field(SC_SESSION_CONTROL_FIELD_T0_V1, output.t0))
        case UInt32(SC_SESSION_CONTROL_KIND_PONG_V1):
            return .pong(sequence: output.sequence,
                         t0: field(SC_SESSION_CONTROL_FIELD_T0_V1, output.t0),
                         t1: field(SC_SESSION_CONTROL_FIELD_T1_V1, output.t1),
                         t2: field(SC_SESSION_CONTROL_FIELD_T2_V1, output.t2))
        default: return nil
        }
    }
}
