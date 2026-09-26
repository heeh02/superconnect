import Foundation

/// Product-neutral session axes shared with `core::collaboration_intent`.
///
/// These are platform value projections only. Capability checks are performed by the Rust resolver;
/// no price tier, operating system, socket, or UI state is represented here.
public enum CollaborationLocalRole: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case source = 1
    case sink = 2
    case relay = 3
}

public enum CollaborationSourceTopology: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case extend = 1
    case mirror = 2
    case primary = 3
    case application = 4
}

public enum CollaborationSinkPresentation: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case windowed = 1
    case fullscreen = 2
    case pictureInPicture = 3
}

public enum CollaborationInputPolicy: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case viewOnly = 1
    case remoteControl = 2
    case requestControl = 3
}

public enum CollaborationTransportPreference: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case reliable = 1
    case lowestLatency = 2
    case automatic = 3
}

public enum CollaborationTopology: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case direct = 1
    case localMultiPeer = 2
    case relayed = 3
}

public enum CollaborationIntentAxis: UInt8, Codable, Hashable, Sendable {
    case localRole = 1
    case sourceTopology = 2
    case sinkPresentation = 3
    case inputPolicy = 4
    case transportPreference = 5
    case topology = 6
}

public enum CollaborationCapabilitySide: UInt8, Codable, Hashable, Sendable {
    case product = 1
    case peer = 2
}

public struct CollaborationIntentDraft: Codable, Equatable, Sendable {
    public var localRole: CollaborationLocalRole
    public var sourceTopology: CollaborationSourceTopology
    public var sinkPresentation: CollaborationSinkPresentation
    public var inputPolicy: CollaborationInputPolicy
    public var transportPreference: CollaborationTransportPreference
    public var topology: CollaborationTopology

    public init(
        localRole: CollaborationLocalRole,
        sourceTopology: CollaborationSourceTopology,
        sinkPresentation: CollaborationSinkPresentation,
        inputPolicy: CollaborationInputPolicy,
        transportPreference: CollaborationTransportPreference,
        topology: CollaborationTopology
    ) {
        self.localRole = localRole
        self.sourceTopology = sourceTopology
        self.sinkPresentation = sinkPresentation
        self.inputPolicy = inputPolicy
        self.transportPreference = transportPreference
        self.topology = topology
    }

    public static let legacyV1 = CollaborationIntentDraft(
        localRole: .source,
        sourceTopology: .extend,
        sinkPresentation: .windowed,
        inputPolicy: .remoteControl,
        transportPreference: .reliable,
        topology: .direct
    )
}

public struct CollaborationResolvedIntent: Codable, Equatable, Sendable {
    public let localRole: CollaborationLocalRole
    public let sourceTopology: CollaborationSourceTopology
    public let sinkPresentation: CollaborationSinkPresentation
    public let inputPolicy: CollaborationInputPolicy
    public let transportPreference: CollaborationTransportPreference
    public let topology: CollaborationTopology

    public init(_ draft: CollaborationIntentDraft) {
        localRole = draft.localRole
        sourceTopology = draft.sourceTopology
        sinkPresentation = draft.sinkPresentation
        inputPolicy = draft.inputPolicy
        transportPreference = draft.transportPreference
        topology = draft.topology
    }
}

/// Already-authorized product or peer capability facts. Construction cannot create unknown bits;
/// an empty axis remains representable so the core can reject incomplete profiles fail-closed.
public struct CollaborationIntentProfile: Equatable, Sendable {
    package let rawValue: UInt64

    public init(
        localRoles: Set<CollaborationLocalRole>,
        sourceTopologies: Set<CollaborationSourceTopology>,
        sinkPresentations: Set<CollaborationSinkPresentation>,
        inputPolicies: Set<CollaborationInputPolicy>,
        transportPreferences: Set<CollaborationTransportPreference>,
        topologies: Set<CollaborationTopology>
    ) {
        var bits: UInt64 = 0
        for value in localRoles { bits |= Self.bit(value.rawValue, shift: 0) }
        for value in sourceTopologies { bits |= Self.bit(value.rawValue, shift: 8) }
        for value in sinkPresentations { bits |= Self.bit(value.rawValue, shift: 16) }
        for value in inputPolicies { bits |= Self.bit(value.rawValue, shift: 24) }
        for value in transportPreferences { bits |= Self.bit(value.rawValue, shift: 32) }
        for value in topologies { bits |= Self.bit(value.rawValue, shift: 40) }
        rawValue = bits
    }

    public static let all = CollaborationIntentProfile(
        localRoles: Set(CollaborationLocalRole.allCases),
        sourceTopologies: Set(CollaborationSourceTopology.allCases),
        sinkPresentations: Set(CollaborationSinkPresentation.allCases),
        inputPolicies: Set(CollaborationInputPolicy.allCases),
        transportPreferences: Set(CollaborationTransportPreference.allCases),
        topologies: Set(CollaborationTopology.allCases)
    )

    package static func bit(_ value: UInt8, shift: UInt64) -> UInt64 {
        UInt64(1) << (shift + UInt64(value - 1))
    }
}

public enum CollaborationIntentResolutionError: Error, Equatable, Sendable {
    case invalidProfile
    case invalidCombination
    case missingCapability(
        side: CollaborationCapabilitySide,
        axis: CollaborationIntentAxis,
        value: UInt8
    )
    case coreFailure
}
