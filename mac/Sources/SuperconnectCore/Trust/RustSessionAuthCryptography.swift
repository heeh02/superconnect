import Foundation
import SuperconnectCoreFFI

struct RustSessionAuthCryptography: SessionAuthCryptography {
    let backend = SessionAuthBackend.rustCore

    func validatePeerID(_ peerID: String) throws {
        _ = RustAuthRuntime.verifiedABI
        var input = ScAuthPeerIdV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthPeerIdV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.length = try copyPeerID(peerID, into: &input.bytes)
        input.reserved = 0
        let status = sc_auth_peer_id_validate_v1(&input)
        guard status == SC_OK else { throw SessionAuthCryptoError.invalidPeerID }
    }

    func publicKey(privateScalar: Data) throws -> Data {
        _ = RustAuthRuntime.verifiedABI
        try require(privateScalar, count: 32, field: .privateScalar)
        var input = ScAuthP256PrivateRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthP256PrivateRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        try copyExact(privateScalar, field: .privateScalar, into: &input.private_scalar)
        defer { wipe(&input) }

        var output = ScAuthP256PublicKeyV1()
        output.struct_size = UInt32(MemoryLayout<ScAuthP256PublicKeyV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        try requireOK(sc_auth_p256_public_from_private_v1(&input, &output))
        defer { wipe(&output) }
        return data(of: &output.public_key)
    }

    func createProof(secret: Data, direction: SessionAuthProofDirection) throws -> Data {
        _ = RustAuthRuntime.verifiedABI
        try require(secret, count: 32, field: .pairSecret)
        let parts = direction.components
        try validatePeerID(parts.proverID)
        try validatePeerID(parts.verifierID)
        try require(parts.nonce, count: 32, field: .authNonce)

        var input = ScAuthProofCreateRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthProofCreateRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.prover_id_length = try copyPeerID(parts.proverID, into: &input.prover_id)
        input.verifier_id_length = try copyPeerID(parts.verifierID, into: &input.verifier_id)
        input.reserved = (0, 0)
        try copyExact(secret, field: .pairSecret, into: &input.pair_secret)
        try copyExact(parts.nonce, field: .authNonce, into: &input.nonce)
        defer { wipe(&input) }

        var output = ScAuthProofV1()
        output.struct_size = UInt32(MemoryLayout<ScAuthProofV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        try requireOK(sc_auth_proof_create_v1(&input, &output))
        defer { wipe(&output) }
        return data(of: &output.proof)
    }

    func verifyProof(_ proof: Data, secret: Data, direction: SessionAuthProofDirection) throws {
        _ = RustAuthRuntime.verifiedABI
        try require(proof, count: 32, field: .proof)
        try require(secret, count: 32, field: .pairSecret)
        let parts = direction.components
        try validatePeerID(parts.proverID)
        try validatePeerID(parts.verifierID)
        try require(parts.nonce, count: 32, field: .authNonce)

        var input = ScAuthProofVerifyRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthProofVerifyRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.prover_id_length = try copyPeerID(parts.proverID, into: &input.prover_id)
        input.verifier_id_length = try copyPeerID(parts.verifierID, into: &input.verifier_id)
        input.reserved = (0, 0)
        try copyExact(secret, field: .pairSecret, into: &input.pair_secret)
        try copyExact(parts.nonce, field: .authNonce, into: &input.nonce)
        try copyExact(proof, field: .proof, into: &input.proof)
        defer { wipe(&input) }
        try requireOK(sc_auth_proof_verify_v1(&input))
    }

    func derivePairKey(privateScalar: Data, peerPublicKey: Data, salt: Data) throws -> Data {
        _ = RustAuthRuntime.verifiedABI
        try require(privateScalar, count: 32, field: .privateScalar)
        try require(peerPublicKey, count: 65, field: .publicKey)
        try require(salt, count: 16, field: .pairingSalt)
        var input = ScAuthPairKeyDeriveRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthPairKeyDeriveRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        try copyExact(privateScalar, field: .privateScalar, into: &input.private_scalar)
        try copyExact(peerPublicKey, field: .publicKey, into: &input.peer_public_key)
        try copyExact(salt, field: .pairingSalt, into: &input.pairing_salt)
        input.reserved = (0, 0, 0, 0, 0, 0, 0)
        defer { wipe(&input) }

        var output = ScAuthPairKeyV1()
        output.struct_size = UInt32(MemoryLayout<ScAuthPairKeyV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        try requireOK(sc_auth_pair_key_derive_v1(&input, &output))
        defer { wipe(&output) }
        return data(of: &output.pair_key)
    }

    func sealPairSecret(_ secret: Data, pairKey: Data, nonce: Data) throws -> Data {
        _ = RustAuthRuntime.verifiedABI
        try require(secret, count: 32, field: .pairSecret)
        try require(pairKey, count: 32, field: .pairKey)
        try require(nonce, count: 12, field: .aeadNonce)
        var input = ScAuthSealRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthSealRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        try copyExact(secret, field: .pairSecret, into: &input.pair_secret)
        try copyExact(pairKey, field: .pairKey, into: &input.pair_key)
        try copyExact(nonce, field: .aeadNonce, into: &input.nonce)
        input.reserved = (0, 0, 0, 0)
        defer { wipe(&input) }

        var output = ScAuthSealedPairSecretV1()
        output.struct_size = UInt32(MemoryLayout<ScAuthSealedPairSecretV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        try requireOK(sc_auth_pair_secret_seal_v1(&input, &output))
        defer { wipe(&output) }
        return data(of: &output.sealed_secret)
    }

    func openPairSecret(_ sealedSecret: Data, pairKey: Data, nonce: Data) throws -> Data {
        _ = RustAuthRuntime.verifiedABI
        try require(sealedSecret, count: 48, field: .sealedSecret)
        try require(pairKey, count: 32, field: .pairKey)
        try require(nonce, count: 12, field: .aeadNonce)
        var input = ScAuthOpenRequestV1()
        input.struct_size = UInt32(MemoryLayout<ScAuthOpenRequestV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        try copyExact(sealedSecret, field: .sealedSecret, into: &input.sealed_secret)
        try copyExact(pairKey, field: .pairKey, into: &input.pair_key)
        try copyExact(nonce, field: .aeadNonce, into: &input.nonce)
        input.reserved = (0, 0, 0, 0)
        defer { wipe(&input) }

        var output = ScAuthPairSecretV1()
        output.struct_size = UInt32(MemoryLayout<ScAuthPairSecretV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        try requireOK(sc_auth_pair_secret_open_v1(&input, &output))
        defer { wipe(&output) }
        return data(of: &output.pair_secret)
    }

    private func require(_ value: Data, count: Int, field: SessionAuthCryptoField) throws {
        guard value.count == count else { throw SessionAuthCryptoError.invalidLength(field) }
    }

    private func copyPeerID<T>(_ peerID: String, into destination: inout T) throws -> UInt32 {
        let bytes = Data(peerID.utf8)
        guard !bytes.isEmpty, bytes.count <= MemoryLayout<T>.size else {
            throw SessionAuthCryptoError.invalidPeerID
        }
        withUnsafeMutableBytes(of: &destination) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in
                buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        return UInt32(bytes.count)
    }

    private func copyExact<T>(
        _ value: Data,
        field: SessionAuthCryptoField,
        into destination: inout T
    ) throws {
        guard value.count == MemoryLayout<T>.size else {
            throw SessionAuthCryptoError.invalidLength(field)
        }
        value.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &destination) { buffer in
                buffer.copyMemory(from: source)
            }
        }
    }

    private func data<T>(of value: inout T) -> Data {
        withUnsafeBytes(of: &value) { Data($0) }
    }

    private func requireOK(_ status: ScStatus) throws {
        switch status {
        case Int32(SC_OK):
            return
        case Int32(SC_AUTHENTICATION_FAILED):
            throw SessionAuthCryptoError.authenticationFailed
        case Int32(SC_INVALID_ARGUMENT):
            throw SessionAuthCryptoError.invalidArgument
        default:
            throw SessionAuthCryptoError.internalFailure(status)
        }
    }

    private func wipe<T>(_ value: inout T) {
        withUnsafeMutableBytes(of: &value) { buffer in
            if let baseAddress = buffer.baseAddress {
                sc_mac_auth_zeroize(baseAddress, buffer.count)
            }
        }
    }
}

private enum RustAuthRuntime {
    static let verifiedABI: Void = {
        precondition(
            sc_mac_rust_auth_active_marker() == UInt32(SC_API_VERSION_V1),
            "Rust auth ABI version mismatch"
        )
    }()
}
