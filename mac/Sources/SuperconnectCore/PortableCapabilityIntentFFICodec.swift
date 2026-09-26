import Foundation
import SuperconnectCoreFFI

enum PortableCapabilityIntentFFICodec {
    static let apiVersion = UInt32(SC_CAPABILITY_INTENT_API_VERSION_V2)

    static func encodeConfig(
        _ config: PortableCapabilityIntentConfig
    ) -> ScCapabilityIntentConfigV2 {
        var value = ScCapabilityIntentConfigV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentConfigV2>.size)
        value.api_version = apiVersion
        value.generation = config.generation
        value.product_capabilities = config.productCapabilities
        value.peer_capabilities = config.peerCapabilities
        value.side = config.side.rawValue
        value.desired_peer_role = config.desiredPeerRole.rawValue
        value.local_role = config.intent.localRole.rawValue
        value.source_topology = config.intent.sourceTopology.rawValue
        value.sink_presentation = config.intent.sinkPresentation.rawValue
        value.input_policy = config.intent.inputPolicy.rawValue
        value.transport_preference = config.intent.transportPreference.rawValue
        value.topology = config.intent.topology.rawValue
        value.reserved = 0
        return value
    }

    static func encodeEvent(
        _ event: PortableCapabilityIntentEvent
    ) -> ScCapabilityIntentEventV2 {
        var value = ScCapabilityIntentEventV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentEventV2>.size)
        value.api_version = apiVersion
        switch event {
        case let .peerHello(generation, negotiationVersion):
            value.generation = generation
            value.event_type = UInt8(SC_CAPABILITY_INTENT_EVENT_PEER_HELLO)
            if let negotiationVersion {
                value.has_negotiation_version = 1
                value.negotiation_version = negotiationVersion
            }
        case let .message(message):
            value.generation = message.generation
            value.negotiation_version = message.negotiationVersion
            value.event_type = eventType(message.kind)
            value.has_negotiation_version = 1
            value.offerer_role = message.offererRole.rawValue
            value.selector_role = message.selectorRole.rawValue
            value.projection = message.projection.rawValue
            value.transport = message.transport.rawValue
            value.local_role = message.resolvedIntent.localRole.rawValue
            value.source_topology = message.resolvedIntent.sourceTopology.rawValue
            value.sink_presentation = message.resolvedIntent.sinkPresentation.rawValue
            value.input_policy = message.resolvedIntent.inputPolicy.rawValue
            value.transport_preference = message.resolvedIntent.transportPreference.rawValue
            value.topology = message.resolvedIntent.topology.rawValue
        }
        return value
    }

    static func encodeWire(_ message: PortableCapabilityIntentMessage) throws -> Data {
        var value = encodeEvent(.message(message))
        return try encoded(
            maxBytes: PortableCapabilityIntentWireCodec.maxBytes,
            call: { sc_capability_intent_wire_encode_v2(&value, $0, $1, $2) },
            failure: { $0 == SC_INVALID_ARGUMENT ? PortableCapabilityIntentWireError.invariantViolation
                : PortableCapabilityIntentWireError.coreFailure(Int32($0)) }
        )
    }
    static func decodeWire(_ data: Data) throws -> PortableCapabilityIntentMessage {
        guard data.count <= PortableCapabilityIntentWireCodec.maxBytes else {
            throw PortableCapabilityIntentWireError.tooLarge }
        var value = ScCapabilityIntentEventV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentEventV2>.size)
        value.api_version = apiVersion
        let status = data.withUnsafeBytes {
            sc_capability_intent_wire_decode_v2(
                $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &value
            )
        }
        guard status == SC_OK else { throw status == SC_INVALID_ARGUMENT
            ? PortableCapabilityIntentWireError.invalidValue
            : PortableCapabilityIntentWireError.coreFailure(Int32(status)) }
        guard value.struct_size == UInt32(MemoryLayout<ScCapabilityIntentEventV2>.size),
              value.api_version == apiVersion, value.has_negotiation_version == 1,
              value.negotiation_version == PortableCapabilityIntentWireCodec.negotiationVersion,
              value.reserved1 == 0, zero(value.reserved0),
              let kind = messageKind(value.event_type),
              let offerer = PortableCapabilityIntentRole(rawValue: value.offerer_role),
              let selector = PortableCapabilityIntentRole(rawValue: value.selector_role),
              let projection = PortableCapabilityIntentSourceTopology(rawValue: value.projection),
              let transport = PortableCapabilityIntentTransport(rawValue: value.transport),
              let local = PortableCapabilityIntentRole(rawValue: value.local_role),
              let source = PortableCapabilityIntentSourceTopology(rawValue: value.source_topology),
              let sink = PortableCapabilityIntentSinkPresentation(rawValue: value.sink_presentation),
              let input = PortableCapabilityIntentInputPolicy(rawValue: value.input_policy),
              let preferred = PortableCapabilityIntentTransport(rawValue: value.transport_preference),
              let topology = PortableCapabilityIntentTopology(rawValue: value.topology) else {
            throw PortableCapabilityIntentWireError.invalidValue
        }
        return .init(
            kind: kind, generation: value.generation,
            negotiationVersion: value.negotiation_version,
            offererRole: offerer, selectorRole: selector,
            projection: projection, transport: transport,
            resolvedIntent: .init(
                localRole: local, sourceTopology: source, sinkPresentation: sink,
                inputPolicy: input, transportPreference: preferred, topology: topology
            )
        )
    }
    static func encodeProfileWire(_ message: PortableCapabilityIntentProductAdvertisement) throws -> Data {
        var value = ScCapabilityIntentProfileV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentProfileV2>.size)
        value.api_version = apiVersion
        value.generation = message.generation
        value.capabilities = message.capabilityBits
        value.sender_role = message.senderRole.rawValue
        return try encoded(
            maxBytes: PortableCapabilityIntentProfileWireCodec.maxBytes,
            call: { sc_capability_intent_profile_wire_encode_v2(&value, $0, $1, $2) },
            failure: { $0 == SC_INVALID_ARGUMENT
                ? PortableCapabilityIntentProfileWireError.invariantViolation :
                PortableCapabilityIntentProfileWireError.coreFailure(Int32($0)) }
        )
    }
    static func decodeProfileWire(_ data: Data) throws -> PortableCapabilityIntentPeerAdvertisement {
        guard data.count <= PortableCapabilityIntentProfileWireCodec.maxBytes else {
            throw PortableCapabilityIntentProfileWireError.tooLarge }
        var value = ScCapabilityIntentProfileV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentProfileV2>.size)
        value.api_version = apiVersion
        let status = data.withUnsafeBytes {
            sc_capability_intent_profile_wire_decode_v2(
                $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &value
            )
        }
        guard status == SC_OK else { throw status == SC_INVALID_ARGUMENT
            ? PortableCapabilityIntentProfileWireError.invalidValue
            : PortableCapabilityIntentProfileWireError.coreFailure(Int32(status)) }
        let axes = PortableCapabilityIntentProfileAxes(
            localRoleBits: value.capabilities & 0x7,
            sourceTopologyBits: value.capabilities & 0xf00,
            sinkPresentationBits: value.capabilities & 0x7_0000,
            inputPolicyBits: value.capabilities & 0x700_0000,
            transportPreferenceBits: value.capabilities & 0x7_0000_0000,
            topologyBits: value.capabilities & 0x700_0000_0000
        )
        guard value.struct_size == UInt32(MemoryLayout<ScCapabilityIntentProfileV2>.size),
              value.api_version == apiVersion, zero(value.reserved),
              axes.capabilityBits == value.capabilities,
              PortableCapabilityIntentProductProfile.valid(axes),
              let role = PortableCapabilityIntentRole(rawValue: value.sender_role),
              axes.localRoleBits & (UInt64(1) << UInt64(role.rawValue - 1)) != 0 else {
            throw PortableCapabilityIntentProfileWireError.invalidValue
        }
        return .init(
            generation: value.generation,
            schemaVersion: PortableCapabilityIntentProfileWireCodec.schemaVersion,
            senderRole: role, peerProfile: .init(validated: axes)
        )
    }
    private static func encoded(
        maxBytes: Int,
        call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> ScStatus,
        failure: (ScStatus) -> any Error
    ) throws -> Data {
        var needed = 0
        let sizing = call(nil, 0, &needed)
        guard sizing == SC_BUFFER_TOO_SMALL, needed > 0, needed <= maxBytes else {
            throw failure(sizing)
        }
        let expected = needed
        var output = Data(count: expected)
        let status = output.withUnsafeMutableBytes {
            call($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &needed)
        }
        guard status == SC_OK, needed == expected else { throw failure(status) }
        return output
    }

    private static func messageKind(_ value: UInt8) -> PortableCapabilityIntentMessageKind? {
        switch value {
        case UInt8(SC_CAPABILITY_INTENT_EVENT_OFFER): return .offer
        case UInt8(SC_CAPABILITY_INTENT_EVENT_SELECTION): return .selection
        case UInt8(SC_CAPABILITY_INTENT_EVENT_COMMIT): return .commit
        default: return nil
        }
    }

    private static func zero<T>(_ value: T) -> Bool {
        withUnsafeBytes(of: value) { $0.allSatisfy { $0 == 0 } } }

    private static func eventType(_ kind: PortableCapabilityIntentMessageKind) -> UInt8 {
        switch kind {
        case .offer: return UInt8(SC_CAPABILITY_INTENT_EVENT_OFFER)
        case .selection: return UInt8(SC_CAPABILITY_INTENT_EVENT_SELECTION)
        case .commit: return UInt8(SC_CAPABILITY_INTENT_EVENT_COMMIT)
        }
    }
}
