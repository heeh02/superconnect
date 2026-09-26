import SuperconnectCoreFFI

extension PortableSessionFFICodec {
    static func encodeEvent(
        _ event: PortableSessionEvent,
        generation: PortableSessionGeneration
    ) -> ScSessionEventV1 {
        var output = ScSessionEventV1()
        output.struct_size = UInt32(MemoryLayout<ScSessionEventV1>.size)
        output.api_version = UInt32(SC_API_VERSION_V1)
        output.presence = generationField
        output.generation = generation.rawValue

        func operation(_ value: PortableSessionOperationID) {
            output.presence |= operationField
            output.operation = value.rawValue
        }
        func identity(_ value: PortableSessionIdentity) {
            output.presence |= identityField
            output.peer_identity = encodeIdentity(value)
        }

        switch event {
        case .start:
            output.type = UInt32(SC_SESSION_EVENT_START)
        case .transportOpened(let id):
            output.type = UInt32(SC_SESSION_EVENT_TRANSPORT_OPENED)
            operation(id)
        case let .peerHelloAck(peer, authVersion, challenge, enrollment, peerEnrollmentKey):
            output.type = UInt32(SC_SESSION_EVENT_PEER_HELLO_ACK)
            identity(peer)
            if let authVersion {
                output.presence |= authVersionField
                output.auth_version = authVersion
            }
            if let challenge {
                output.presence |= challengeField
                output.challenge = challenge.rawValue
            }
            output.enrollment = enrollment ? 1 : 0
            if let peerEnrollmentKey {
                output.presence |= peerEnrollmentKeyField
                output.peer_enrollment_key = peerEnrollmentKey.rawValue
            }
        case let .peerHello(peer, authVersion, peerEnrollmentKey):
            output.type = UInt32(SC_SESSION_EVENT_PEER_HELLO)
            identity(peer)
            if let authVersion {
                output.presence |= authVersionField
                output.auth_version = authVersion
            }
            if let peerEnrollmentKey {
                output.presence |= peerEnrollmentKeyField
                output.peer_enrollment_key = peerEnrollmentKey.rawValue
            }
        case let .credentialLoaded(id, state):
            output.type = UInt32(SC_SESSION_EVENT_CREDENTIAL_LOADED)
            operation(id)
            switch state {
            case .missing:
                output.credential_state = UInt32(SC_SESSION_CREDENTIAL_MISSING)
            case .present(let credential):
                output.credential_state = UInt32(SC_SESSION_CREDENTIAL_PRESENT)
                output.presence |= credentialField
                output.credential = credential.rawValue
            case .unavailable:
                output.credential_state = UInt32(SC_SESSION_CREDENTIAL_UNAVAILABLE)
            }
        case let .enrollmentOpened(id, candidate):
            output.type = UInt32(SC_SESSION_EVENT_ENROLLMENT_OPENED)
            operation(id)
            output.presence |= candidateCredentialField
            output.candidate_credential = candidate.rawValue
        case let .enrollmentApproved(id, approved):
            output.type = UInt32(SC_SESSION_EVENT_ENROLLMENT_APPROVED)
            operation(id)
            output.approved = approved ? 1 : 0
        case let .enrollmentPrepared(id, candidate, challenge, envelope):
            output.type = UInt32(SC_SESSION_EVENT_ENROLLMENT_PREPARED)
            operation(id)
            output.presence |= candidateCredentialField | challengeField | envelopeField
            output.candidate_credential = candidate.rawValue
            output.challenge = challenge.rawValue
            output.envelope = envelope.rawValue
        case let .challengeGenerated(id, challenge):
            output.type = UInt32(SC_SESSION_EVENT_CHALLENGE_GENERATED)
            operation(id)
            output.presence |= challengeField
            output.challenge = challenge.rawValue
        case let .authProofCreated(id, proof, localChallenge):
            output.type = UInt32(SC_SESSION_EVENT_AUTH_PROOF_CREATED)
            operation(id)
            output.presence |= proofField | localChallengeField
            output.proof = proof.rawValue
            output.local_challenge = localChallenge.rawValue
        case let .peerAuth(proof, peerChallenge):
            output.type = UInt32(SC_SESSION_EVENT_PEER_AUTH)
            output.presence |= proofField | peerChallengeField
            output.proof = proof.rawValue
            output.peer_challenge = peerChallenge.rawValue
        case let .peerProofVerified(id, valid):
            output.type = UInt32(SC_SESSION_EVENT_PEER_PROOF_VERIFIED)
            operation(id)
            output.valid = valid ? 1 : 0
        case let .admissionClaimSucceeded(id, claim):
            output.type = UInt32(SC_SESSION_EVENT_ADMISSION_CLAIM_SUCCEEDED)
            operation(id)
            output.presence |= claimField
            output.admission_claim = claim.rawValue
        case let .admissionClaimFailed(id):
            output.type = UInt32(SC_SESSION_EVENT_ADMISSION_CLAIM_FAILED)
            operation(id)
        case let .mutualProofCreated(id, proof):
            output.type = UInt32(SC_SESSION_EVENT_MUTUAL_PROOF_CREATED)
            operation(id)
            output.presence |= proofField
            output.proof = proof.rawValue
        case .peerAuthAck(let proof):
            output.type = UInt32(SC_SESSION_EVENT_PEER_AUTH_ACK)
            output.presence |= proofField
            output.proof = proof.rawValue
        case let .mutualProofVerified(id, valid):
            output.type = UInt32(SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED)
            operation(id)
            output.valid = valid ? 1 : 0
        case let .credentialWriteCompleted(id, success):
            output.type = UInt32(SC_SESSION_EVENT_CREDENTIAL_WRITE_COMPLETED)
            operation(id)
            output.success = success ? 1 : 0
        case let .finalAckSubmitted(id, success):
            output.type = UInt32(SC_SESSION_EVENT_FINAL_ACK_SUBMITTED)
            operation(id)
            output.success = success ? 1 : 0
        case let .capabilitiesCommitted(id, success):
            output.type = UInt32(SC_SESSION_EVENT_CAPABILITIES_COMMITTED)
            operation(id)
            output.success = success ? 1 : 0
        case .streamingStarted:
            output.type = UInt32(SC_SESSION_EVENT_STREAMING_STARTED)
        case .closeRequested:
            output.type = UInt32(SC_SESSION_EVENT_CLOSE_REQUESTED)
        case .transportClosed:
            output.type = UInt32(SC_SESSION_EVENT_TRANSPORT_CLOSED)
        case .transportFailed:
            output.type = UInt32(SC_SESSION_EVENT_TRANSPORT_FAILED)
        case .timerFired(let token):
            output.type = UInt32(SC_SESSION_EVENT_TIMER_FIRED)
            output.presence |= timerField
            output.timer_token = token.rawValue
        }
        return output
    }
}
