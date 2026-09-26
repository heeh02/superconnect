import SuperconnectCoreFFI

/// Single-owner, value-only binding to the universal Rust capability reducer.
///
/// The caller serializes `apply` and `snapshot`. The binding owns no socket, callback, Session,
/// product, clock or UI. A selector opens its reducer from the first strict offer so the offerer's
/// generation remains authoritative across every platform.
public final class PortableCapabilityRuntime {
    public static var usesPortableCore: Bool {
        true
    }

    public static var hasActiveABI: Bool {
        sc_mac_rust_capability_active_marker() == UInt32(SC_API_VERSION_V1)
    }

    public let configuration: PortableCapabilityConfiguration

    private enum SelectorHello: Equatable {
        case unobserved
        case observed(UInt16?)
    }

    private var handle: OpaquePointer?
    private var activeConfiguration: PortableCapabilityConfiguration?
    private var selectorHello = SelectorHello.unobserved
    private var locallyFailed = false

    public init(configuration: PortableCapabilityConfiguration) throws {
        self.configuration = configuration
        guard Self.configurationIsValid(configuration) else {
            throw PortableCapabilityError.invalidConfiguration
        }
        guard Self.hasActiveABI else { throw PortableCapabilityError.abiVersionMismatch }
        if configuration.side == .offerer {
            try open(configuration: configuration)
        }
    }

    deinit {
        if let handle { precondition(sc_capability_negotiation_free_v1(handle) == SC_OK) }
    }

    public func apply(_ event: PortableCapabilityEvent) throws -> [PortableCapabilityEffect] {
        guard !locallyFailed else { return [] }
        if case .peerHello(negotiationVersion: nil) = event,
           configuration.projection != .extend {
            locallyFailed = true
            return [.fatal(.projectionMismatch(
                expected: configuration.projection,
                received: .extend
            ))]
        }
        guard configuration.side == .selector, handle == nil else {
            return try applyToCore(event)
        }
        return try applyBeforeSelectorOffer(event)
    }

    public func snapshot() throws -> PortableCapabilitySnapshot {
        guard let handle else { throw PortableCapabilityError.negotiationNotStarted }
        var output = ScCapabilitySnapshotV1()
        output.struct_size = UInt32(MemoryLayout<ScCapabilitySnapshotV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        let status = sc_capability_negotiation_snapshot_v1(handle, &output)
        guard status == SC_OK else { throw Self.failure(status) }
        return try PortableCapabilityCodec.snapshot(output)
    }
}

private extension PortableCapabilityRuntime {
    static func configurationIsValid(_ value: PortableCapabilityConfiguration) -> Bool {
        guard value.localRole != value.desiredPeerRole,
              value.transport == .tcp,
              value.authorizedCapabilities.rawValue
                & ~PortableCapabilityAuthorization.known.rawValue == 0 else {
            return false
        }
        let required: PortableCapabilityAuthorization = [
            .init(role: value.localRole),
            .init(projection: value.projection),
            .transportTCP,
        ]
        return value.authorizedCapabilities.isSuperset(of: required)
    }
}

private extension PortableCapabilityRuntime {
    func applyBeforeSelectorOffer(
        _ event: PortableCapabilityEvent
    ) throws -> [PortableCapabilityEffect] {
        switch event {
        case .peerHello(let version):
            switch selectorHello {
            case .unobserved:
                selectorHello = .observed(version)
                if version == nil || version != portableCapabilityNegotiationVersion {
                    try open(configuration: configuration)
                    return try applyToCore(event)
                }
                return []
            case .observed(let previous) where previous == version:
                return []
            case .observed:
                return [.rejected(.outOfOrder)]
            }
        case .message(let message):
            guard case .observed(let version?) = selectorHello,
                  message.kind == .offer else {
                return [.rejected(.outOfOrder)]
            }
            var adopted = configuration
            adopted = PortableCapabilityConfiguration(
                generation: message.generation,
                side: adopted.side,
                localRole: adopted.localRole,
                desiredPeerRole: adopted.desiredPeerRole,
                projection: adopted.projection,
                transport: adopted.transport,
                authorizedCapabilities: adopted.authorizedCapabilities
            )
            try open(configuration: adopted)
            let helloEffects = try applyToCore(.peerHello(negotiationVersion: version))
            guard !helloEffects.contains(where: { if case .fatal = $0 { true } else { false } })
            else { return helloEffects }
            return helloEffects + (try applyToCore(event))
        }
    }

    func open(configuration: PortableCapabilityConfiguration) throws {
        precondition(handle == nil)
        var input = PortableCapabilityCodec.configuration(configuration)
        var created: OpaquePointer?
        let status = sc_capability_negotiation_new_v1(&input, &created)
        guard status == SC_OK else { throw Self.failure(status) }
        guard let created else {
            throw PortableCapabilityError.coreFailure(Int32(SC_INTERNAL_ERROR))
        }
        handle = created
        activeConfiguration = configuration
    }

    func applyToCore(_ event: PortableCapabilityEvent) throws -> [PortableCapabilityEffect] {
        guard let handle, let activeConfiguration else {
            throw PortableCapabilityError.negotiationNotStarted
        }
        var input = PortableCapabilityCodec.event(
            event,
            runtimeGeneration: activeConfiguration.generation
        )
        var output = Array(
            repeating: ScCapabilityEffectV1(),
            count: Int(SC_CAPABILITY_MAX_EFFECTS_V1)
        )
        var count = 0
        let status = output.withUnsafeMutableBufferPointer { buffer in
            sc_capability_negotiation_apply_v1(
                handle, &input, buffer.baseAddress, buffer.count, &count
            )
        }
        if status == SC_BUFFER_TOO_SMALL {
            throw PortableCapabilityError.effectCapacityExceeded(required: count)
        }
        guard status == SC_OK else { throw Self.failure(status) }
        guard count >= 0, count <= output.count else {
            throw PortableCapabilityError.malformedEffect
        }
        return try output.prefix(count).map(PortableCapabilityCodec.effect)
    }

    static func failure(_ status: ScStatus) -> PortableCapabilityError {
        status == SC_INVALID_ARGUMENT ? .invalidEvent : .coreFailure(Int32(status))
    }
}
