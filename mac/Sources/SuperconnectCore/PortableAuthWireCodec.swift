import Foundation
import SuperconnectCoreFFI

public enum PortableAuthWireMessage: Equatable, Sendable {
    case auth(proof: Data, challenge: Data)
    case authAck(proof: Data)
    case pairSecret(sealedSecret: Data, pairingSalt: Data, aeadNonce: Data)
}

public enum PortableAuthWireCodec {
    public static func encode(_ message: PortableAuthWireMessage) throws -> Data {
        var value = ScAuthWireMessageV1()
        value.struct_size = UInt32(MemoryLayout<ScAuthWireMessageV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        switch message {
        case .auth(let proof, let challenge):
            value.kind = UInt8(SC_AUTH_WIRE_KIND_AUTH)
            try copy(proof, count: 32, into: &value.proof)
            try copy(challenge, count: 32, into: &value.challenge)
        case .authAck(let proof):
            value.kind = UInt8(SC_AUTH_WIRE_KIND_AUTH_ACK)
            try copy(proof, count: 32, into: &value.proof)
        case .pairSecret(let sealed, let salt, let nonce):
            value.kind = UInt8(SC_AUTH_WIRE_KIND_PAIR_SECRET)
            try copy(sealed, count: 48, into: &value.sealed_secret)
            try copy(salt, count: 16, into: &value.pairing_salt)
            try copy(nonce, count: 12, into: &value.aead_nonce)
        }
        var needed = 0
        guard sc_auth_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL,
              needed > 0 else { throw PortableAuthWireError.invalid }
        var output = Data(count: needed)
        let status = output.withUnsafeMutableBytes { bytes in
            sc_auth_wire_encode_v1(&value, bytes.bindMemory(to: UInt8.self).baseAddress,
                                   bytes.count, &needed)
        }
        guard status == SC_OK, needed == output.count else { throw PortableAuthWireError.invalid }
        return output
    }

    public static func decode(_ input: Data) throws -> PortableAuthWireMessage {
        var value = ScAuthWireMessageV1()
        value.struct_size = UInt32(MemoryLayout<ScAuthWireMessageV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = input.withUnsafeBytes { bytes in
            sc_auth_wire_decode_v1(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value)
        }
        guard status == SC_OK else { throw PortableAuthWireError.invalid }
        switch Int(value.kind) {
        case SC_AUTH_WIRE_KIND_AUTH:
            return .auth(proof: data(value.proof), challenge: data(value.challenge))
        case SC_AUTH_WIRE_KIND_AUTH_ACK:
            return .authAck(proof: data(value.proof))
        case SC_AUTH_WIRE_KIND_PAIR_SECRET:
            return .pairSecret(sealedSecret: data(value.sealed_secret),
                               pairingSalt: data(value.pairing_salt),
                               aeadNonce: data(value.aead_nonce))
        default: throw PortableAuthWireError.invalid
        }
    }

    private static func copy<T>(_ data: Data, count: Int, into value: inout T) throws {
        guard data.count == count else { throw PortableAuthWireError.invalid }
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
    }
    private static func data<T>(_ value: T) -> Data {
        var value = value
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

public enum PortableAuthWireError: Error { case invalid }
