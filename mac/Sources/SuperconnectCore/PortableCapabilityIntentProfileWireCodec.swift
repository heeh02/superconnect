import Foundation

public enum PortableCapabilityIntentProfileWireError: Error, Equatable {
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

public enum PortableCapabilityIntentProfileWireCodec {
    public static let wireType = "capability_intent_profile_v2"
    public static let schemaVersion: UInt16 = 2
    public static let maxBytes = 768

    public static func decode(_ data: Data) throws -> PortableCapabilityIntentPeerAdvertisement {
        return try PortableCapabilityIntentFFICodec.decodeProfileWire(data)
    }

    public static func encode(
        _ message: PortableCapabilityIntentProductAdvertisement
    ) throws -> String {
        let data = try encodeData(message)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw PortableCapabilityIntentProfileWireError.invalidValue
        }
        return encoded
    }

    package static func encodeData(_ message: PortableCapabilityIntentProductAdvertisement) throws -> Data {
        return try PortableCapabilityIntentFFICodec.encodeProfileWire(message)
    }
}
