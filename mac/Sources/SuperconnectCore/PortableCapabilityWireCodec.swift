import Foundation
import SuperconnectCoreFFI

/// Canonical capability CONTROL bytes owned by the shared Rust core.
public enum PortableCapabilityWireCodec {
    public static let maxBytes = 1_024

    public static func encodeData(_ message: PortableCapabilityMessage) throws -> Data {
        var value = PortableCapabilityCodec.event(
            .message(message), runtimeGeneration: message.generation)
        var needed = 0
        let sizing = sc_capability_wire_encode_v1(&value, nil, 0, &needed)
        guard sizing == SC_BUFFER_TOO_SMALL, needed > 0, needed <= maxBytes else {
            throw failure(sizing)
        }
        let expected = needed
        var output = Data(count: expected)
        let status = output.withUnsafeMutableBytes {
            sc_capability_wire_encode_v1(
                &value, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &needed)
        }
        guard status == SC_OK, needed == expected else { throw failure(status) }
        return output
    }

    public static func decode(_ data: Data) throws -> PortableCapabilityMessage {
        guard data.count <= maxBytes else { throw PortableCapabilityError.invalidConfiguration }
        var value = ScCapabilityEventV1()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityEventV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = data.withUnsafeBytes {
            sc_capability_wire_decode_v1(
                $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &value)
        }
        guard status == SC_OK,
              value.struct_size == UInt32(MemoryLayout<ScCapabilityEventV1>.size),
              value.api_version == UInt32(SC_API_VERSION_V1),
              value.has_negotiation_version == 1,
              zero(value.reserved),
              let kind = PortableCapabilityMessageKind(rawValue: value.event_type &- 1),
              let generation = PortableCapabilityGeneration(rawValue: value.generation),
              value.capabilities & ~PortableCapabilityAuthorization.known.rawValue == 0,
              let offerer = PortableCapabilityRole(rawValue: value.offerer_role),
              let selector = PortableCapabilityRole(rawValue: value.selector_role),
              let projection = PortableCapabilityProjection(rawValue: value.projection),
              let transport = PortableCapabilityTransport(rawValue: value.transport) else {
            throw status == SC_INVALID_ARGUMENT ? PortableCapabilityError.invalidConfiguration
                : failure(status)
        }
        return .init(
            kind: kind, generation: generation,
            negotiationVersion: value.negotiation_version,
            authorizedCapabilities: .init(rawValue: value.capabilities),
            offererRole: offerer, selectorRole: selector,
            projection: projection, transport: transport
        )
    }

    private static func failure(_ status: ScStatus) -> PortableCapabilityError {
        status == SC_INVALID_ARGUMENT ? .invalidConfiguration : .coreFailure(Int32(status))
    }

    private static func zero<T>(_ value: T) -> Bool {
        withUnsafeBytes(of: value) { $0.allSatisfy { $0 == 0 } }
    }
}
