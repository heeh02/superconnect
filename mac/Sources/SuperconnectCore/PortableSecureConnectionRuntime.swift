import Foundation
import SuperconnectCoreFFI

/// Single-owner binding for Auth -> Record -> Capability -> Ready composition and data routing.
public final class PortableSecureConnectionRuntime {
    public let configuration: PortableSessionConfiguration
    public var generation: PortableSessionGeneration { configuration.generation }
    public var localEnrollmentKey: PortableSessionArtifactID { configuration.localEnrollmentKey }

    var handle: OpaquePointer?

    public init(configuration: PortableSessionConfiguration) throws {
        self.configuration = configuration
        guard sc_mac_rust_secure_connection_active_marker() == UInt32(SC_API_VERSION_V1) else {
            throw PortableSecureConnectionError.coreUnavailable
        }
        var input = ScSecureConnectionConfigV1()
        input.struct_size = UInt32(MemoryLayout<ScSecureConnectionConfigV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.session = PortableSessionFFICodec.encodeConfiguration(configuration)
        var created: OpaquePointer?
        let status = sc_secure_connection_new_v1(&input, &created)
        guard status == SC_OK, let created else { throw Self.failure(status) }
        handle = created
        do {
            _ = try snapshot()
        } catch {
            handle = nil
            precondition(sc_secure_connection_free_v1(created) == SC_OK)
            throw error
        }
    }

    deinit {
        if let handle { precondition(sc_secure_connection_free_v1(handle) == SC_OK) }
    }

    public func observeRecordVersion(_ value: Int?) throws -> [PortableSecureConnectionEffect] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        let version: UInt16
        if let value {
            guard let exact = UInt16(exactly: value), exact != 0 else {
                throw PortableSecureConnectionError.invalidRecordVersion
            }
            version = exact
        } else {
            version = 0
        }
        let status = sc_secure_connection_observe_record_version_v1(
            handle, generation.rawValue, version)
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeEffects()
    }

    public func apply(_ event: PortableSessionEvent) throws -> [PortableSecureConnectionEffect] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        var input = PortableSessionFFICodec.encodeEvent(event, generation: generation)
        let status = sc_secure_connection_apply_session_v1(handle, &input)
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeEffects()
    }

    public func recordMaterialPrepared(
        operation: PortableSessionOperationID,
        secret: Data?,
        responderChallenge: Data?,
        initiatorChallenge: Data?
    ) throws -> [PortableSecureConnectionEffect] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        let success = secret != nil || responderChallenge != nil || initiatorChallenge != nil
        if success {
            guard secret?.count == 32, responderChallenge?.count == 32,
                  initiatorChallenge?.count == 32 else {
                throw PortableSecureConnectionError.invalidRecordMaterial
            }
        }
        var input = ScSecureRecordMaterialV1()
        input.struct_size = UInt32(MemoryLayout<ScSecureRecordMaterialV1>.size)
        input.api_version = UInt32(SC_API_VERSION_V1)
        input.generation = generation.rawValue
        input.operation = operation.rawValue
        input.success = success ? 1 : 0
        if let secret, let responderChallenge, let initiatorChallenge {
            withUnsafeMutableBytes(of: &input) { output in
                Self.copy(secret, to: output, offset: 32)
                Self.copy(responderChallenge, to: output, offset: 64)
                Self.copy(initiatorChallenge, to: output, offset: 96)
            }
        }
        defer {
            _ = withUnsafeMutableBytes(of: &input) {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        let status = sc_secure_connection_record_material_prepared_v1(handle, &input)
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeEffects()
    }

    public func recordsActivated(
        operation: PortableSessionOperationID,
        success: Bool
    ) throws -> [PortableSecureConnectionEffect] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        let status = sc_secure_connection_records_activated_v1(
            handle, generation.rawValue, operation.rawValue, success ? 1 : 0)
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeEffects()
    }

    public func takeEffects() throws -> [PortableSecureConnectionEffect] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        var result = [PortableSecureConnectionEffect]()
        while true {
            var value = ScSecureConnectionEffectV1()
            value.struct_size = UInt32(MemoryLayout<ScSecureConnectionEffectV1>.size)
            value.api_version = UInt32(SC_API_VERSION_V1)
            let status = sc_secure_connection_pop_effect_v1(handle, &value)
            if status == SC_NO_FRAME { return result }
            guard status == SC_OK else { throw Self.failure(status) }
            result.append(try decodeEffect(value))
        }
    }

    public func snapshot() throws -> PortableSecureConnectionSnapshot {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        var value = ScSecureConnectionSnapshotV1()
        value.struct_size = UInt32(MemoryLayout<ScSecureConnectionSnapshotV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        let status = sc_secure_connection_snapshot_v1(handle, &value)
        guard status == SC_OK else { throw Self.failure(status) }
        guard value.struct_size == UInt32(MemoryLayout<ScSecureConnectionSnapshotV1>.size),
              value.api_version == UInt32(SC_API_VERSION_V1),
              value.generation == generation.rawValue,
              let generation = PortableSessionGeneration(rawValue: value.generation),
              let phase = PortableSessionPhase(rawValue: value.session_phase),
              value.records_active <= 1, value.records_required <= 1,
              value.invariants_hold == 1, value.inbound_view_outstanding <= 1,
              value.reserved0 == 0, value.reserved1 == 0 else {
            throw PortableSecureConnectionError.malformedSnapshot
        }
        return .init(
            generation: generation, sessionPhase: phase, recordPhase: value.record_phase,
            recordsActive: value.records_active == 1,
            recordsRequired: value.records_required == 1,
            invariantsHold: true, pendingEffectCount: value.pending_effect_count,
            pendingInboundCount: value.pending_inbound_count,
            inboundViewOutstanding: value.inbound_view_outstanding == 1)
    }

    public func phase() throws -> PortableSessionPhase { try snapshot().sessionPhase }
}

