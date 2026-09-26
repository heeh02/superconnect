import Foundation

/// Wire identity only. Recovery policy/state is not part of the FOSS preview.
public struct PortableRecoveryIdentity: Equatable, Sendable {
    public let generation: UInt64
    public let recoveryID: UInt64
    public let sourceFrameID: UInt64

    public init(generation: UInt64, recoveryID: UInt64, sourceFrameID: UInt64) {
        self.generation = generation
        self.recoveryID = recoveryID
        self.sourceFrameID = sourceFrameID
    }
}

public enum MediaRecoveryControlType: String, Sendable {
    case anchor = "recovery_anchor"
    case accepted = "anchor_accepted"
    case output = "anchor_output"
}

public enum KeyframeRequestReason: Equatable, Sendable {
    case unspecified, udpGap, udpReassemblyOverflow, udpAuth, decoderBacklog
    case decoderInputFailure, decoderNotReady, decoderError, configRearm

    public var wireName: String? {
        switch self {
        case .unspecified: nil
        case .udpGap: "udp_gap"
        case .udpReassemblyOverflow: "udp_reassembly_overflow"
        case .udpAuth: "udp_auth"
        case .decoderBacklog: "decoder_backlog"
        case .decoderInputFailure: "decoder_input_failure"
        case .decoderNotReady: "decoder_not_ready"
        case .decoderError: "decoder_error"
        case .configRearm: "config_rearm"
        }
    }
}

public struct KeyframeRequestControl: Equatable, Sendable {
    public let reason: KeyframeRequestReason

    public init(reason: KeyframeRequestReason = .unspecified) { self.reason = reason }

    public init?(wirePayload: Data) {
        guard let reason = RustWireRuntime.decodeKeyframeRequest(wirePayload) else { return nil }
        self.reason = reason
    }

    public var wirePayload: Data? { RustWireRuntime.encodeKeyframeRequest(reason) }
}

/// Value-only projection of the canonical Rust recovery CONTROL wire record.
public struct MediaRecoveryControl: Equatable, Sendable {
    public let type: MediaRecoveryControlType
    public let identity: PortableRecoveryIdentity

    public init(type: MediaRecoveryControlType, identity: PortableRecoveryIdentity) {
        self.type = type
        self.identity = identity
    }

    public init?(wirePayload: Data, expected: MediaRecoveryControlType? = nil) {
        guard let decoded = RustWireRuntime.decodeMediaRecoveryControl(wirePayload),
              expected == nil || decoded.type == expected else { return nil }
        self = decoded
    }

    public var wirePayload: Data? {
        RustWireRuntime.encodeMediaRecoveryControl(self)
    }

    // Compatibility value surface for callers/tests that still need a JSON object. Both directions
    // pass through the Rust codec; this dictionary is never the wire authority.
    public var object: [String: Any] {
        guard let wirePayload,
              let value = try? JSONSerialization.jsonObject(with: wirePayload),
              let object = value as? [String: Any]
        else { preconditionFailure("Rust recovery wire projection failed") }
        return object
    }

    public init?(object: [String: Any], expected: MediaRecoveryControlType) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        self.init(wirePayload: payload, expected: expected)
    }
}
