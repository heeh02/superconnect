import Foundation

final class RustInitiatorSessionDriver {
    private enum CredentialLoad {
        case missing, present(PortableSessionArtifactID), unavailable
    }
    private struct EnrollmentOpen {
        let operation: PortableSessionOperationID
        let peerKey: PortableSessionArtifactID
    }

    var openTransport: (() -> Void)?
    var stopTransport: (() -> Void)?
    var sendHello: ((Data) -> Void)?
    var sendAuth: ((_ proof: Data, _ localChallenge: Data) -> Void)?
    var notifyReady: (() -> Void)?
    var notifyClosed: (() -> Void)?
    var notifyError: ((String) -> Void)?
    var log: ((String) -> Void)?
    /// Test-only ownership probe; it reports zeroization without exposing artifact bytes.
    var artifactCleanupProbeForTesting: ((UInt64, Bool) -> Void)?

    private let runtime: PortableSecureConnectionRuntime
    private let store: PairSecretStore?
    private let crypto: any SessionAuthCryptography
    private let timer: SessionTimerDriving
    private let localPeerID: String
    private let trustedLocal: Bool
    private let lock = NSRecursiveLock()
    private var artifacts = [UInt64: RustInitiatorArtifact]()
    private var nextArtifact: UInt64 = 100
    private var openOperation: PortableSessionOperationID?
    private var peerID: String?
    private var enrollmentOpen: EnrollmentOpen?
    private var candidateCredential: PortableSessionArtifactID?
    private var capabilityCommitRequest: (() -> Void)?
    private var capabilityOperation: PortableSessionOperationID?
    private var terminalError: String?
    private var pendingRecordMaterial: (secret: Data, responderChallenge: Data,
                                        initiatorChallenge: Data)?

    private static let generationLock = NSLock()
    private static var nextGeneration: UInt64 = 1

    var generation: UInt64 { runtime.generation.rawValue }

    init(
        localPeerID: String,
        localRole: MediaRole,
        trustedLocal: Bool,
        store: PairSecretStore?,
        crypto: any SessionAuthCryptography,
        timer: SessionTimerDriving = DispatchSessionTimerDriver()
    ) throws {
        self.localPeerID = localPeerID
        self.trustedLocal = trustedLocal
        self.store = store
        self.crypto = crypto
        self.timer = timer
        runtime = try PortableSecureConnectionRuntime(configuration: PortableSessionConfiguration(
            generation: Self.allocateGeneration(),
            firstOperationID: PortableSessionOperationID(rawValue: 2)!,
            localEnrollmentKey: PortableSessionArtifactID(rawValue: 1)!,
            side: .initiator,
            mediaRole: localRole == .source ? .host : .receiver,
            origin: trustedLocal ? .trustedLocal : .mutualAuthenticationRequired,
            localIdentity: try PortableSessionIdentity(localPeerID)
        ))
        var privateKey = AuthCrypto.newEphemeralPrivateScalar()
        defer { Self.wipe(&privateKey) }
        let publicKey = try crypto.publicKey(privateScalar: privateKey)
        artifacts[runtime.localEnrollmentKey.rawValue] = .enrollmentKey(
            privateKey: RustInitiatorSensitiveArtifactBuffer(privateKey),
            publicKey: RustInitiatorSensitiveArtifactBuffer(publicKey))
    }

    deinit { clearSensitiveArtifacts() }

    func start() { lock.lock(); defer { lock.unlock() }; drive(.start) }

    func transportReady() {
        lock.lock(); defer { lock.unlock() }
        guard let operation = openOperation else { return failLocal("transport operation missing") }
        drive(.transportOpened(operation: operation))
    }

