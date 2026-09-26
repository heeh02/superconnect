/// Non-zero transaction identity shared by both negotiation sides.
public struct PortableCapabilityGeneration: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

/// Handshake position only. It does not imply media direction or socket ownership.
public enum PortableCapabilitySide: UInt8, CaseIterable, Equatable, Sendable {
    case offerer = 1
    case selector = 2
}

public enum PortableCapabilityRole: UInt8, CaseIterable, Equatable, Sendable {
    case host = 1
    case receiver = 2
}

public enum PortableCapabilityProjection: UInt8, CaseIterable, Equatable, Sendable {
    case extend = 1
    case mirror = 2
    case primary = 3
}

public enum PortableCapabilityTransport: UInt8, CaseIterable, Equatable, Sendable {
    case tcp = 1
}

public enum PortableCapabilityID: UInt8, CaseIterable, Equatable, Sendable {
    case mediaHost = 0
    case mediaReceiver = 1
    case projectionExtend = 8
    case projectionMirror = 9
    case projectionPrimary = 10
    case transportTCP = 16
}

/// Product-authorized facts. Product names, prices and implementations never enter the reducer.
public struct PortableCapabilityAuthorization: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let mediaHost = Self(id: .mediaHost)
    public static let mediaReceiver = Self(id: .mediaReceiver)
    public static let projectionExtend = Self(id: .projectionExtend)
    public static let projectionMirror = Self(id: .projectionMirror)
    public static let projectionPrimary = Self(id: .projectionPrimary)
    public static let transportTCP = Self(id: .transportTCP)

    public static let known: Self = [
        .mediaHost, .mediaReceiver,
        .projectionExtend, .projectionMirror, .projectionPrimary,
        .transportTCP,
    ]

    public init(id: PortableCapabilityID) {
        rawValue = UInt64(1) << UInt64(id.rawValue)
    }

    public static func minimum(
        localRole: PortableCapabilityRole,
        projection: PortableCapabilityProjection
    ) -> Self {
        [Self(role: localRole), Self(projection: projection), .transportTCP]
    }

    public init(role: PortableCapabilityRole) {
        self = role == .host ? .mediaHost : .mediaReceiver
    }

    public init(projection: PortableCapabilityProjection) {
        switch projection {
        case .extend: self = .projectionExtend
        case .mirror: self = .projectionMirror
        case .primary: self = .projectionPrimary
        }
    }
}

public struct PortableCapabilityConfiguration: Equatable, Sendable {
    /// For selectors this is the legacy fallback. The first strict offer owns strict generation.
    public let generation: PortableCapabilityGeneration
    public let side: PortableCapabilitySide
    public let localRole: PortableCapabilityRole
    public let desiredPeerRole: PortableCapabilityRole
    public let projection: PortableCapabilityProjection
    public let transport: PortableCapabilityTransport
    public let authorizedCapabilities: PortableCapabilityAuthorization

    public init(
        generation: PortableCapabilityGeneration,
        side: PortableCapabilitySide,
        localRole: PortableCapabilityRole,
        desiredPeerRole: PortableCapabilityRole,
        projection: PortableCapabilityProjection,
        transport: PortableCapabilityTransport,
        authorizedCapabilities: PortableCapabilityAuthorization
    ) {
        self.generation = generation
        self.side = side
        self.localRole = localRole
        self.desiredPeerRole = desiredPeerRole
        self.projection = projection
        self.transport = transport
        self.authorizedCapabilities = authorizedCapabilities
    }
}

public enum PortableCapabilityMessageKind: UInt8, CaseIterable, Equatable, Sendable {
    case offer = 1
    case selection = 2
    case commit = 3
}

public let portableCapabilityNegotiationVersion: UInt16 = 1

public struct PortableCapabilityMessage: Equatable, Sendable {
    public let kind: PortableCapabilityMessageKind
    public let generation: PortableCapabilityGeneration
    public let negotiationVersion: UInt16
    public let authorizedCapabilities: PortableCapabilityAuthorization
    public let offererRole: PortableCapabilityRole
    public let selectorRole: PortableCapabilityRole
    public let projection: PortableCapabilityProjection
    public let transport: PortableCapabilityTransport

    public init(
        kind: PortableCapabilityMessageKind,
        generation: PortableCapabilityGeneration,
        negotiationVersion: UInt16,
        authorizedCapabilities: PortableCapabilityAuthorization,
        offererRole: PortableCapabilityRole,
        selectorRole: PortableCapabilityRole,
        projection: PortableCapabilityProjection,
        transport: PortableCapabilityTransport
    ) {
        self.kind = kind
        self.generation = generation
        self.negotiationVersion = negotiationVersion
        self.authorizedCapabilities = authorizedCapabilities
        self.offererRole = offererRole
        self.selectorRole = selectorRole
        self.projection = projection
        self.transport = transport
    }
}

public struct PortableCapabilityBinding: Equatable, Sendable {
    public let generation: PortableCapabilityGeneration
    public let localRole: PortableCapabilityRole
    public let peerRole: PortableCapabilityRole
    public let projection: PortableCapabilityProjection
    public let transport: PortableCapabilityTransport
    public let negotiated: Bool

    public init(
        generation: PortableCapabilityGeneration,
        localRole: PortableCapabilityRole,
        peerRole: PortableCapabilityRole,
        projection: PortableCapabilityProjection,
        transport: PortableCapabilityTransport,
        negotiated: Bool
    ) {
        self.generation = generation
        self.localRole = localRole
        self.peerRole = peerRole
        self.projection = projection
        self.transport = transport
        self.negotiated = negotiated
    }
}

public enum PortableCapabilityEvent: Equatable, Sendable {
    case peerHello(negotiationVersion: UInt16?)
    case message(PortableCapabilityMessage)
}

public enum PortableCapabilityRejection: Equatable, Sendable {
    case outOfOrder
    case staleGeneration(
        expected: PortableCapabilityGeneration,
        received: PortableCapabilityGeneration
    )
}

public enum PortableCapabilityFatalReason: Equatable, Sendable {
    case unsupportedVersion(expected: UInt16, received: UInt16)
    case unsupportedCapability(PortableCapabilityID)
    case roleMismatch(expected: PortableCapabilityRole, received: PortableCapabilityRole)
    case projectionMismatch(
        expected: PortableCapabilityProjection,
        received: PortableCapabilityProjection
    )
    case commitMismatch
}

public enum PortableCapabilityEffect: Equatable, Sendable {
    case send(PortableCapabilityMessage)
    case committed(PortableCapabilityBinding)
    case connected(PortableCapabilityBinding)
    case rejected(PortableCapabilityRejection)
    case fatal(PortableCapabilityFatalReason)
}

public struct PortableCapabilitySnapshot: Equatable, Sendable {
    public let generation: PortableCapabilityGeneration
    public let authorizedCapabilities: PortableCapabilityAuthorization
    public let side: PortableCapabilitySide
    public let localRole: PortableCapabilityRole
    public let desiredPeerRole: PortableCapabilityRole
    public let projection: PortableCapabilityProjection
    public let transport: PortableCapabilityTransport
    public let binding: PortableCapabilityBinding?
}

public enum PortableCapabilityError: Error, Equatable, Sendable {
    case coreUnavailable
    case abiVersionMismatch
    case invalidConfiguration
    case invalidEvent
    case coreFailure(Int32)
    case effectCapacityExceeded(required: Int)
    case malformedEffect
    case negotiationNotStarted
    case malformedSnapshot
}
