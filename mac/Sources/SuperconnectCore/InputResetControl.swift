import Foundation

public struct InputResetControl: Equatable, Sendable {
    public let reason: String

    public init?(reason: String) {
        guard RustWireRuntime.encodeInputReset(reason) != nil else { return nil }
        self.reason = reason
    }

    public init?(wirePayload: Data) {
        guard let reason = RustWireRuntime.decodeInputReset(wirePayload) else { return nil }
        self.reason = reason
    }

    public var wirePayload: Data? { RustWireRuntime.encodeInputReset(reason) }
}