    func receiveHelloAck(
        peer: String,
        authVersion: Int?,
        recordVersion: Int?,
        challenge: Data?,
        enrollment: Bool,
        peerEnrollmentKey: Data?,
        commit: @escaping () -> Void
    ) {
        lock.lock(); defer { lock.unlock() }
        let challengeID = challenge.map(artifact)
        let peerKeyID = peerEnrollmentKey.map(artifact)
        let version = authVersion.flatMap { UInt16(exactly: $0) }
        do {
            execute(try runtime.observeRecordVersion(recordVersion))
            let identity = try PortableSessionIdentity(peer)
            let effects = try runtime.apply(.peerHelloAck(
                peer: identity,
                authVersion: version,
                challenge: challengeID,
                enrollment: enrollment,
                peerEnrollmentKey: peerKeyID
            ))
            guard !effects.isEmpty else {
                if let challengeID { removeArtifact(challengeID.rawValue) }
                if let peerKeyID { removeArtifact(peerKeyID.rawValue) }
                return
            }
            if !trustedLocal {
                do {
                    try crypto.validatePeerID(localPeerID)
                    try crypto.validatePeerID(peer)
                } catch { return failTransport("invalid peer identity") }
            }
            peerID = peer
            capabilityCommitRequest = commit
            execute(effects)
        } catch { failTransport("invalid hello_ack") }
    }

    func receivePairSecret(sealed: Data?, salt: Data?, nonce: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard let pending = enrollmentOpen else { return }
        guard let sealed, let salt, let nonce, var peerKey = bytes(pending.peerKey),
              case .enrollmentKey(let privateKey, _) =
                artifacts[runtime.localEnrollmentKey.rawValue]
        else { return failTransport("malformed pair_secret") }
        var privateScalar = privateKey.data
        defer {
            Self.wipe(&peerKey)
            Self.wipe(&privateScalar)
        }
        do {
            var key = try crypto.derivePairKey(
                privateScalar: privateScalar, peerPublicKey: peerKey, salt: salt)
            defer { Self.wipe(&key) }
            var secret = try crypto.openPairSecret(sealed, pairKey: key, nonce: nonce)
            defer { Self.wipe(&secret) }
            let credential = artifact(secret)
            candidateCredential = credential
            enrollmentOpen = nil
            drive(.enrollmentOpened(
                operation: pending.operation,
                candidateCredential: credential
            ))
        } catch { failTransport("enrollment decrypt failed") }
    }

    func receiveAuthAck(proof: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard let proof else { return failTransport("malformed auth_ack") }
        let proofID = artifact(proof)
        do {
            let effects = try runtime.apply(.peerAuthAck(proof: proofID))
            if effects.isEmpty { removeArtifact(proofID.rawValue) }
            execute(effects)
        } catch { failTransport("invalid auth_ack") }
    }

    func transportFailed(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        terminalError = "transport failed: \(message)"
        drive(.transportFailed)
    }

    func transportClosed() { lock.lock(); defer { lock.unlock() }; drive(.transportClosed) }
    func closeRequested() { lock.lock(); defer { lock.unlock() }; drive(.closeRequested) }

    func capabilityCommitCompleted(_ success: Bool, failure: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let operation = capabilityOperation else { return }
        capabilityOperation = nil
        if let failure { terminalError = failure }
        drive(.capabilitiesCommitted(operation: operation, success: success))
    }

