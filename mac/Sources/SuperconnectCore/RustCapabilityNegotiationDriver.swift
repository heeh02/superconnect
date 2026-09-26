import Foundation

struct RustCapabilityBinding: Equatable {
    let localRole: MediaRole
    let peerRole: MediaRole
    let projection: ProjectionMode
    let negotiated: Bool
}

/// Active initiator adapter. It owns sequencing only: both negotiation paths execute in Rust and
/// CONTROL transmission remains a platform effect; Rust owns every capability wire byte.
final class RustCapabilityNegotiationDriver {
    var sendWireControl: ((Data) -> Void)?
    var connected: ((RustCapabilityBinding) -> Void)?
    var failed: ((String) -> Void)?
    var log: ((String) -> Void)?

    private enum Mode {
        case awaitingHello
        case legacy
        case intentAwaitingProfile
        case intentActive
        case finished
    }

    private let generation: UInt64
    private let localIntent: PortableCapabilityIntentResolved
    private let desiredPeerIntentRole: PortableCapabilityIntentRole
    private let localProfile: PortableCapabilityIntentProductAdvertisement
    private let legacyRuntime: PortableCapabilityRuntime
    private let lock = NSRecursiveLock()
    private var intentRuntime: PortableCapabilityIntentNegotiation?
    private var peerProfile: PortableCapabilityIntentPeerAdvertisement?
    private var mode = Mode.awaitingHello

    init(
        generation: UInt64,
        localRole: MediaRole,
        projection: ProjectionMode,
        authorized: SessionCapabilityAuthorization,
        intentProductProfile: PortableCapabilityIntentProductProfile,
        collaborationIntent: CollaborationIntentDraft
    ) throws {
        guard let legacyGeneration = PortableCapabilityGeneration(rawValue: generation) else {
            throw PortableCapabilityError.invalidConfiguration
        }
        self.generation = generation
        localIntent = .init(collaborationIntent)
        guard intentProductProfile.contains(localIntent) else {
            throw PortableCapabilityError.invalidConfiguration
        }
        desiredPeerIntentRole = localIntent.localRole == .source ? .sink : .source
        localProfile = .init(
            generation: generation,
            senderRole: localIntent.localRole,
            productProfile: intentProductProfile
        )
        legacyRuntime = try PortableCapabilityRuntime(configuration: .init(
            generation: legacyGeneration,
            side: .offerer,
            localRole: Self.role(localRole),
            desiredPeerRole: Self.role(localRole.peerRole),
            projection: Self.projection(projection),
            transport: .tcp,
            authorizedCapabilities: .init(rawValue: authorized.rawValue)
        ))
    }

    func begin(peerVersion: Int?, peerIntentVersion: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard case .awaitingHello = mode else { return }
        if peerIntentVersion == Int(PortableCapabilityIntentWireCodec.negotiationVersion) {
            mode = .intentAwaitingProfile
            do {
                sendWireControl?(try PortableCapabilityIntentProfileWireCodec.encodeData(localProfile))
            } catch {
                fail("capability intent profile encoding failed")
            }
            return
        }

        let version: UInt16?
        if let peerVersion {
            guard let exact = UInt16(exactly: peerVersion) else {
                fail("capability negotiation version is malformed")
                return
            }
            version = exact
        } else {
            version = nil
        }
        mode = .legacy
        applyLegacy(.peerHello(negotiationVersion: version))
    }

    func receive(payload: Data) {
        lock.lock(); defer { lock.unlock() }
        guard case .legacy = mode else {
            fail("legacy capability message entered capability intent v2")
            return
        }
        guard let message = try? PortableCapabilityWireCodec.decode(payload) else {
            fail("capability envelope is malformed")
            return
        }
        applyLegacy(.message(message))
    }

    func receiveIntentProfile(payload: Data) {
        lock.lock(); defer { lock.unlock() }
        do {
            let profile = try PortableCapabilityIntentProfileWireCodec.decode(payload)
            guard profile.generation == generation,
                  profile.senderRole == desiredPeerIntentRole else {
                fail("capability intent profile does not match the active Session")
                return
            }
            if peerProfile != nil {
                fail("duplicate capability intent profile")
                return
            }
            guard case .intentAwaitingProfile = mode else {
                fail("capability intent profile arrived out of order")
                return
            }
            peerProfile = profile
            let runtime = try PortableCapabilityIntentNegotiation(config: .init(
                generation: generation,
                productCapabilities: localProfile.capabilityBits,
                peerCapabilities: profile.capabilityBits,
                side: .offerer,
                desiredPeerRole: desiredPeerIntentRole,
                intent: localIntent
            ))
            intentRuntime = runtime
            mode = .intentActive
            applyIntent(.peerHello(
                generation: generation,
                negotiationVersion: PortableCapabilityIntentWireCodec.negotiationVersion
            ), to: runtime)
        } catch {
            fail("capability intent profile is malformed or incompatible")
        }
    }

