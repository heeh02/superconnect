public struct PortableCapabilityIntentProfileAxes: Equatable, Sendable {
    public let localRoleBits: UInt64
    public let sourceTopologyBits: UInt64
    public let sinkPresentationBits: UInt64
    public let inputPolicyBits: UInt64
    public let transportPreferenceBits: UInt64
    public let topologyBits: UInt64

    public var capabilityBits: UInt64 {
        localRoleBits | sourceTopologyBits | sinkPresentationBits | inputPolicyBits |
            transportPreferenceBits | topologyBits
    }
}

/// Local product-composition fact. Only this type is accepted by the profile encoder.
public struct PortableCapabilityIntentProductProfile: Equatable, Sendable {
    public let axes: PortableCapabilityIntentProfileAxes

    public init(
        localRoles: Set<PortableCapabilityIntentRole>,
        sourceTopologies: Set<PortableCapabilityIntentSourceTopology>,
        sinkPresentations: Set<PortableCapabilityIntentSinkPresentation>,
        inputPolicies: Set<PortableCapabilityIntentInputPolicy>,
        transportPreferences: Set<PortableCapabilityIntentTransport>,
        topologies: Set<PortableCapabilityIntentTopology>
    ) {
        let axes = PortableCapabilityIntentProfileAxes(
            localRoleBits: Self.bits(localRoles, shift: 0),
            sourceTopologyBits: Self.bits(sourceTopologies, shift: 8),
            sinkPresentationBits: Self.bits(sinkPresentations, shift: 16),
            inputPolicyBits: Self.bits(inputPolicies, shift: 24),
            transportPreferenceBits: Self.bits(transportPreferences, shift: 32),
            topologyBits: Self.bits(topologies, shift: 40)
        )
        precondition(Self.valid(axes), "capability intent product profile needs every axis")
        self.axes = axes
    }

    public init(exact intent: PortableCapabilityIntentResolved) {
        self.init(
            localRoles: [intent.localRole],
            sourceTopologies: [intent.sourceTopology],
            sinkPresentations: [intent.sinkPresentation],
            inputPolicies: [intent.inputPolicy],
            transportPreferences: [intent.transportPreference],
            topologies: [intent.topology]
        )
    }

    package init(validated axes: PortableCapabilityIntentProfileAxes) {
        precondition(Self.valid(axes), "invalid capability intent product axes")
        self.axes = axes
    }

    public var capabilityBits: UInt64 { axes.capabilityBits }

    public func contains(_ intent: PortableCapabilityIntentResolved) -> Bool {
        let selected = PortableCapabilityIntentProductProfile(exact: intent).axes
        return Self.contains(axes.localRoleBits, selected.localRoleBits)
            && Self.contains(axes.sourceTopologyBits, selected.sourceTopologyBits)
            && Self.contains(axes.sinkPresentationBits, selected.sinkPresentationBits)
            && Self.contains(axes.inputPolicyBits, selected.inputPolicyBits)
            && Self.contains(axes.transportPreferenceBits, selected.transportPreferenceBits)
            && Self.contains(axes.topologyBits, selected.topologyBits)
    }

    package static func valid(_ axes: PortableCapabilityIntentProfileAxes) -> Bool {
        validAxis(axes.localRoleBits, mask: 0x7)
            && validAxis(axes.sourceTopologyBits, mask: 0xf00)
            && validAxis(axes.sinkPresentationBits, mask: 0x7_0000)
            && validAxis(axes.inputPolicyBits, mask: 0x700_0000)
            && validAxis(axes.transportPreferenceBits, mask: 0x7_0000_0000)
            && validAxis(axes.topologyBits, mask: 0x700_0000_0000)
    }

    private static func bits<Value: RawRepresentable>(
        _ values: Set<Value>, shift: UInt64
    ) -> UInt64 where Value.RawValue == UInt8, Value: Hashable {
        values.reduce(0) { $0 | (UInt64(1) << (shift + UInt64($1.rawValue - 1))) }
    }

    private static func validAxis(_ value: UInt64, mask: UInt64) -> Bool {
        value != 0 && value & ~mask == 0
    }

    private static func contains(_ available: UInt64, _ selected: UInt64) -> Bool {
        available & selected == selected
    }
}

/// Immutable remote fact. It has no path into the product advertisement encoder.
public struct PortableCapabilityIntentPeerProfile: Equatable, Sendable {
    public let axes: PortableCapabilityIntentProfileAxes

    package init(validated axes: PortableCapabilityIntentProfileAxes) {
        self.axes = axes
    }

    public var capabilityBits: UInt64 { axes.capabilityBits }
}

public struct PortableCapabilityIntentProductAdvertisement: Equatable, Sendable {
    public let generation: UInt64
    public let schemaVersion: UInt16
    public let senderRole: PortableCapabilityIntentRole
    public let productProfile: PortableCapabilityIntentProductProfile

    public init(
        generation: UInt64,
        senderRole: PortableCapabilityIntentRole,
        productProfile: PortableCapabilityIntentProductProfile
    ) {
        self.generation = generation
        schemaVersion = PortableCapabilityIntentProfileWireCodec.schemaVersion
        self.senderRole = senderRole
        self.productProfile = productProfile
    }

    public var capabilityBits: UInt64 { productProfile.capabilityBits }
}

public struct PortableCapabilityIntentPeerAdvertisement: Equatable, Sendable {
    public let generation: UInt64
    public let schemaVersion: UInt16
    public let senderRole: PortableCapabilityIntentRole
    public let peerProfile: PortableCapabilityIntentPeerProfile

    package init(
        generation: UInt64,
        schemaVersion: UInt16,
        senderRole: PortableCapabilityIntentRole,
        peerProfile: PortableCapabilityIntentPeerProfile
    ) {
        self.generation = generation
        self.schemaVersion = schemaVersion
        self.senderRole = senderRole
        self.peerProfile = peerProfile
    }

    public var capabilityBits: UInt64 { peerProfile.capabilityBits }
}