    func fireTimerForTesting(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let token = PortableSessionTimerToken(rawValue: token) else {
            return failLocal("timer token invalid")
        }
        drive(.timerFired(token: token))
    }
    func phaseForTesting() -> PortableSessionPhase? {
        lock.lock(); defer { lock.unlock() }; return try? runtime.phase()
    }
    func sensitiveHandshakeStateIsClearForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return artifacts.isEmpty && pendingRecordMaterial == nil
            && candidateCredential == nil && enrollmentOpen == nil
    }

    func hasAuthenticatedRecords() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? runtime.snapshot().recordsActive) == true
    }

    func frameOutbound(channel: UInt8, flags: UInt8, payload: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        do { return try runtime.sealFrame(channel: channel, flags: flags, plaintext: payload) }
        catch { handleDataPlaneFailure("SC-RECORD-v1 seal failed"); return nil }
    }

    func authenticatedPayload(channel: UInt8, flags: UInt8, payload: Data) -> Data? {
        guard hasAuthenticatedRecords(),
              let frame = frameOutbound(channel: channel, flags: flags, payload: payload),
              frame.count >= 6, frame[0] == channel, frame[1] == 0 else { return nil }
        let declared = frame[2..<6].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard declared == frame.count - 6 else { return nil }
        return Data(frame.dropFirst(6))
    }

    func receiveBytes(_ bytes: Data) -> [PortableSecureInboundFrame]? {
        lock.lock(); defer { lock.unlock() }
        let recordsWereActive = (try? runtime.snapshot().recordsActive) == true
        do { return try exactlyOneOrEmpty(try runtime.push(bytes)) }
        catch {
            handleDataPlaneFailure(
                recordsWereActive
                    ? "SC-RECORD-v1 authentication failed"
                    : "portable CONTROL classifier rejected payload")
            return nil
        }
    }

    /// Expose one frame buffered behind the last socket read. Session calls this only after it has
    /// routed the previous frame and all resulting typed effects have completed; the explicit empty
    /// push is part of the Core ABI state barrier, not an opportunistic polling loop.
    func receiveBufferedBytes() -> [PortableSecureInboundFrame]? {
        lock.lock(); defer { lock.unlock() }
        let recordsWereActive = (try? runtime.snapshot().recordsActive) == true
        do { return try exactlyOneOrEmpty(try runtime.pushBuffered()) }
        catch {
            handleDataPlaneFailure(
                recordsWereActive
                    ? "SC-RECORD-v1 authentication failed"
                    : "portable CONTROL classifier rejected payload")
            return nil
        }
    }

    private func exactlyOneOrEmpty(
        _ frames: [PortableSecureInboundFrame]
    ) throws -> [PortableSecureInboundFrame] {
        guard frames.count <= 1 else {
            throw PortableSecureConnectionError.inboundBatchViolation
        }
        return frames
    }

    private func drive(_ event: PortableSessionEvent) {
        do { execute(try runtime.apply(event)) }
        catch { failLocal("Rust session ABI failure") }
    }

    private func execute(_ effects: [PortableSecureConnectionEffect]) {
        for effect in effects {
            switch effect {
            case .session(let sessionEffect): executeSession(sessionEffect)
            case .prepareRecordContext(let generation, let operation):
                guard generation.rawValue == runtime.generation.rawValue else {
                    return failLocal("record generation mismatch")
                }
                prepareRecordContext(operation)
            case .activateRecords(let generation, let operation):
                guard generation.rawValue == runtime.generation.rawValue else {
                    return failLocal("record activation generation mismatch")
                }
                do { execute(try runtime.recordsActivated(operation: operation, success: true)) }
                catch { failTransport("record activation completion failed") }
            case .disposeRecords:
                clearSensitiveArtifacts()
            }
        }
    }

    private func executeSession(_ effect: PortableSessionEffect) {
        var shouldStop = false
        switch effect.kind {
            case .openTransport:
                openOperation = effect.operation; openTransport?()
            case .armHandshakeTimer:
                guard let token = effect.timerToken else {
                    return failLocal("timer token missing")
                }
                timer.arm(token: token.rawValue) { [weak self] in self?.fireTimerForTesting($0) }
            case .cancelHandshakeTimer:
                if let token = effect.timerToken { timer.cancel(token: token.rawValue) }
            case .sendHello:
                guard let keyID = effect.localEnrollmentKey,
                      case .enrollmentKey(_, let publicKey) = artifacts[keyID.rawValue]
                else { return failTransport("local enrollment key missing") }
                sendHello?(publicKey.data)
            case .loadCredential:
                loadCredential(effect)
            case .openEnrollment:
                guard let operation = effect.operation, let peerKey = effect.peerEnrollmentKey else {
                    return failTransport("enrollment artifacts missing")
                }
                enrollmentOpen = EnrollmentOpen(operation: operation, peerKey: peerKey)
            case .createAuthProof:
                createAuthProof(effect)
            case .sendAuth:
                guard var proof = effect.proof.flatMap(bytes),
                      var challenge = effect.challenge.flatMap(bytes) else {
                    return failTransport("auth artifacts missing")
                }
                defer {
                    Self.wipe(&proof)
                    Self.wipe(&challenge)
                }
                sendAuth?(proof, challenge)
            case .verifyMutualProof:
                verifyMutualProof(effect)
            case .writeCredential:
                writeCredential(effect)
            case .cancelCredentialWrite:
                candidateCredential = nil
            case .commitCapabilities:
                guard let operation = effect.operation, capabilityOperation == nil,
                      let capabilityCommitRequest else {
                    return failTransport("capability operation missing")
                }
                capabilityOperation = operation
                capabilityCommitRequest()
            case .notifyReady:
                clearSensitiveArtifacts()
                notifyReady?()
            case .closeTransport:
                shouldStop = true
            case .notifyClosed:
                capabilityOperation = nil
                clearSensitiveArtifacts()
                notifyClosed?()
            case .notifyFatal:
                capabilityOperation = nil
                clearSensitiveArtifacts()
                notifyError?(fatalMessage(effect.fatalReason))
            case .notifyStreaming, .requestEnrollmentApproval, .prepareEnrollment,
                 .generateChallenge, .sendHelloAck, .sendEnrollment, .verifyPeerProof,
                 .claimAdmission, .createMutualProof, .submitFinalAuthAck,
                 .submitFinalHelloAck, .releaseAdmission:
                failLocal("unexpected initiator effect \(effect.kind)")
        }
        if shouldStop { stopTransport?() }
    }

    private func loadCredential(_ effect: PortableSessionEffect) {
        guard let operation = effect.operation, let peerID else {
            return failTransport("credential identity missing")
        }
        let result: CredentialLoad
        if let store, var secret = store.secret(for: peerID) {
            defer { Self.wipe(&secret) }
            result = .present(artifact(secret))
        } else if store != nil {
            result = .missing
        } else { result = .unavailable }
        switch result {
        case .missing: driveCredential(operation, nil, unavailable: false)
        case .present(let credential): driveCredential(operation, credential, unavailable: false)
        case .unavailable: driveCredential(operation, nil, unavailable: true)
        }
    }

    private func driveCredential(
        _ operation: PortableSessionOperationID,
        _ credential: PortableSessionArtifactID?,
        unavailable: Bool
    ) {
        let state: PortableSessionCredentialState
        if let credential { state = .present(credential) }
        else { state = unavailable ? .unavailable : .missing }
        drive(.credentialLoaded(operation: operation, state: state))
    }

    private func createAuthProof(_ effect: PortableSessionEffect) {
        guard let operation = effect.operation, var credential = effect.credential.flatMap(bytes),
              var tabletChallenge = effect.challenge.flatMap(bytes), let peerID else {
            return failTransport("proof artifacts missing")
        }
        defer {
            Self.wipe(&credential)
            Self.wipe(&tabletChallenge)
        }
        do {
            let direction = SessionAuthProofDirection.macToTablet(
                macPeerID: localPeerID, tabletPeerID: peerID, tabletNonce: tabletChallenge)
            var proof = try crypto.createProof(secret: credential, direction: direction)
            defer { Self.wipe(&proof) }
            var localChallenge = AuthCrypto.randomBytes(32)
            defer { Self.wipe(&localChallenge) }
            pendingRecordMaterial = (credential, tabletChallenge, localChallenge)
            drive(.authProofCreated(
                operation: operation,
                proof: artifact(proof),
                localChallenge: artifact(localChallenge)
            ))
        } catch { failTransport("authentication proof creation failed") }
    }

    private func verifyMutualProof(_ effect: PortableSessionEffect) {
        guard let operation = effect.operation, var credential = effect.credential.flatMap(bytes),
              var challenge = effect.challenge.flatMap(bytes),
              var proof = effect.proof.flatMap(bytes), let peerID else {
            return failTransport("mutual proof artifacts missing")
        }
        defer {
            Self.wipe(&credential)
            Self.wipe(&challenge)
            Self.wipe(&proof)
        }
        do {
            let direction = SessionAuthProofDirection.tabletToMac(
                macPeerID: localPeerID, tabletPeerID: peerID, macNonce: challenge)
            try crypto.verifyProof(proof, secret: credential, direction: direction)
            drive(.mutualProofVerified(operation: operation, valid: true))
        } catch { drive(.mutualProofVerified(operation: operation, valid: false)) }
    }

    private func prepareRecordContext(_ operation: PortableSessionOperationID) {
        guard var material = pendingRecordMaterial else {
            do {
                execute(try runtime.recordMaterialPrepared(
                    operation: operation, secret: nil,
                    responderChallenge: nil, initiatorChallenge: nil))
            } catch { failTransport("record material rejection failed") }
            return
        }
        pendingRecordMaterial = nil
        defer {
            material.secret.resetBytes(in: 0..<material.secret.count)
            material.responderChallenge.resetBytes(in: 0..<material.responderChallenge.count)
            material.initiatorChallenge.resetBytes(in: 0..<material.initiatorChallenge.count)
        }
        do {
            execute(try runtime.recordMaterialPrepared(
                operation: operation, secret: material.secret,
                responderChallenge: material.responderChallenge,
                initiatorChallenge: material.initiatorChallenge))
        } catch { failTransport("record material preparation failed") }
    }

    private func writeCredential(_ effect: PortableSessionEffect) {
        guard let operation = effect.operation, let credentialID = effect.credential,
              candidateCredential == credentialID, var secret = bytes(credentialID),
              let peerID, let store else {
            if let operation = effect.operation {
                drive(.credentialWriteCompleted(operation: operation, success: false))
            }
            return
        }
        defer { Self.wipe(&secret) }
        let success: Bool
        switch store.storeIfAbsent(secret, for: peerID) {
        case .inserted, .unchanged:
            if var persisted = store.secret(for: peerID) {
                success = persisted == secret
                Self.wipe(&persisted)
            } else {
                success = false
            }
        case .conflict, .unavailable: success = false
        }
        drive(.credentialWriteCompleted(operation: operation, success: success))
        if success { candidateCredential = nil }
    }

    private func artifact(_ data: Data) -> PortableSessionArtifactID {
        precondition(nextArtifact != UInt64.max, "session artifact identifiers exhausted")
        let rawValue = nextArtifact
        nextArtifact += 1
        artifacts[rawValue] = .bytes(RustInitiatorSensitiveArtifactBuffer(data))
        return PortableSessionArtifactID(rawValue: rawValue)!
    }
    private func bytes(_ id: PortableSessionArtifactID) -> Data? {
        artifacts[id.rawValue]?.data
    }
    private func failTransport(_ message: String) { terminalError = message; drive(.transportFailed) }
    private func failLocal(_ message: String) { notifyError?(message); stopTransport?() }
    private func fatalMessage(_ reason: PortableSessionFatalReason?) -> String {
        if let terminalError { return terminalError }
        switch reason {
        case .authenticationRequired: return "auth_required"
        case .authenticationFailed, .unexpectedReenrollment, .credentialUnavailable:
            return "auth_failed"
        case .pairingRejected: return "pairing_rejected"
        case .capabilityCommitFailed: return "role_negotiation_failed"
        case .handshakeTimedOut: return "auth_timeout"
        default: return "session_failed"
        }
    }

    private func handleDataPlaneFailure(_ message: String) {
        terminalError = "transport failed: \(message)"
        if let effects = try? runtime.takeEffects(), !effects.isEmpty {
            execute(effects)
        } else {
            failTransport(message)
        }
    }

    private func clearSensitiveArtifacts() {
        if var material = pendingRecordMaterial {
            pendingRecordMaterial = nil
            material.secret.resetBytes(in: 0..<material.secret.count)
            material.responderChallenge.resetBytes(in: 0..<material.responderChallenge.count)
            material.initiatorChallenge.resetBytes(in: 0..<material.initiatorChallenge.count)
        }
        for key in Array(artifacts.keys) {
            removeArtifact(key)
        }
        candidateCredential = nil
        enrollmentOpen = nil
        capabilityCommitRequest = nil
    }

    private func removeArtifact(_ rawValue: UInt64) {
        guard let artifact = artifacts[rawValue] else { return }
        artifact.clear()
        artifactCleanupProbeForTesting?(rawValue, artifact.isZeroed)
        artifacts[rawValue] = nil
    }

    private static func wipe(_ data: inout Data) {
        data.resetBytes(in: data.startIndex..<data.endIndex)
    }

    private static func allocateGeneration() -> PortableSessionGeneration {
        generationLock.lock()
        defer { generationLock.unlock() }
        precondition(nextGeneration != UInt64.max, "session generation exhausted")
        let value = nextGeneration
        nextGeneration += 1
        return PortableSessionGeneration(rawValue: value)!
    }
}
