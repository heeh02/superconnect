import Foundation

/// Input event kinds. See proto/protocol.md §5.
public enum InputType: UInt8 {
    case touchDown = 0
    case touchMove = 1
    case touchUp = 2
    case hover = 3
    case keyDown = 4
    case keyUp = 5
    case scroll = 6
    case zoom = 7
}

/// Which physical tool produced the event.
public enum InputTool: UInt8 {
    case finger = 0
    case pen = 1
    case eraser = 2
    case mouse = 3
}

public struct InputButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let primary = InputButtons(rawValue: 0x01)
    public static let secondary = InputButtons(rawValue: 0x02)
}

/// Keyboard modifier bitmask carried in the InputEvent `flags` byte for key events.
/// The tablet reports which physical modifiers are held; the Mac maps their MEANING
/// (e.g. tablet Control → macOS Command) — the remap lives only on the Mac side.
public struct InputFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift   = InputFlags(rawValue: 0x01)
    public static let control = InputFlags(rawValue: 0x02) // tablet Ctrl key
    public static let alt     = InputFlags(rawValue: 0x04) // tablet Alt/Option
    public static let meta    = InputFlags(rawValue: 0x08) // reserved / Fn (tablet has no Cmd)
}

/// A single input event. Fixed-size 44-byte little-endian wire record so all
/// three languages (Swift / ArkTS / C++) encode it identically.
///
/// Layout (LE):
///   type:u8 | tool:u8 | buttons:u8 | flags:u8
///   timestampMs:u64
///   x:f32 | y:f32              (normalized [0,1] over the virtual display)
///   pressure:f32               ([0,1]; raw device value may be larger — normalize)
///   tiltX:f32 | tiltY:f32      (stylus tilt, degrees [-90,90])
///   scrollX:f32 | scrollY:f32
///   keyCode:u16 | reserved:u16
public struct InputEvent: Equatable {
    public var type: UInt8
    public var tool: UInt8
    public var buttons: UInt8
    public var flags: UInt8
    public var timestampMs: UInt64
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var tiltX: Float
    public var tiltY: Float
    public var scrollX: Float
    public var scrollY: Float
    public var keyCode: UInt16
    public var reserved: UInt16

    public init(type: UInt8, tool: UInt8 = InputTool.finger.rawValue, buttons: UInt8 = 0,
                flags: UInt8 = 0, timestampMs: UInt64 = 0,
                x: Float = 0, y: Float = 0, pressure: Float = 0,
                tiltX: Float = 0, tiltY: Float = 0,
                scrollX: Float = 0, scrollY: Float = 0,
                keyCode: UInt16 = 0, reserved: UInt16 = 0) {
        self.type = type; self.tool = tool; self.buttons = buttons; self.flags = flags
        self.timestampMs = timestampMs
        self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY
        self.scrollX = scrollX; self.scrollY = scrollY
        self.keyCode = keyCode; self.reserved = reserved
    }
}

public enum InputCodec {
    public static let recordSize = 44

    public static func encode(_ e: InputEvent) -> Data {
        var w = ByteWriter()
        w.u8(e.type); w.u8(e.tool); w.u8(e.buttons); w.u8(e.flags)
        w.u64(e.timestampMs)
        w.f32(e.x); w.f32(e.y); w.f32(e.pressure)
        w.f32(e.tiltX); w.f32(e.tiltY)
        w.f32(e.scrollX); w.f32(e.scrollY)
        w.u16(e.keyCode); w.u16(e.reserved)
        return w.data
    }

    public static func decode(_ data: Data) -> InputEvent? {
        guard data.count >= recordSize else { return nil }
        var r = ByteReader(data)
        return InputEvent(
            type: r.u8(), tool: r.u8(), buttons: r.u8(), flags: r.u8(),
            timestampMs: r.u64(),
            x: r.f32(), y: r.f32(), pressure: r.f32(),
            tiltX: r.f32(), tiltY: r.f32(),
            scrollX: r.f32(), scrollY: r.f32(),
            keyCode: r.u16(), reserved: r.u16())
    }
}

// MARK: - Little-endian byte helpers

private struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { for i in 0..<2 { data.append(UInt8((v >> (8 * UInt16(i))) & 0xff)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { data.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
}

private struct ByteReader {
    let bytes: [UInt8]
    var i = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    mutating func u8() -> UInt8 { defer { i += 1 }; return bytes[i] }
    mutating func u16() -> UInt16 { UInt16(u8()) | (UInt16(u8()) << 8) }
    mutating func u32() -> UInt32 {
        UInt32(u8()) | (UInt32(u8()) << 8) | (UInt32(u8()) << 16) | (UInt32(u8()) << 24)
    }
    mutating func u64() -> UInt64 {
        var v: UInt64 = 0
        for s in stride(from: 0, through: 56, by: 8) { v |= UInt64(u8()) << UInt64(s) }
        return v
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
}
