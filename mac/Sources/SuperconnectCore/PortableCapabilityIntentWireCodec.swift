import Foundation

public enum PortableCapabilityIntentWireError: Error, Equatable {
    case tooLarge
    case syntax
    case unknownField
    case duplicateField
    case missingField
    case invalidValue
    case invariantViolation
    case coreUnavailable
    case coreFailure(Int32)
}

public enum PortableCapabilityIntentWireCodec {
    public static let wireType = "capability_intent_v2"
    public static let negotiationVersion: UInt16 = 2
    public static let maxBytes = 1_024

    public static func decode(_ data: Data) throws -> PortableCapabilityIntentMessage {
        return try PortableCapabilityIntentFFICodec.decodeWire(data)
    }

    public static func encode(_ message: PortableCapabilityIntentMessage) throws -> String {
        let data = try encodeData(message)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw PortableCapabilityIntentWireError.invalidValue
        }
        return encoded
    }

    package static func encodeData(_ message: PortableCapabilityIntentMessage) throws -> Data {
        return try PortableCapabilityIntentFFICodec.encodeWire(message)
    }
}