extension PortableSecureConnectionRuntime {
    func decodeEffect(_ input: ScSecureConnectionEffectV1) throws
        -> PortableSecureConnectionEffect {
        guard input.struct_size == UInt32(MemoryLayout<ScSecureConnectionEffectV1>.size),
              input.api_version == UInt32(SC_API_VERSION_V1), input.reserved0 == 0,
              input.reserved1 == 0, input.reserved2 == 0 else {
            throw PortableSecureConnectionError.malformedEffect
        }
        let sessionBytesAreZero = withUnsafeBytes(of: input.session_effect) {
            $0.allSatisfy { $0 == 0 }
        }
        switch input.type {
        case UInt32(SC_SECURE_CONNECTION_EFFECT_SESSION_V1):
            guard input.generation == 0, input.operation == 0 else {
                throw PortableSecureConnectionError.malformedEffect
            }
            return .session(try PortableSessionFFICodec.decodeEffect(input.session_effect))
        case UInt32(SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1),
             UInt32(SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1):
            guard sessionBytesAreZero,
                  let generation = PortableSessionGeneration(rawValue: input.generation),
                  let operation = PortableSessionOperationID(rawValue: input.operation) else {
                throw PortableSecureConnectionError.malformedEffect
            }
            if input.type == UInt32(SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1) {
                return .prepareRecordContext(generation: generation, operation: operation)
            }
            return .activateRecords(generation: generation, operation: operation)
        case UInt32(SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1):
            guard sessionBytesAreZero, input.operation == 0,
                  let generation = PortableSessionGeneration(rawValue: input.generation) else {
                throw PortableSecureConnectionError.malformedEffect
            }
            return .disposeRecords(generation: generation)
        default:
            throw PortableSecureConnectionError.malformedEffect
        }
    }

    static func copy(_ data: Data, to output: UnsafeMutableRawBufferPointer, offset: Int) {
        precondition(offset >= 0 && offset + data.count <= output.count)
        data.withUnsafeBytes { input in
            output.baseAddress!.advanced(by: offset).copyMemory(
                from: input.baseAddress!, byteCount: input.count)
        }
    }

    static func failure(_ status: ScStatus) -> PortableSecureConnectionError {
        .coreFailure(Int32(status))
    }
}
