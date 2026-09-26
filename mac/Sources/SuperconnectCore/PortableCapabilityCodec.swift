import SuperconnectCoreFFI

enum PortableCapabilityCodec {
    static func configuration(
        _ value: PortableCapabilityConfiguration
    ) -> ScCapabilityConfigV1 {
        var output = ScCapabilityConfigV1()
        output.struct_size = UInt32(MemoryLayout<ScCapabilityConfigV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        output.generation = value.generation.rawValue
        output.authorized_capabilities = value.authorizedCapabilities.rawValue
        output.side = value.side.rawValue
        output.local_role = value.localRole.rawValue
        output.desired_peer_role = value.desiredPeerRole.rawValue
        output.projection = value.projection.rawValue
        output.transport = value.transport.rawValue
        return output
    }

    static func event(
        _ value: PortableCapabilityEvent,
        runtimeGeneration: PortableCapabilityGeneration
    ) -> ScCapabilityEventV1 {
        var output = ScCapabilityEventV1()
        output.struct_size = UInt32(MemoryLayout<ScCapabilityEventV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        output.generation = runtimeGeneration.rawValue
        switch value {
        case .peerHello(let version):
            output.event_type = UInt8(SC_CAPABILITY_EVENT_PEER_HELLO)
            if let version {
                output.has_negotiation_version = 1
                output.negotiation_version = version
            }
        case .message(let message):
            output.generation = message.generation.rawValue
            output.event_type = message.kind.rawValue + 1
            output.has_negotiation_version = 1
            output.negotiation_version = message.negotiationVersion
            output.capabilities = message.authorizedCapabilities.rawValue
            output.offerer_role = message.offererRole.rawValue
            output.selector_role = message.selectorRole.rawValue
            output.projection = message.projection.rawValue
            output.transport = message.transport.rawValue
        }
        return output
    }

    static func effect(_ value: ScCapabilityEffectV1) throws -> PortableCapabilityEffect {
        guard value.struct_size == UInt32(MemoryLayout<ScCapabilityEffectV1>.size),
              value.api_version == UInt32(SC_API_VERSION_V1),
              let generation = PortableCapabilityGeneration(rawValue: value.generation) else {
            throw PortableCapabilityError.malformedEffect
        }
        switch value.effect_type {
        case UInt8(SC_CAPABILITY_EFFECT_SEND_OFFER),
             UInt8(SC_CAPABILITY_EFFECT_SEND_SELECTION),
             UInt8(SC_CAPABILITY_EFFECT_SEND_COMMIT):
            return .send(try message(value, generation: generation))
        case UInt8(SC_CAPABILITY_EFFECT_COMMITTED),
             UInt8(SC_CAPABILITY_EFFECT_CONNECTED):
            let binding = try binding(value, generation: generation)
            return value.effect_type == UInt8(SC_CAPABILITY_EFFECT_COMMITTED)
                ? .committed(binding) : .connected(binding)
        case UInt8(SC_CAPABILITY_EFFECT_REJECTED):
            return .rejected(try rejection(value))
        case UInt8(SC_CAPABILITY_EFFECT_FATAL):
            return .fatal(try fatal(value))
        default:
            throw PortableCapabilityError.malformedEffect
        }
    }

    static func snapshot(_ value: ScCapabilitySnapshotV1) throws
        -> PortableCapabilitySnapshot {
        guard value.struct_size == UInt32(MemoryLayout<ScCapabilitySnapshotV1>.size),
              value.api_version == UInt32(SC_API_VERSION_V1),
              let generation = PortableCapabilityGeneration(rawValue: value.generation),
              let side = PortableCapabilitySide(rawValue: value.side),
              let localRole = PortableCapabilityRole(rawValue: value.local_role),
              let peerRole = PortableCapabilityRole(rawValue: value.desired_peer_role),
              let projection = PortableCapabilityProjection(rawValue: value.projection),
              let transport = PortableCapabilityTransport(rawValue: value.transport),
              knownAuthorization(value.authorized_capabilities) != nil,
              value.has_binding == 0 || value.has_binding == 1 else {
            throw PortableCapabilityError.malformedSnapshot
        }
        let binding: PortableCapabilityBinding?
        if value.has_binding == 1 {
            guard let bindingLocal = PortableCapabilityRole(rawValue: value.binding_local_role),
                  let bindingPeer = PortableCapabilityRole(rawValue: value.binding_peer_role),
                  let bindingProjection = PortableCapabilityProjection(
                    rawValue: value.binding_projection),
                  let bindingTransport = PortableCapabilityTransport(
                    rawValue: value.binding_transport),
                  value.binding_negotiated == 0 || value.binding_negotiated == 1 else {
                throw PortableCapabilityError.malformedSnapshot
            }
            binding = PortableCapabilityBinding(
                generation: generation,
                localRole: bindingLocal,
                peerRole: bindingPeer,
                projection: bindingProjection,
                transport: bindingTransport,
                negotiated: value.binding_negotiated == 1
            )
        } else {
            binding = nil
        }
        return PortableCapabilitySnapshot(
            generation: generation,
            authorizedCapabilities: .init(rawValue: value.authorized_capabilities),
            side: side,
            localRole: localRole,
            desiredPeerRole: peerRole,
            projection: projection,
            transport: transport,
            binding: binding
        )
    }
}

private extension PortableCapabilityCodec {
    static func message(
        _ value: ScCapabilityEffectV1,
        generation: PortableCapabilityGeneration
    ) throws -> PortableCapabilityMessage {
        guard let kind = PortableCapabilityMessageKind(rawValue: value.effect_type),
              let authorization = knownAuthorization(value.capabilities),
              let offerer = PortableCapabilityRole(rawValue: value.offerer_role),
              let selector = PortableCapabilityRole(rawValue: value.selector_role),
              let projection = PortableCapabilityProjection(rawValue: value.projection),
              let transport = PortableCapabilityTransport(rawValue: value.transport) else {
            throw PortableCapabilityError.malformedEffect
        }
        return PortableCapabilityMessage(
            kind: kind,
            generation: generation,
            negotiationVersion: value.negotiation_version,
            authorizedCapabilities: authorization,
            offererRole: offerer,
            selectorRole: selector,
            projection: projection,
            transport: transport
        )
    }

    static func binding(
        _ value: ScCapabilityEffectV1,
        generation: PortableCapabilityGeneration
    ) throws -> PortableCapabilityBinding {
        guard let local = PortableCapabilityRole(rawValue: value.local_role),
              let peer = PortableCapabilityRole(rawValue: value.peer_role),
              let projection = PortableCapabilityProjection(rawValue: value.projection),
              let transport = PortableCapabilityTransport(rawValue: value.transport),
              value.negotiated == 0 || value.negotiated == 1 else {
            throw PortableCapabilityError.malformedEffect
        }
        return PortableCapabilityBinding(
            generation: generation,
            localRole: local,
            peerRole: peer,
            projection: projection,
            transport: transport,
            negotiated: value.negotiated == 1
        )
    }

    static func rejection(_ value: ScCapabilityEffectV1) throws
        -> PortableCapabilityRejection {
        switch value.reason {
        case UInt8(SC_CAPABILITY_REASON_OUT_OF_ORDER):
            return .outOfOrder
        case UInt8(SC_CAPABILITY_REASON_STALE_GENERATION):
            guard let expected = PortableCapabilityGeneration(
                    rawValue: value.expected_generation),
                  let received = PortableCapabilityGeneration(
                    rawValue: value.received_generation) else {
                throw PortableCapabilityError.malformedEffect
            }
            return .staleGeneration(expected: expected, received: received)
        default:
            throw PortableCapabilityError.malformedEffect
        }
    }

    static func fatal(_ value: ScCapabilityEffectV1) throws -> PortableCapabilityFatalReason {
        switch value.reason {
        case UInt8(SC_CAPABILITY_REASON_UNSUPPORTED_VERSION):
            return .unsupportedVersion(
                expected: value.expected_version,
                received: value.received_version
            )
        case UInt8(SC_CAPABILITY_REASON_UNSUPPORTED_CAPABILITY):
            guard let capability = PortableCapabilityID(rawValue: value.capability) else {
                throw PortableCapabilityError.malformedEffect
            }
            return .unsupportedCapability(capability)
        case UInt8(SC_CAPABILITY_REASON_ROLE_MISMATCH):
            guard let expected = PortableCapabilityRole(rawValue: value.expected_role),
                  let received = PortableCapabilityRole(rawValue: value.received_role) else {
                throw PortableCapabilityError.malformedEffect
            }
            return .roleMismatch(expected: expected, received: received)
        case UInt8(SC_CAPABILITY_REASON_PROJECTION_MISMATCH):
            guard let expected = PortableCapabilityProjection(
                    rawValue: value.expected_projection),
                  let received = PortableCapabilityProjection(
                    rawValue: value.received_projection) else {
                throw PortableCapabilityError.malformedEffect
            }
            return .projectionMismatch(expected: expected, received: received)
        case UInt8(SC_CAPABILITY_REASON_COMMIT_MISMATCH):
            return .commitMismatch
        default:
            throw PortableCapabilityError.malformedEffect
        }
    }

    static func knownAuthorization(_ rawValue: UInt64)
        -> PortableCapabilityAuthorization? {
        guard rawValue & ~PortableCapabilityAuthorization.known.rawValue == 0 else {
            return nil
        }
        return .init(rawValue: rawValue)
    }
}
