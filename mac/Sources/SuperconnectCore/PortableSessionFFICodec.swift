import SuperconnectCoreFFI

enum PortableSessionFFICodec {
    static let generationField: UInt64 = 1 << 0
    static let operationField: UInt64 = 1 << 1
    static let timerField: UInt64 = 1 << 2
    static let claimField: UInt64 = 1 << 3
    static let credentialField: UInt64 = 1 << 4
    static let candidateCredentialField: UInt64 = 1 << 5
    static let challengeField: UInt64 = 1 << 6
    static let localChallengeField: UInt64 = 1 << 7
    static let peerChallengeField: UInt64 = 1 << 8
    static let proofField: UInt64 = 1 << 9
    static let envelopeField: UInt64 = 1 << 10
    static let localEnrollmentKeyField: UInt64 = 1 << 11
    static let peerEnrollmentKeyField: UInt64 = 1 << 12
    static let identityField: UInt64 = 1 << 13
    static let authVersionField: UInt64 = 1 << 14
    static let knownFields = generationField | operationField | timerField | claimField
        | credentialField | candidateCredentialField | challengeField | localChallengeField
        | peerChallengeField | proofField | envelopeField | localEnrollmentKeyField
        | peerEnrollmentKeyField | identityField | authVersionField

    static func encodeIdentity(_ identity: PortableSessionIdentity) -> ScSessionPeerIdentityV1 {
        let bytes = Array(identity.rawValue.utf8)
        precondition(!bytes.isEmpty && bytes.count <= PortableSessionIdentity.maximumUTF8Bytes)
        var output = ScSessionPeerIdentityV1()
        output.length = UInt32(bytes.count)
        withUnsafeMutableBytes(of: &output.bytes) { $0.copyBytes(from: bytes) }
        return output
    }

    static func decodeIdentity(_ input: ScSessionPeerIdentityV1) throws -> PortableSessionIdentity {
        let length = Int(input.length)
        guard length > 0, length <= PortableSessionIdentity.maximumUTF8Bytes else {
            throw PortableSessionError.malformedEffect
        }
        let bytes = withUnsafeBytes(of: input.bytes) { Array($0) }
        guard bytes[length...].allSatisfy({ $0 == 0 }),
              let identity = String(bytes: bytes[..<length], encoding: .utf8) else {
            throw PortableSessionError.malformedEffect
        }
        do { return try PortableSessionIdentity(identity) }
        catch { throw PortableSessionError.malformedEffect }
    }

    static func encodeConfiguration(
        _ configuration: PortableSessionConfiguration
    ) -> ScSessionConfigV1 {
        var output = ScSessionConfigV1()
        output.struct_size = UInt32(MemoryLayout<ScSessionConfigV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        output.generation = configuration.generation.rawValue
        output.first_operation_id = configuration.firstOperationID.rawValue
        output.local_enrollment_key = configuration.localEnrollmentKey.rawValue
        output.side = configuration.side.rawValue
        output.media_role = configuration.mediaRole.rawValue
        output.origin = configuration.origin.rawValue
        output.local_identity = encodeIdentity(configuration.localIdentity)
        return output
    }

    static func optional<T>(
        _ presence: UInt64,
        _ bit: UInt64,
        _ rawValue: UInt64,
        _ transform: (UInt64) -> T?
    ) throws -> T? {
        if presence & bit == 0 { return nil }
        guard let value = transform(rawValue) else { throw PortableSessionError.malformedEffect }
        return value
    }
}
