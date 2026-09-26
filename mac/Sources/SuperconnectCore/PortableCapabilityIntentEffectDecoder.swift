import SuperconnectCoreFFI

extension PortableCapabilityIntentFFICodec {
    static func decodeEffect(
        _ value: ScCapabilityIntentEffectV2
    ) throws -> PortableCapabilityIntentEffect {
        guard validEffectHeader(value) else { throw invalidOutput() }
        switch value.effect_type {
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_SEND_OFFER):
            return .send(try decodeMessage(value, kind: .offer))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_SEND_SELECTION):
            return .send(try decodeMessage(value, kind: .selection))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_SEND_COMMIT):
            return .send(try decodeMessage(value, kind: .commit))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_COMMITTED):
            return .committed(try decodeBinding(value))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_CONNECTED):
            return .connected(try decodeBinding(value))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_REJECTED):
            return .rejected(try decodeRejected(value))
        case UInt8(SC_CAPABILITY_INTENT_EFFECT_FATAL):
            return .fatal(try decodeFatal(value))
        default:
            throw invalidOutput()
        }
    }

    private static func decodeMessage(
        _ value: ScCapabilityIntentEffectV2,
        kind: PortableCapabilityIntentMessageKind
    ) throws -> PortableCapabilityIntentMessage {
        guard value.negotiation_version == 2,
              value.reason == UInt8(SC_CAPABILITY_INTENT_REASON_NONE),
              value.expected_generation == 0, value.received_generation == 0,
              value.expected_version == 0, value.received_version == 0,
              value.local_role == 0, value.peer_role == 0, value.negotiated == 0,
              mismatchFieldsAreZero(value),
              let offerer = PortableCapabilityIntentRole(rawValue: value.offerer_role),
              let selector = PortableCapabilityIntentRole(rawValue: value.selector_role),
              let projection = PortableCapabilityIntentSourceTopology(rawValue: value.projection),
              let transport = PortableCapabilityIntentTransport(rawValue: value.transport)
        else { throw invalidOutput() }
        let intent = try decodeIntent(value)
        guard projection == intent.sourceTopology,
              transport == intent.transportPreference else { throw invalidOutput() }
        return PortableCapabilityIntentMessage(
            kind: kind,
            generation: value.generation,
            negotiationVersion: value.negotiation_version,
            offererRole: offerer,
            selectorRole: selector,
            projection: projection,
            transport: transport,
            resolvedIntent: intent
        )
    }

    private static func decodeBinding(
        _ value: ScCapabilityIntentEffectV2
    ) throws -> PortableCapabilityIntentBinding {
        guard value.negotiation_version == 0,
              value.reason == UInt8(SC_CAPABILITY_INTENT_REASON_NONE),
              value.expected_generation == 0, value.received_generation == 0,
              value.expected_version == 0, value.received_version == 0,
              value.offerer_role == 0, value.selector_role == 0,
              value.negotiated == 0 || value.negotiated == 1,
              mismatchFieldsAreZero(value),
              let localRole = PortableCapabilityIntentRole(rawValue: value.local_role),
              let peerRole = PortableCapabilityIntentRole(rawValue: value.peer_role),
              let projection = PortableCapabilityIntentSourceTopology(rawValue: value.projection),
              let transport = PortableCapabilityIntentTransport(rawValue: value.transport)
        else { throw invalidOutput() }
        let intent = try decodeIntent(value)
        guard localRole == intent.localRole,
              projection == intent.sourceTopology,
              transport == intent.transportPreference else { throw invalidOutput() }
        return PortableCapabilityIntentBinding(
            localIntent: intent,
            peerRole: peerRole,
            negotiated: value.negotiated == 1
        )
    }

    private static func decodeRejected(
        _ value: ScCapabilityIntentEffectV2
    ) throws -> PortableCapabilityIntentRejected {
        guard semanticPayloadIsZero(value), mismatchFieldsAreZero(value) else {
            throw invalidOutput()
        }
        switch value.reason {
        case UInt8(SC_CAPABILITY_INTENT_REASON_OUT_OF_ORDER):
            guard value.expected_generation == 0, value.received_generation == 0 else {
                throw invalidOutput()
            }
            return .outOfOrder
        case UInt8(SC_CAPABILITY_INTENT_REASON_STALE_GENERATION):
            guard value.expected_generation != 0, value.received_generation != 0 else {
                throw invalidOutput()
            }
            return .staleGeneration(
                expected: value.expected_generation,
                received: value.received_generation
            )
        default:
            throw invalidOutput()
        }
    }

    private static func decodeFatal(
        _ value: ScCapabilityIntentEffectV2
    ) throws -> PortableCapabilityIntentFatal {
        guard semanticPayloadIsZero(value),
              value.expected_generation == 0, value.received_generation == 0 else {
            throw invalidOutput()
        }
        switch value.reason {
        case UInt8(SC_CAPABILITY_INTENT_REASON_UNSUPPORTED_VERSION):
            guard roleProjectionTransportMismatchFieldsAreZero(value),
                  value.expected_version != 0 else { throw invalidOutput() }
            return .unsupportedVersion(
                expected: value.expected_version,
                received: value.received_version
            )
        case UInt8(SC_CAPABILITY_INTENT_REASON_ROLE_MISMATCH):
            guard versionProjectionTransportMismatchFieldsAreZero(value),
                  let expected = PortableCapabilityIntentRole(rawValue: value.expected_role),
                  let received = PortableCapabilityIntentRole(rawValue: value.received_role)
            else { throw invalidOutput() }
            return .roleMismatch(expected: expected, received: received)
        case UInt8(SC_CAPABILITY_INTENT_REASON_PROJECTION_MISMATCH):
            guard versionRoleTransportMismatchFieldsAreZero(value),
                  let expected = PortableCapabilityIntentSourceTopology(
                    rawValue: value.expected_projection
                  ),
                  let received = PortableCapabilityIntentSourceTopology(
                    rawValue: value.received_projection
                  ) else { throw invalidOutput() }
            return .projectionMismatch(expected: expected, received: received)
        case UInt8(SC_CAPABILITY_INTENT_REASON_TRANSPORT_MISMATCH):
            guard versionRoleProjectionMismatchFieldsAreZero(value),
                  let expected = PortableCapabilityIntentTransport(
                    rawValue: value.expected_transport
                  ),
                  let received = PortableCapabilityIntentTransport(
                    rawValue: value.received_transport
                  ) else { throw invalidOutput() }
            return .transportMismatch(expected: expected, received: received)
        case UInt8(SC_CAPABILITY_INTENT_REASON_INTENT_MISMATCH):
            guard mismatchFieldsAreZero(value) else { throw invalidOutput() }
            return .intentMismatch
        case UInt8(SC_CAPABILITY_INTENT_REASON_COMMIT_MISMATCH):
            guard mismatchFieldsAreZero(value) else { throw invalidOutput() }
            return .commitMismatch
        case UInt8(SC_CAPABILITY_INTENT_REASON_LEGACY_INTENT_MISMATCH):
            guard mismatchFieldsAreZero(value) else { throw invalidOutput() }
            return .legacyIntentMismatch
        default:
            throw invalidOutput()
        }
    }

    private static func validEffectHeader(_ value: ScCapabilityIntentEffectV2) -> Bool {
        value.struct_size == UInt32(MemoryLayout<ScCapabilityIntentEffectV2>.size)
            && value.api_version == apiVersion
            && value.generation != 0
            && value.reserved0 == 0
            && value.reserved1 == 0
            && value.reserved2 == 0
    }

    private static func semanticPayloadIsZero(_ value: ScCapabilityIntentEffectV2) -> Bool {
        value.negotiation_version == 0
            && value.offerer_role == 0 && value.selector_role == 0
            && value.local_role == 0 && value.peer_role == 0
            && value.projection == 0 && value.transport == 0 && value.negotiated == 0
            && value.resolved_local_role == 0 && value.resolved_source_topology == 0
            && value.resolved_sink_presentation == 0 && value.resolved_input_policy == 0
            && value.resolved_transport_preference == 0 && value.resolved_topology == 0
    }

    private static func mismatchFieldsAreZero(_ value: ScCapabilityIntentEffectV2) -> Bool {
        value.expected_version == 0 && value.received_version == 0
            && roleProjectionTransportMismatchFieldsAreZero(value)
    }

    private static func roleProjectionTransportMismatchFieldsAreZero(
        _ value: ScCapabilityIntentEffectV2
    ) -> Bool {
        value.expected_role == 0 && value.received_role == 0
            && value.expected_projection == 0 && value.received_projection == 0
            && value.expected_transport == 0 && value.received_transport == 0
    }

    private static func versionProjectionTransportMismatchFieldsAreZero(
        _ value: ScCapabilityIntentEffectV2
    ) -> Bool {
        value.expected_version == 0 && value.received_version == 0
            && value.expected_projection == 0 && value.received_projection == 0
            && value.expected_transport == 0 && value.received_transport == 0
    }

    private static func versionRoleTransportMismatchFieldsAreZero(
        _ value: ScCapabilityIntentEffectV2
    ) -> Bool {
        value.expected_version == 0 && value.received_version == 0
            && value.expected_role == 0 && value.received_role == 0
            && value.expected_transport == 0 && value.received_transport == 0
    }

    private static func versionRoleProjectionMismatchFieldsAreZero(
        _ value: ScCapabilityIntentEffectV2
    ) -> Bool {
        value.expected_version == 0 && value.received_version == 0
            && value.expected_role == 0 && value.received_role == 0
            && value.expected_projection == 0 && value.received_projection == 0
    }
}
