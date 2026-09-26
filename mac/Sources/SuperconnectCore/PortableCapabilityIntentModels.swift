public enum PortableCapabilityIntentSide: UInt8, Equatable, Sendable {
    case offerer = 1
    case selector = 2
}

public enum PortableCapabilityIntentError: Error, Equatable, Sendable {
    case coreUnavailable
    case ffiStatus(Int32)
}

// The transaction ABI and the public resolver project the same six canonical axes. Keep one set of
// platform values so a Session cannot silently translate between two Swift policy models.
public typealias PortableCapabilityIntentRole = CollaborationLocalRole
public typealias PortableCapabilityIntentSourceTopology = CollaborationSourceTopology
public typealias PortableCapabilityIntentSinkPresentation = CollaborationSinkPresentation
public typealias PortableCapabilityIntentInputPolicy = CollaborationInputPolicy
public typealias PortableCapabilityIntentTransport = CollaborationTransportPreference
public typealias PortableCapabilityIntentTopology = CollaborationTopology

public struct PortableCapabilityIntentResolved: Equatable, Sendable {
    public let localRole: PortableCapabilityIntentRole
    public let sourceTopology: PortableCapabilityIntentSourceTopology
    public let sinkPresentation: PortableCapabilityIntentSinkPresentation
    public let inputPolicy: PortableCapabilityIntentInputPolicy
    public let transportPreference: PortableCapabilityIntentTransport
    public let topology: PortableCapabilityIntentTopology

    public init(
        localRole: PortableCapabilityIntentRole,
        sourceTopology: PortableCapabilityIntentSourceTopology,
        sinkPresentation: PortableCapabilityIntentSinkPresentation,
        inputPolicy: PortableCapabilityIntentInputPolicy,
        transportPreference: PortableCapabilityIntentTransport,
        topology: PortableCapabilityIntentTopology
    ) {
        self.localRole = localRole
        self.sourceTopology = sourceTopology
        self.sinkPresentation = sinkPresentation
        self.inputPolicy = inputPolicy
        self.transportPreference = transportPreference
        self.topology = topology
    }

    public init(_ draft: CollaborationIntentDraft) {
        self.init(
            localRole: draft.localRole,
            sourceTopology: draft.sourceTopology,
            sinkPresentation: draft.sinkPresentation,
            inputPolicy: draft.inputPolicy,
            transportPreference: draft.transportPreference,
            topology: draft.topology
        )
    }

    public var draft: CollaborationIntentDraft {
        CollaborationIntentDraft(
            localRole: localRole,
            sourceTopology: sourceTopology,
            sinkPresentation: sinkPresentation,
            inputPolicy: inputPolicy,
            transportPreference: transportPreference,
            topology: topology
        )
    }
}

/// Typed outbound values emitted by the v2 profile/transaction path. JSON and transport remain
/// platform effects; no platform is allowed to reproduce the reducer decision.
public enum PortableCapabilityIntentOutbound: Equatable, Sendable {
    case profile(PortableCapabilityIntentProductAdvertisement)
    case transaction(PortableCapabilityIntentMessage)
}

public struct PortableCapabilityIntentConfig: Equatable, Sendable {
    public let generation: UInt64
    public let productCapabilities: UInt64
    public let peerCapabilities: UInt64
    public let side: PortableCapabilityIntentSide
    public let desiredPeerRole: PortableCapabilityIntentRole
    public let intent: PortableCapabilityIntentResolved

    public init(
        generation: UInt64,
        productCapabilities: UInt64,
        peerCapabilities: UInt64,
        side: PortableCapabilityIntentSide,
        desiredPeerRole: PortableCapabilityIntentRole,
        intent: PortableCapabilityIntentResolved
    ) {
        self.generation = generation
        self.productCapabilities = productCapabilities
        self.peerCapabilities = peerCapabilities
        self.side = side
        self.desiredPeerRole = desiredPeerRole
        self.intent = intent
    }
}

public enum PortableCapabilityIntentMessageKind: UInt8, Equatable, Sendable {
    case offer = 1
    case selection = 2
    case commit = 3
}

public struct PortableCapabilityIntentMessage: Equatable, Sendable {
    public let kind: PortableCapabilityIntentMessageKind
    public let generation: UInt64
    public let negotiationVersion: UInt16
    public let offererRole: PortableCapabilityIntentRole
    public let selectorRole: PortableCapabilityIntentRole
    public let projection: PortableCapabilityIntentSourceTopology
    public let transport: PortableCapabilityIntentTransport
    public let resolvedIntent: PortableCapabilityIntentResolved

    public init(
        kind: PortableCapabilityIntentMessageKind,
        generation: UInt64,
        negotiationVersion: UInt16,
        offererRole: PortableCapabilityIntentRole,
        selectorRole: PortableCapabilityIntentRole,
        projection: PortableCapabilityIntentSourceTopology,
        transport: PortableCapabilityIntentTransport,
        resolvedIntent: PortableCapabilityIntentResolved
    ) {
        self.kind = kind
        self.generation = generation
        self.negotiationVersion = negotiationVersion
        self.offererRole = offererRole
        self.selectorRole = selectorRole
        self.projection = projection
        self.transport = transport
        self.resolvedIntent = resolvedIntent
    }
}

public enum PortableCapabilityIntentEvent: Equatable, Sendable {
    case peerHello(generation: UInt64, negotiationVersion: UInt16?)
    case message(PortableCapabilityIntentMessage)
}

public struct PortableCapabilityIntentBinding: Equatable, Sendable {
    public let localIntent: PortableCapabilityIntentResolved
    public let peerRole: PortableCapabilityIntentRole
    public let negotiated: Bool

    public init(
        localIntent: PortableCapabilityIntentResolved,
        peerRole: PortableCapabilityIntentRole,
        negotiated: Bool
    ) {
        self.localIntent = localIntent
        self.peerRole = peerRole
        self.negotiated = negotiated
    }
}

public enum PortableCapabilityIntentRejected: Equatable, Sendable {
    case outOfOrder
    case staleGeneration(expected: UInt64, received: UInt64)
}

public enum PortableCapabilityIntentFatal: Equatable, Sendable {
    case unsupportedVersion(expected: UInt16, received: UInt16)
    case roleMismatch(expected: PortableCapabilityIntentRole, received: PortableCapabilityIntentRole)
    case projectionMismatch(
        expected: PortableCapabilityIntentSourceTopology,
        received: PortableCapabilityIntentSourceTopology
    )
    case transportMismatch(
        expected: PortableCapabilityIntentTransport,
        received: PortableCapabilityIntentTransport
    )
    case intentMismatch
    case commitMismatch
    case legacyIntentMismatch
}

public enum PortableCapabilityIntentEffect: Equatable, Sendable {
    case send(PortableCapabilityIntentMessage)
    case committed(PortableCapabilityIntentBinding)
    case connected(PortableCapabilityIntentBinding)
    case rejected(PortableCapabilityIntentRejected)
    case fatal(PortableCapabilityIntentFatal)
}

public struct PortableCapabilityIntentSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let productCapabilities: UInt64
    public let peerCapabilities: UInt64
    public let side: PortableCapabilityIntentSide
    public let desiredPeerRole: PortableCapabilityIntentRole
    public let resolvedIntent: PortableCapabilityIntentResolved
    public let binding: PortableCapabilityIntentBinding?
}
