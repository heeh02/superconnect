import Foundation
import SuperconnectCoreFFI

/// Logical multiplexing channels. See proto/protocol.md §2.
public enum Channel: UInt8 {
    case control = 0
    case video = 1
    case input = 2
    case audio = 3
    case stats = 4
}

/// Per-frame flag bits. See proto/protocol.md §3.
public struct FrameFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let keyframe = FrameFlags(rawValue: 0x01)
    public static let codecConfig = FrameFlags(rawValue: 0x02)
}

/// One protocol message: a channel, flags, and a payload.
public struct Frame: Equatable {
    public let channel: UInt8
    public let flags: UInt8
    public let payload: Data

    public init(channel: UInt8, flags: UInt8 = 0, payload: Data) {
        self.channel = channel
        self.flags = flags
        self.payload = payload
    }

    public init(channel: Channel, flags: FrameFlags = [], payload: Data) {
        self.init(channel: channel.rawValue, flags: flags.rawValue, payload: payload)
    }
}

/// Errors raised while decoding a byte stream into frames.
public enum FrameError: Error, Equatable {
    case payloadTooLarge(Int)
}

/// Wire framing: `channel:u8 | flags:u8 | length:u32-LE | payload`.
/// This is the single most important interop surface — it must match
/// proto/vectors.json byte-for-byte across Swift, C++, and ArkTS.
public enum FrameCodec {
    public static let headerSize = 6
    public static let maxPayload = 16 * 1024 * 1024 // 16 MiB

    public static func encode(channel: UInt8, flags: UInt8, payload: Data) -> Data {
        RustWireRuntime.encodeFrame(channel: channel, flags: flags, payload: payload)
    }

    /// Header only. The sender may write the 6-byte header and the payload as two back-to-back sends
    /// on the same ordered stream — byte-identical on the wire to encode(channel:flags:payload:), but
    /// avoids copying the whole payload into a fresh frame buffer (biggest on IDRs).
    public static func encodeHeader(channel: UInt8, flags: UInt8, payloadLength: Int) -> Data {
        RustWireRuntime.encodeFrameHeader(channel: channel, flags: flags, payloadLength: payloadLength)
    }

    public static func encode(_ frame: Frame) -> Data {
        encode(channel: frame.channel, flags: frame.flags, payload: frame.payload)
    }

    public static func encode(channel: Channel, flags: FrameFlags = [], payload: Data) -> Data {
        encode(channel: channel.rawValue, flags: flags.rawValue, payload: payload)
    }
}

/// Accumulates incoming bytes and yields complete frames as they arrive.
/// Tolerant of arbitrary fragmentation (one frame split across many reads,
/// or many frames in one read).
public final class FrameDecoder {
    private let handle: OpaquePointer
    private var pendingHeader = [UInt8]()
    private var pendingPayloadBytes = 0
    public init() { handle = RustWireRuntime.makeFrameDecoder() }
    deinit { RustWireRuntime.freeFrameDecoder(handle) }

    public func push(_ data: Data) throws -> [Frame] {
        var frames = [Frame]()
        var offset = 0
        do {
            while offset < data.count {
                if pendingPayloadBytes > 0 {
                    let length = min(pendingPayloadBytes, data.count - offset)
                    try RustWireRuntime.pushFrameBytes(
                        data, offset: offset, length: length, into: handle
                    )
                    offset += length
                    pendingPayloadBytes -= length
                    if pendingPayloadBytes == 0 {
                        frames += try RustWireRuntime.drainFrames(from: handle)
                    }
                    continue
                }

                let length = min(FrameCodec.headerSize - pendingHeader.count, data.count - offset)
                for index in offset ..< offset + length {
                    pendingHeader.append(data[data.index(data.startIndex, offsetBy: index)])
                }
                try RustWireRuntime.pushFrameBytes(
                    data, offset: offset, length: length, into: handle
                )
                offset += length
                guard pendingHeader.count == FrameCodec.headerSize else { continue }

                let declaredLength = Int(pendingHeader[2])
                    | (Int(pendingHeader[3]) << 8)
                    | (Int(pendingHeader[4]) << 16)
                    | (Int(pendingHeader[5]) << 24)
                pendingHeader.removeAll(keepingCapacity: true)
                if declaredLength > FrameCodec.maxPayload {
                    _ = try RustWireRuntime.drainFrames(
                        from: handle, declaredOversizeLength: declaredLength
                    )
                    preconditionFailure("Rust accepted an oversized frame header")
                }
                pendingPayloadBytes = declaredLength
                if declaredLength == 0 {
                    frames += try RustWireRuntime.drainFrames(from: handle)
                }
            }
            return frames
        } catch {
            RustWireRuntime.resetFrameDecoder(handle)
            pendingHeader.removeAll(keepingCapacity: true)
            pendingPayloadBytes = 0
            throw error
        }
    }
}

// MARK: - Hex helpers (used by tests and logging)

public extension Data {
    init(hexString: String) {
        var data = Data()
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            if let byte = UInt8(hexString[idx ..< next], radix: 16) { data.append(byte) }
            idx = next
        }
        self = data
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
