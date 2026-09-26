public struct PortableSessionGeneration: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

public struct PortableSessionOperationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

public struct PortableSessionArtifactID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

public struct PortableSessionTimerToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

public struct PortableSessionAdmissionClaimID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

public struct PortableSessionIdentity: Hashable, Sendable {
    public static let maximumUTF8Bytes = 128
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let length = rawValue.utf8.count
        guard length > 0, length <= Self.maximumUTF8Bytes else {
            throw PortableSessionError.invalidIdentity
        }
        guard !rawValue.contains("|") else {
            throw PortableSessionError.invalidIdentity
        }
        let containsControl = rawValue.unicodeScalars.contains { scalar in
            scalar.value <= 0x1f || (0x7f...0x9f).contains(scalar.value)
        }
        guard !containsControl else {
            throw PortableSessionError.invalidIdentity
        }
        self.rawValue = rawValue
    }
}
