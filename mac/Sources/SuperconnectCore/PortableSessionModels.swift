public enum PortableSessionError: Error, Equatable, Sendable {
    case coreUnavailable
    case abiVersionMismatch
    case invalidConfiguration
    case invalidIdentity
    case invalidEvent
    case coreFailure(Int32)
    case effectCapacityExceeded(required: Int)
    case malformedEffect
    case malformedSnapshot
}

public enum PortableSessionSide: UInt32, CaseIterable, Equatable, Sendable {
    case initiator = 1
    case responder = 2
}

public enum PortableSessionMediaRole: UInt32, CaseIterable, Equatable, Sendable {
    case host = 1
    case receiver = 2
}

public enum PortableSessionOrigin: UInt32, CaseIterable, Equatable, Sendable {
    case trustedLocal = 1
    case mutualAuthenticationRequired = 2
}

public enum PortableSessionPhase: UInt32, CaseIterable, Equatable, Sendable {
    case idle = 0
    case transport = 1
    case hello = 2
    case credential = 3
    case enrollment = 4
    case mutualAuth = 5
    case admission = 6
    case finalAck = 7
    case capabilityCommit = 8
    case ready = 9
    case streaming = 10
    case closing = 11
    case closed = 12
    case fatal = 13
}

public enum PortableSessionFatalReason: UInt32, CaseIterable, Equatable, Sendable {
    case authenticationRequired = 1
    case authenticationFailed = 2
    case unexpectedReenrollment = 3
    case credentialUnavailable = 4
    case capabilityCommitFailed = 5
    case admissionRejected = 6
    case handshakeTimedOut = 7
    case identifierSpaceExhausted = 8
    case transportFailed = 9
    case finalAckFailed = 10
    case pairingRejected = 11
    case protocolViolation = 12
}

public struct PortableSessionConfiguration: Equatable, Sendable {
    public let generation: PortableSessionGeneration
    public let firstOperationID: PortableSessionOperationID
    public let localEnrollmentKey: PortableSessionArtifactID
    public let side: PortableSessionSide
    public let mediaRole: PortableSessionMediaRole
    public let origin: PortableSessionOrigin
    public let localIdentity: PortableSessionIdentity

    public init(
        generation: PortableSessionGeneration,
        firstOperationID: PortableSessionOperationID,
        localEnrollmentKey: PortableSessionArtifactID,
        side: PortableSessionSide,
        mediaRole: PortableSessionMediaRole,
        origin: PortableSessionOrigin,
        localIdentity: PortableSessionIdentity
    ) {
        self.generation = generation
        self.firstOperationID = firstOperationID
        self.localEnrollmentKey = localEnrollmentKey
        self.side = side
        self.mediaRole = mediaRole
        self.origin = origin
        self.localIdentity = localIdentity
    }
}

public enum PortableSessionCredentialState: Equatable, Sendable {
    case missing
    case present(PortableSessionArtifactID)
    case unavailable
}

public enum PortableSessionEvent: Equatable, Sendable {
    case start
    case transportOpened(operation: PortableSessionOperationID)
    case peerHelloAck(
        peer: PortableSessionIdentity,
        authVersion: UInt16?,
        challenge: PortableSessionArtifactID?,
        enrollment: Bool,
        peerEnrollmentKey: PortableSessionArtifactID?
    )
    case peerHello(
        peer: PortableSessionIdentity,
        authVersion: UInt16?,
        peerEnrollmentKey: PortableSessionArtifactID?
    )
    case credentialLoaded(
        operation: PortableSessionOperationID,
        state: PortableSessionCredentialState
    )
    case enrollmentOpened(
        operation: PortableSessionOperationID,
        candidateCredential: PortableSessionArtifactID
    )
    case enrollmentApproved(operation: PortableSessionOperationID, approved: Bool)
    case enrollmentPrepared(
        operation: PortableSessionOperationID,
        candidateCredential: PortableSessionArtifactID,
        challenge: PortableSessionArtifactID,
        envelope: PortableSessionArtifactID
    )
    case challengeGenerated(
        operation: PortableSessionOperationID,
        challenge: PortableSessionArtifactID
    )
    case authProofCreated(
        operation: PortableSessionOperationID,
        proof: PortableSessionArtifactID,
        localChallenge: PortableSessionArtifactID
    )
    case peerAuth(proof: PortableSessionArtifactID, peerChallenge: PortableSessionArtifactID)
    case peerProofVerified(operation: PortableSessionOperationID, valid: Bool)
    case admissionClaimSucceeded(
        operation: PortableSessionOperationID,
        claim: PortableSessionAdmissionClaimID
    )
    case admissionClaimFailed(operation: PortableSessionOperationID)
    case mutualProofCreated(
        operation: PortableSessionOperationID,
        proof: PortableSessionArtifactID
    )
    case peerAuthAck(proof: PortableSessionArtifactID)
    case mutualProofVerified(operation: PortableSessionOperationID, valid: Bool)
    case credentialWriteCompleted(operation: PortableSessionOperationID, success: Bool)
    case finalAckSubmitted(operation: PortableSessionOperationID, success: Bool)
    case capabilitiesCommitted(operation: PortableSessionOperationID, success: Bool)
    case streamingStarted
    case closeRequested
    case transportClosed
    case transportFailed
    case timerFired(token: PortableSessionTimerToken)
}

