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
///   keyCode:u16 | pointerId:u16
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
    public var pointerId: UInt16

    public init(type: UInt8, tool: UInt8 = InputTool.finger.rawValue, buttons: UInt8 = 0,
                flags: UInt8 = 0, timestampMs: UInt64 = 0,
                x: Float = 0, y: Float = 0, pressure: Float = 0,
                tiltX: Float = 0, tiltY: Float = 0,
                scrollX: Float = 0, scrollY: Float = 0,
                keyCode: UInt16 = 0, pointerId: UInt16 = 0) {
        self.type = type; self.tool = tool; self.buttons = buttons; self.flags = flags
        self.timestampMs = timestampMs
        self.x = x; self.y = y; self.pressure = pressure
        self.tiltX = tiltX; self.tiltY = tiltY
        self.scrollX = scrollX; self.scrollY = scrollY
        self.keyCode = keyCode; self.pointerId = pointerId
    }
}

public enum InputCodec {
    public static let recordSize = 44

    public static func encode(_ e: InputEvent) -> Data {
        RustWireRuntime.encodeInput(e)
    }

    public static func decode(_ data: Data) -> InputEvent? {
        RustWireRuntime.decodeInput(data)
    }
}
