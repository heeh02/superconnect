import SuperconnectCoreFFI

extension PortableCapabilityIntentFFICodec {
    static func decodeSnapshot(
        _ value: ScCapabilityIntentSnapshotV2
    ) throws -> PortableCapabilityIntentSnapshot {
        guard value.struct_size == UInt32(MemoryLayout<ScCapabilityIntentSnapshotV2>.size),
              value.api_version == apiVersion,
              value.generation != 0,
              profileIsValid(value.product_capabilities),
              profileIsValid(value.peer_capabilities),
              let side = PortableCapabilityIntentSide(rawValue: value.side),
              let desiredPeerRole = PortableCapabilityIntentRole(rawValue: value.desired_peer_role),
              value.has_binding == 0 || value.has_binding == 1,
              value.binding_negotiated == 0 || value.binding_negotiated == 1,
              bytesAreZero(value.reserved0),
              value.reserved1 == 0
        else { throw invalidOutput() }

        let resolved = try decodeIntent(
            role: value.resolved_local_role,
            source: value.resolved_source_topology,
            sink: value.resolved_sink_presentation,
            input: value.resolved_input_policy,
            transport: value.resolved_transport_preference,
            topology: value.resolved_topology
        )
        let binding: PortableCapabilityIntentBinding?
        if value.has_binding == 1 {
            let bindingIntent = try decodeIntent(
                role: value.binding_local_role,
                source: value.binding_source_topology,
                sink: value.binding_sink_presentation,
                input: value.binding_input_policy,
                transport: value.binding_transport_preference,
                topology: value.binding_topology
            )
            guard bindingIntent == resolved,
                  let peerRole = PortableCapabilityIntentRole(rawValue: value.binding_peer_role),
                  peerRole == desiredPeerRole else { throw invalidOutput() }
            binding = PortableCapabilityIntentBinding(
                localIntent: bindingIntent,
                peerRole: peerRole,
                negotiated: value.binding_negotiated == 1
            )
        } else {
            guard value.binding_negotiated == 0,
                  value.binding_local_role == 0,
                  value.binding_source_topology == 0,
                  value.binding_sink_presentation == 0,
                  value.binding_input_policy == 0,
                  value.binding_transport_preference == 0,
                  value.binding_topology == 0,
                  value.binding_peer_role == 0 else { throw invalidOutput() }
            binding = nil
        }
        return PortableCapabilityIntentSnapshot(
            generation: value.generation,
            productCapabilities: value.product_capabilities,
            peerCapabilities: value.peer_capabilities,
            side: side,
            desiredPeerRole: desiredPeerRole,
            resolvedIntent: resolved,
            binding: binding
        )
    }

    static func decodeIntent(
        _ value: ScCapabilityIntentEffectV2
    ) throws -> PortableCapabilityIntentResolved {
        try decodeIntent(
            role: value.resolved_local_role,
            source: value.resolved_source_topology,
            sink: value.resolved_sink_presentation,
            input: value.resolved_input_policy,
            transport: value.resolved_transport_preference,
            topology: value.resolved_topology
        )
    }

    private static func decodeIntent(
        role: UInt8,
        source: UInt8,
        sink: UInt8,
        input: UInt8,
        transport: UInt8,
        topology: UInt8
    ) throws -> PortableCapabilityIntentResolved {
        guard let localRole = PortableCapabilityIntentRole(rawValue: role),
              let sourceTopology = PortableCapabilityIntentSourceTopology(rawValue: source),
              let sinkPresentation = PortableCapabilityIntentSinkPresentation(rawValue: sink),
              let inputPolicy = PortableCapabilityIntentInputPolicy(rawValue: input),
              let transportPreference = PortableCapabilityIntentTransport(rawValue: transport),
              let collaborationTopology = PortableCapabilityIntentTopology(rawValue: topology),
              localRole != .relay || collaborationTopology == .relayed
        else { throw invalidOutput() }
        return PortableCapabilityIntentResolved(
            localRole: localRole,
            sourceTopology: sourceTopology,
            sinkPresentation: sinkPresentation,
            inputPolicy: inputPolicy,
            transportPreference: transportPreference,
            topology: collaborationTopology
        )
    }

    private static func profileIsValid(_ bits: UInt64) -> Bool {
        let known: UInt64 = 0x7 | 0x0f00 | 0x0007_0000 | 0x0700_0000
            | 0x0000_0007_0000_0000 | 0x0000_0700_0000_0000
        let masks: [UInt64] = [
            0x7,
            0x0f00,
            0x0007_0000,
            0x0700_0000,
            0x0000_0007_0000_0000,
            0x0000_0700_0000_0000,
        ]
        return bits & ~known == 0 && masks.allSatisfy { bits & $0 != 0 }
    }

    private static func bytesAreZero<T>(_ value: T) -> Bool {
        withUnsafeBytes(of: value) { bytes in bytes.allSatisfy { $0 == 0 } }
    }

    static func invalidOutput() -> PortableCapabilityIntentError {
        .ffiStatus(Int32(SC_INTERNAL_ERROR))
    }
}