public enum PortableSessionEffectKind: UInt32, CaseIterable, Equatable, Sendable {
    case openTransport = 1
    case armHandshakeTimer = 2
    case cancelHandshakeTimer = 3
    case sendHello = 4
    case loadCredential = 5
    case openEnrollment = 6
    case requestEnrollmentApproval = 7
    case prepareEnrollment = 8
    case generateChallenge = 9
    case sendHelloAck = 10
    case sendEnrollment = 11
    case createAuthProof = 12
    case verifyPeerProof = 13
    case claimAdmission = 14
    case createMutualProof = 15
    case submitFinalAuthAck = 16
    case submitFinalHelloAck = 17
    case sendAuth = 18
    case verifyMutualProof = 19
    case writeCredential = 20
    case cancelCredentialWrite = 21
    case commitCapabilities = 22
    case notifyReady = 23
    case notifyStreaming = 24
    case closeTransport = 25
    case notifyClosed = 26
    case releaseAdmission = 27
    case notifyFatal = 28
}

public struct PortableSessionEffect: Equatable, Sendable {
    public let kind: PortableSessionEffectKind
    public let generation: PortableSessionGeneration?
    public let operation: PortableSessionOperationID?
    public let timerToken: PortableSessionTimerToken?
    public let admissionClaim: PortableSessionAdmissionClaimID?
    public let credential: PortableSessionArtifactID?
    public let candidateCredential: PortableSessionArtifactID?
    public let challenge: PortableSessionArtifactID?
    public let localChallenge: PortableSessionArtifactID?
    public let peerChallenge: PortableSessionArtifactID?
    public let proof: PortableSessionArtifactID?
    public let envelope: PortableSessionArtifactID?
    public let localEnrollmentKey: PortableSessionArtifactID?
    public let peerEnrollmentKey: PortableSessionArtifactID?
    public let authVersion: UInt16?
    public let mediaRole: PortableSessionMediaRole?
    public let enrollment: Bool
    public let identity: PortableSessionIdentity?
    public let fatalReason: PortableSessionFatalReason?

    init(
        kind: PortableSessionEffectKind,
        generation: PortableSessionGeneration? = nil,
        operation: PortableSessionOperationID? = nil,
        timerToken: PortableSessionTimerToken? = nil,
        admissionClaim: PortableSessionAdmissionClaimID? = nil,
        credential: PortableSessionArtifactID? = nil,
        candidateCredential: PortableSessionArtifactID? = nil,
        challenge: PortableSessionArtifactID? = nil,
        localChallenge: PortableSessionArtifactID? = nil,
        peerChallenge: PortableSessionArtifactID? = nil,
        proof: PortableSessionArtifactID? = nil,
        envelope: PortableSessionArtifactID? = nil,
        localEnrollmentKey: PortableSessionArtifactID? = nil,
        peerEnrollmentKey: PortableSessionArtifactID? = nil,
        authVersion: UInt16? = nil,
        mediaRole: PortableSessionMediaRole? = nil,
        enrollment: Bool = false,
        identity: PortableSessionIdentity? = nil,
        fatalReason: PortableSessionFatalReason? = nil
    ) {
        self.kind = kind
        self.generation = generation
        self.operation = operation
        self.timerToken = timerToken
        self.admissionClaim = admissionClaim
        self.credential = credential
        self.candidateCredential = candidateCredential
        self.challenge = challenge
        self.localChallenge = localChallenge
        self.peerChallenge = peerChallenge
        self.proof = proof
        self.envelope = envelope
        self.localEnrollmentKey = localEnrollmentKey
        self.peerEnrollmentKey = peerEnrollmentKey
        self.authVersion = authVersion
        self.mediaRole = mediaRole
        self.enrollment = enrollment
        self.identity = identity
        self.fatalReason = fatalReason
    }
}

public struct PortableSessionSnapshot: Equatable, Sendable {
    public let generation: PortableSessionGeneration
    public let firstOperationID: PortableSessionOperationID
    public let localEnrollmentKey: PortableSessionArtifactID
    public let phase: PortableSessionPhase
    public let side: PortableSessionSide
    public let mediaRole: PortableSessionMediaRole
    public let origin: PortableSessionOrigin
    public let pendingTimerCount: UInt32
    public let pendingOperationCount: UInt32
    public let invariantsHold: Bool
    public let localIdentity: PortableSessionIdentity

    init(
        generation: PortableSessionGeneration,
        firstOperationID: PortableSessionOperationID,
        localEnrollmentKey: PortableSessionArtifactID,
        phase: PortableSessionPhase,
        side: PortableSessionSide,
        mediaRole: PortableSessionMediaRole,
        origin: PortableSessionOrigin,
        pendingTimerCount: UInt32,
        pendingOperationCount: UInt32,
        invariantsHold: Bool,
        localIdentity: PortableSessionIdentity
    ) {
        self.generation = generation
        self.firstOperationID = firstOperationID
        self.localEnrollmentKey = localEnrollmentKey
        self.phase = phase
        self.side = side
        self.mediaRole = mediaRole
        self.origin = origin
        self.pendingTimerCount = pendingTimerCount
        self.pendingOperationCount = pendingOperationCount
        self.invariantsHold = invariantsHold
        self.localIdentity = localIdentity
    }
}