    func receiveIntent(payload: Data) {
        lock.lock(); defer { lock.unlock() }
        guard case .intentActive = mode, let runtime = intentRuntime else {
            fail("capability intent transaction arrived before profile agreement")
            return
        }
        do {
            let message = try PortableCapabilityIntentWireCodec.decode(payload)
            guard message.generation == generation, message.kind == .selection else {
                fail("capability intent transaction is stale or out of order")
                return
            }
            applyIntent(.message(message), to: runtime)
        } catch {
            fail("capability intent transaction is malformed")
        }
    }

    private func applyLegacy(_ event: PortableCapabilityEvent) {
        do {
            for effect in try legacyRuntime.apply(event) { executeLegacy(effect) }
        } catch {
            fail("capability reducer ABI failure")
        }
    }

    private func applyIntent(
        _ event: PortableCapabilityIntentEvent,
        to runtime: PortableCapabilityIntentNegotiation
    ) {
        do {
            for effect in try runtime.apply(event) { executeIntent(effect) }
        } catch {
            fail("capability intent reducer ABI failure")
        }
    }

    private func executeLegacy(_ effect: PortableCapabilityEffect) {
        switch effect {
        case .send(let message):
            do { sendWireControl?(try PortableCapabilityWireCodec.encodeData(message)) }
            catch { fail("capability wire encoding failed") }
        case .committed(let binding):
            log?("capability binding committed negotiated=\(binding.negotiated)")
        case .connected(let binding):
            guard let legacy = Self.binding(binding) else {
                fail("capability binding is malformed")
                return
            }
            mode = .finished
            connected?(legacy)
        case .rejected(let reason):
            log?("capability event rejected reason=\(reason)")
        case .fatal(let reason):
            fail(Self.failure(reason))
        }
    }

    private func executeIntent(_ effect: PortableCapabilityIntentEffect) {
        switch effect {
        case .send(let message):
            do { sendWireControl?(try PortableCapabilityIntentWireCodec.encodeData(message)) }
            catch { fail("capability intent transaction encoding failed") }
        case .committed(let binding):
            log?("capability intent binding committed negotiated=\(binding.negotiated)")
        case .connected(let binding):
            guard binding.localIntent == localIntent,
                  binding.peerRole == desiredPeerIntentRole,
                  binding.negotiated,
                  let projected = Self.binding(binding) else {
                fail("capability intent binding does not match authorized Session intent")
                return
            }
            mode = .finished
            connected?(projected)
        case .rejected(let reason):
            fail("capability intent event rejected: \(reason)")
        case .fatal(let reason):
            fail("capability intent negotiation fatal: \(reason)")
        }
    }

    private func fail(_ message: String) {
        guard case .finished = mode else {
            mode = .finished
            failed?(message)
            return
        }
    }
}

private extension RustCapabilityNegotiationDriver {
    static func role(_ value: MediaRole) -> PortableCapabilityRole {
        value == .source ? .host : .receiver
    }

    static func projection(_ value: ProjectionMode) -> PortableCapabilityProjection {
        switch value {
        case .extend: return .extend
        case .mirror: return .mirror
        case .primary: return .primary
        }
    }

    static func projection(_ value: PortableCapabilityProjection) -> ProjectionMode {
        switch value {
        case .extend: return .extend
        case .mirror: return .mirror
        case .primary: return .primary
        }
    }

    static func binding(_ value: PortableCapabilityBinding) -> RustCapabilityBinding? {
        let local: MediaRole = value.localRole == .host ? .source : .sink
        let peer: MediaRole = value.peerRole == .host ? .source : .sink
        guard local != peer, value.transport == .tcp else { return nil }
        return RustCapabilityBinding(
            localRole: local,
            peerRole: peer,
            projection: projection(value.projection),
            negotiated: value.negotiated
        )
    }

    static func binding(_ value: PortableCapabilityIntentBinding) -> RustCapabilityBinding? {
        let local: MediaRole = value.localIntent.localRole == .source ? .source : .sink
        let peer: MediaRole = value.peerRole == .source ? .source : .sink
        guard local != peer else { return nil }
        let projection: ProjectionMode
        switch value.localIntent.sourceTopology {
        case .extend: projection = .extend
        case .mirror: projection = .mirror
        case .primary: projection = .primary
        case .application: return nil
        }
        return .init(
            localRole: local,
            peerRole: peer,
            projection: projection,
            negotiated: value.negotiated
        )
    }

    static func failure(_ reason: PortableCapabilityFatalReason) -> String {
        switch reason {
        case .unsupportedVersion:
            return "capability negotiation version unsupported"
        case .unsupportedCapability:
            return "capability is not authorized"
        case .roleMismatch:
            return "capability role mismatch"
        case .projectionMismatch:
            return "capability projection mismatch"
        case .commitMismatch:
            return "capability commit mismatch"
        }
    }
}
