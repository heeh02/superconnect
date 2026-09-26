import Foundation

/// FR120 FrameIdentity — the per-frame identity header prepended to every encoded access unit on
/// BOTH video transports (docs/FR120.md §FrameIdentity). v1 is 16 bytes; negotiated v2 is 24 bytes
/// and inserts a 64-bit streamEpoch before the three v1 u32 fields:
///
/// ```
/// [0]     0x53 'S'   ┐ magic — Annex-B from our emitter always starts 00 00 00 01, so a receiver
/// [1]     0x4D 'M'   ┘ can SNIFF this header unambiguously (no version negotiation needed)
/// [2]     version u8 (= 1 or 2)
/// [3]     flags u8:  0x01 = synthetic (heartbeat resend of sourceFrameID), 0x02 = keyframe
/// v1 [4..15]: sourceFrameID, captureTimeMs, accessUnitSeq (three u32 LE)
/// v2 [4..11]: streamEpoch u64 LE; [12..23]: the same three u32 fields
/// ```
///
/// Placement: on TCP it is the first 16/24 bytes of the VIDEO frame payload; on UDP it is prepended to
/// the frame BEFORE packetization, so fragment 0 carries it and the reassembler rebuilds it
/// transparently — the 14-byte UDP packet header does NOT change (stays wire-compatible with the
/// golden vectors in proto/vectors-private.json). Pure + deterministic so it is golden-vector
/// testable like `FrameCodec`.
public enum VideoFrameMeta {
    public static let size = 16                 // v1 compatibility size
    public static let version: UInt8 = 1        // v1 compatibility version
    public static let v2Size = 24
    public static let latestVersion: UInt8 = 2
    public static let magic0: UInt8 = 0x53   // 'S'
    public static let magic1: UInt8 = 0x4D   // 'M'
    public static let syntheticFlag: UInt8 = 0x01
    public static let keyframeFlag: UInt8 = 0x02

    public struct Fields: Equatable, Sendable {
        public let isSynthetic: Bool
        public let isKeyframe: Bool
        public let sourceFrameID: UInt32
        public let captureTimeMs: UInt32
        public let accessUnitSeq: UInt32
        /// Random/incremented per pipeline. Zero means unavailable on a legacy v1 header.
        public let streamEpoch: UInt64

        public init(isSynthetic: Bool, isKeyframe: Bool, sourceFrameID: UInt32,
                    captureTimeMs: UInt32, accessUnitSeq: UInt32, streamEpoch: UInt64 = 0) {
            self.isSynthetic = isSynthetic
            self.isKeyframe = isKeyframe
            self.sourceFrameID = sourceFrameID
            self.captureTimeMs = captureTimeMs
            self.accessUnitSeq = accessUnitSeq
            self.streamEpoch = streamEpoch
        }
    }

    /// Serialize v1 (16 bytes, legacy) or negotiated v2 (24 bytes, adds streamEpoch u64 LE).
    public static func encode(_ f: Fields, wireVersion: UInt8 = version) -> Data {
        let normalizedVersion = wireVersion >= latestVersion ? latestVersion : version
        return RustWireRuntime.encodeVideoMeta(f, wireVersion: normalizedVersion)
    }

    /// Parse the header at the start of `payload`. Returns nil when the payload does NOT start with
    /// the meta magic (a legacy pre-FrameIdentity sender) — the caller then treats the WHOLE payload
    /// as Annex-B. A payload that starts with the magic but is truncated/wrong-version is malformed
    /// (also nil, but distinguishable via `hasMagic`).
    public static func parse(_ payload: Data) -> (fields: Fields, rest: Data)? {
        switch RustWireRuntime.decodeVideoMeta(payload) {
        case .absent, .malformed:
            return nil
        case .valid(let fields, let payloadOffset):
            return (fields, payload.dropFirst(payloadOffset))
        }
    }

    /// True when the payload starts with the meta magic (regardless of version/length).
    public static func hasMagic(_ payload: Data) -> Bool {
        switch RustWireRuntime.decodeVideoMeta(payload) {
        case .absent: return false
        case .valid, .malformed: return true
        }
    }
}
