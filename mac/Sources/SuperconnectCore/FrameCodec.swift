import Foundation

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
        var out = Data(capacity: headerSize + payload.count)
        out.append(channel)
        out.append(flags)
        let len = UInt32(payload.count)
        out.append(UInt8(len & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 24) & 0xff))
        out.append(payload)
        return out
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
    private var buffer = [UInt8]()

    public init() {}

    public func push(_ data: Data) throws -> [Frame] {
        buffer.append(contentsOf: data)
        var frames = [Frame]()
        var cursor = 0
        while buffer.count - cursor >= FrameCodec.headerSize {
            let base = cursor
            let channel = buffer[base]
            let flags = buffer[base + 1]
            let len = Int(buffer[base + 2])
                | (Int(buffer[base + 3]) << 8)
                | (Int(buffer[base + 4]) << 16)
                | (Int(buffer[base + 5]) << 24)
            if len > FrameCodec.maxPayload {
                throw FrameError.payloadTooLarge(len)
            }
            let total = FrameCodec.headerSize + len
            if buffer.count - base < total { break } // wait for more bytes
            let payloadStart = base + FrameCodec.headerSize
            let payload = Data(buffer[payloadStart ..< payloadStart + len])
            frames.append(Frame(channel: channel, flags: flags, payload: payload))
            cursor += total
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
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
