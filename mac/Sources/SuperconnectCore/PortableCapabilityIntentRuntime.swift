import Foundation
import SuperconnectCoreFFI

/// Single-owner active adapter for the universal Rust capability-intent v2 reducer.
/// It owns no JSON, transport, Session, entitlement, platform effect, or UI state.
public final class PortableCapabilityIntentNegotiation {
    public static var usesPortableCore: Bool { true }
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(config: PortableCapabilityIntentConfig) throws {
        var value = PortableCapabilityIntentFFICodec.encodeConfig(config)
        try Self.requireOK(sc_capability_intent_negotiation_new_v2(&value, &handle))
        guard handle != nil else { throw PortableCapabilityIntentFFICodec.invalidOutput() }
    }

    deinit {
        if let handle {
            let status = sc_capability_intent_negotiation_free_v2(handle)
            precondition(status == SC_OK, "Rust capability-intent v2 free failed: \(status)")
        }
    }

    public func apply(
        _ event: PortableCapabilityIntentEvent
    ) throws -> [PortableCapabilityIntentEffect] {
        lock.lock(); defer { lock.unlock() }
        var value = PortableCapabilityIntentFFICodec.encodeEvent(event)
        var effects = Array(
            repeating: ScCapabilityIntentEffectV2(),
            count: Int(SC_CAPABILITY_INTENT_MAX_EFFECTS_V2)
        )
        var count = 0
        let status = effects.withUnsafeMutableBufferPointer { buffer in
            sc_capability_intent_negotiation_apply_v2(
                handle,
                &value,
                buffer.baseAddress,
                buffer.count,
                &count
            )
        }
        try Self.requireOK(status)
        guard count >= 0, count <= effects.count else {
            throw PortableCapabilityIntentFFICodec.invalidOutput()
        }
        return try effects.prefix(count).map(PortableCapabilityIntentFFICodec.decodeEffect)
    }

    public func snapshot() throws -> PortableCapabilityIntentSnapshot {
        lock.lock(); defer { lock.unlock() }
        var value = ScCapabilityIntentSnapshotV2()
        value.struct_size = UInt32(MemoryLayout<ScCapabilityIntentSnapshotV2>.size)
        value.api_version = PortableCapabilityIntentFFICodec.apiVersion
        try Self.requireOK(sc_capability_intent_negotiation_snapshot_v2(handle, &value))
        return try PortableCapabilityIntentFFICodec.decodeSnapshot(value)
    }

    private static func requireOK(_ status: ScStatus) throws {
        guard status == SC_OK else {
            throw PortableCapabilityIntentError.ffiStatus(status)
        }
    }
}
