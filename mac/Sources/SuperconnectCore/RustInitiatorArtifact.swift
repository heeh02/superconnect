import Foundation

/// Owns one mutable byte storage. `RustInitiatorArtifact` may be copied as a dictionary value,
/// but cleanup always reaches this same storage instead of a Swift `Data` COW value.
final class RustInitiatorSensitiveArtifactBuffer {
    private var bytes: [UInt8]

    init(_ data: Data) {
        bytes = Array(data)
    }

    deinit { clear() }

    var data: Data { Data(bytes) }

    var isZeroed: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    func clear() {
        for index in bytes.indices { bytes[index] = 0 }
    }
}

enum RustInitiatorArtifact {
    case bytes(RustInitiatorSensitiveArtifactBuffer)
    case enrollmentKey(
        privateKey: RustInitiatorSensitiveArtifactBuffer,
        publicKey: RustInitiatorSensitiveArtifactBuffer
    )

    var data: Data? {
        guard case .bytes(let value) = self else { return nil }
        return value.data
    }

    func clear() {
        switch self {
        case .bytes(let value): value.clear()
        case .enrollmentKey(let privateKey, let publicKey):
            privateKey.clear()
            publicKey.clear()
        }
    }

    var isZeroed: Bool {
        switch self {
        case .bytes(let value): return value.isZeroed
        case .enrollmentKey(let privateKey, let publicKey):
            return privateKey.isZeroed && publicKey.isZeroed
        }
    }
}
