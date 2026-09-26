import SuperconnectCoreFFI

extension PortableSessionFFICodec {
    static func decodeSnapshot(
        _ input: ScSessionSnapshotV1,
        configuration: PortableSessionConfiguration
    ) throws -> PortableSessionSnapshot {
        guard input.struct_size == UInt32(MemoryLayout<ScSessionSnapshotV1>.size),
              input.api_version == UInt32(SC_API_VERSION_V1),
              input.reserved0 == 0, input.reserved1 == 0, input.reserved2 == 0,
              input.invariants_hold == 1,
              input.pending_timer_count <= 1,
              input.pending_operation_count <= 1,
              let generation = PortableSessionGeneration(rawValue: input.generation),
              let firstOperation = PortableSessionOperationID(rawValue: input.first_operation_id),
              let localKey = PortableSessionArtifactID(rawValue: input.local_enrollment_key),
              let phase = PortableSessionPhase(rawValue: input.phase),
              let side = PortableSessionSide(rawValue: input.side),
              let mediaRole = PortableSessionMediaRole(rawValue: input.media_role),
              let origin = PortableSessionOrigin(rawValue: input.origin) else {
            throw PortableSessionError.malformedSnapshot
        }
        let identity: PortableSessionIdentity
        do { identity = try decodeIdentity(input.local_identity) }
        catch { throw PortableSessionError.malformedSnapshot }
        guard generation == configuration.generation,
              firstOperation == configuration.firstOperationID,
              localKey == configuration.localEnrollmentKey,
              side == configuration.side,
              mediaRole == configuration.mediaRole,
              origin == configuration.origin,
              identity == configuration.localIdentity else {
            throw PortableSessionError.malformedSnapshot
        }
        return PortableSessionSnapshot(
            generation: generation,
            firstOperationID: firstOperation,
            localEnrollmentKey: localKey,
            phase: phase,
            side: side,
            mediaRole: mediaRole,
            origin: origin,
            pendingTimerCount: input.pending_timer_count,
            pendingOperationCount: input.pending_operation_count,
            invariantsHold: true,
            localIdentity: identity
        )
    }
}
