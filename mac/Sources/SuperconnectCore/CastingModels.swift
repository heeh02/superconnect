import Foundation

/// Which side of a cast session owns the desktop pixels.
///
/// The v1/v2 wire calls these roles `host` and `receiver`. New code uses source/sink so media
/// direction cannot be confused with connection initiator/server direction.
public enum MediaRole: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case sink

    public var peerRole: MediaRole { self == .source ? .sink : .source }

    public var legacyWireValue: String { self == .source ? "host" : "receiver" }

    public init?(legacyWireValue: String) {
        switch legacyWireValue {
        case "host", "source": self = .source
        case "receiver", "sink": self = .sink
        default: return nil
        }
    }
}

/// How the source desktop is materialized. This is orthogonal to whether the sink presents the
/// incoming stream in a window or fullscreen.
public enum ProjectionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case extend
    case mirror
    case primary
}

/// How a sink presents an already-negotiated stream locally.
public enum PresentationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case windowed
    case fullscreen
}

/// Whether the sink may send its local input back to the source.
public enum InputPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case viewOnly
    case remoteControl
    case requestControl
}

/// A requested media transport profile. `udpV2` still keeps control/input and keyframes reliable;
/// it names the existing private hybrid path, not a generic best-effort session.
public enum TransportProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case tcp
    case udpV2 = "udp-v2"
    case quic
}

/// Product-authorized facts passed into the platform-neutral capability reducer.
/// Price tiers and implementation types never cross this boundary.
public struct SessionCapabilityAuthorization: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let mediaHost = Self(rawValue: 1 << 0)
    public static let mediaReceiver = Self(rawValue: 1 << 1)
    public static let projectionExtend = Self(rawValue: 1 << 8)
    public static let projectionMirror = Self(rawValue: 1 << 9)
    public static let projectionPrimary = Self(rawValue: 1 << 10)
    public static let transportTCP = Self(rawValue: 1 << 16)

    public static func minimum(localRole: MediaRole, projection: ProjectionMode) -> Self {
        let role: Self = localRole == .source ? .mediaHost : .mediaReceiver
        let mode: Self
        switch projection {
        case .extend: mode = .projectionExtend
        case .mirror: mode = .projectionMirror
        case .primary: mode = .projectionPrimary
        }
        return [role, mode, .transportTCP]
    }
}

/// User intent before entitlement, peer capability, and live transport negotiation are applied.
/// `sourceDisplayID` is deliberately opaque: each platform owns its stable display identifier.
public struct ProjectionIntent: Codable, Equatable, Sendable {
    public var localRole: MediaRole
    public var mode: ProjectionMode
    public var inputPolicy: InputPolicy
    public var transportProfile: TransportProfile
    public var sourceDisplayID: String?

    public init(
        localRole: MediaRole = .source,
        mode: ProjectionMode = .extend,
        inputPolicy: InputPolicy = .remoteControl,
        transportProfile: TransportProfile = .tcp,
        sourceDisplayID: String? = nil
    ) {
        self.localRole = localRole
        self.mode = mode
        self.inputPolicy = inputPolicy
        self.transportProfile = transportProfile
        self.sourceDisplayID = sourceDisplayID
    }
}

/// Platform/entitlement capabilities resolved at the composition root. Media, codec, transport,
/// and input implementations receive an already-authorized intent and never inspect a price tier.
public struct CastCapabilitySet: Codable, Equatable, Sendable {
    public var localRoles: Set<MediaRole>
    public var projectionModes: Set<ProjectionMode>
    public var inputPolicies: Set<InputPolicy>
    public var transportProfiles: Set<TransportProfile>

    public init(
        localRoles: Set<MediaRole>,
        projectionModes: Set<ProjectionMode>,
        inputPolicies: Set<InputPolicy>,
        transportProfiles: Set<TransportProfile>
    ) {
        self.localRoles = localRoles
        self.projectionModes = projectionModes
        self.inputPolicies = inputPolicies
        self.transportProfiles = transportProfiles
    }

    public func supports(_ intent: ProjectionIntent) -> Bool {
        localRoles.contains(intent.localRole)
            && projectionModes.contains(intent.mode)
            && inputPolicies.contains(intent.inputPolicy)
            && transportProfiles.contains(intent.transportProfile)
    }
}
