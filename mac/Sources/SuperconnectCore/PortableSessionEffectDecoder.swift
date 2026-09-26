import SuperconnectCoreFFI

extension PortableSessionFFICodec {
    private struct EffectShape {
        let required: UInt64
        let optional: UInt64
        let hasMediaRole: Bool
        let hasEnrollmentFlag: Bool
        let hasFatalReason: Bool

        init(
            _ required: UInt64 = 0,
            optional: UInt64 = 0,
            mediaRole: Bool = false,
            enrollment: Bool = false,
            fatal: Bool = false
        ) {
            self.required = required
            self.optional = optional
            hasMediaRole = mediaRole
            hasEnrollmentFlag = enrollment
            hasFatalReason = fatal
        }
    }

    static func decodeEffect(_ input: ScSessionEffectV1) throws -> PortableSessionEffect {
        guard input.struct_size == UInt32(MemoryLayout<ScSessionEffectV1>.size),
              input.api_version == UInt32(SC_API_VERSION_V1),
              input.reserved0 == 0, input.reserved1 == 0, input.reserved2 == 0,
              input.presence & ~knownFields == 0,
              input.enrollment <= 1,
              let kind = PortableSessionEffectKind(rawValue: input.type),
              fieldsAreCanonical(input) else {
            throw PortableSessionError.malformedEffect
        }
        let shape = effectShape(kind)
        guard input.presence & shape.required == shape.required,
              input.presence & ~(shape.required | shape.optional) == 0,
              shape.hasEnrollmentFlag || input.enrollment == 0 else {
            throw PortableSessionError.malformedEffect
        }

        let mediaRole: PortableSessionMediaRole?
        if shape.hasMediaRole {
            guard let value = PortableSessionMediaRole(rawValue: UInt32(input.media_role)) else {
                throw PortableSessionError.malformedEffect
            }
            mediaRole = value
        } else {
            guard input.media_role == 0 else { throw PortableSessionError.malformedEffect }
            mediaRole = nil
        }

        let fatalReason: PortableSessionFatalReason?
        if shape.hasFatalReason {
            guard let value = PortableSessionFatalReason(rawValue: input.fatal_reason) else {
                throw PortableSessionError.malformedEffect
            }
            fatalReason = value
        } else {
            guard input.fatal_reason == UInt32(SC_SESSION_FATAL_NONE) else {
                throw PortableSessionError.malformedEffect
            }
            fatalReason = nil
        }

        let identity: PortableSessionIdentity?
        if input.presence & identityField == 0 {
            identity = nil
        } else {
            identity = try decodeIdentity(input.identity)
        }

        return PortableSessionEffect(
            kind: kind,
            generation: try optional(input.presence, generationField, input.generation) {
                PortableSessionGeneration(rawValue: $0)
            },
            operation: try optional(input.presence, operationField, input.operation) {
                PortableSessionOperationID(rawValue: $0)
            },
            timerToken: try optional(input.presence, timerField, input.timer_token) {
                PortableSessionTimerToken(rawValue: $0)
            },
            admissionClaim: try optional(input.presence, claimField, input.admission_claim) {
                PortableSessionAdmissionClaimID(rawValue: $0)
            },
            credential: try optional(input.presence, credentialField, input.credential) {
                PortableSessionArtifactID(rawValue: $0)
            },
            candidateCredential: try optional(
                input.presence,
                candidateCredentialField,
                input.candidate_credential
            ) { PortableSessionArtifactID(rawValue: $0) },
            challenge: try optional(input.presence, challengeField, input.challenge) {
                PortableSessionArtifactID(rawValue: $0)
            },
            localChallenge: try optional(
                input.presence,
                localChallengeField,
                input.local_challenge
            ) { PortableSessionArtifactID(rawValue: $0) },
            peerChallenge: try optional(
                input.presence,
                peerChallengeField,
                input.peer_challenge
            ) { PortableSessionArtifactID(rawValue: $0) },
            proof: try optional(input.presence, proofField, input.proof) {
                PortableSessionArtifactID(rawValue: $0)
            },
            envelope: try optional(input.presence, envelopeField, input.envelope) {
                PortableSessionArtifactID(rawValue: $0)
            },
            localEnrollmentKey: try optional(
                input.presence,
                localEnrollmentKeyField,
                input.local_enrollment_key
            ) { PortableSessionArtifactID(rawValue: $0) },
            peerEnrollmentKey: try optional(
                input.presence,
                peerEnrollmentKeyField,
                input.peer_enrollment_key
            ) { PortableSessionArtifactID(rawValue: $0) },
            authVersion: input.presence & authVersionField == 0 ? nil : input.auth_version,
            mediaRole: mediaRole,
            enrollment: input.enrollment == 1,
            identity: identity,
            fatalReason: fatalReason
        )
    }

    private static func fieldsAreCanonical(_ input: ScSessionEffectV1) -> Bool {
        for (bit, value) in [
            (generationField, input.generation),
            (operationField, input.operation),
            (timerField, input.timer_token),
            (claimField, input.admission_claim),
            (credentialField, input.credential),
            (candidateCredentialField, input.candidate_credential),
            (challengeField, input.challenge),
            (localChallengeField, input.local_challenge),
            (peerChallengeField, input.peer_challenge),
            (proofField, input.proof),
            (envelopeField, input.envelope),
            (localEnrollmentKeyField, input.local_enrollment_key),
            (peerEnrollmentKeyField, input.peer_enrollment_key),
        ] {
            if input.presence & bit == 0 ? value != 0 : value == 0 { return false }
        }
        let identityBytes = withUnsafeBytes(of: input.identity.bytes) { Array($0) }
        let identityLength = Int(input.identity.length)
        guard identityLength <= PortableSessionIdentity.maximumUTF8Bytes,
              identityBytes[identityLength...].allSatisfy({ $0 == 0 }),
              (input.presence & identityField != 0) == (identityLength != 0) else {
            return false
        }
        return input.presence & authVersionField == 0
            ? input.auth_version == 0
            : input.auth_version != 0
    }

    private static func effectShape(_ kind: PortableSessionEffectKind) -> EffectShape {
        switch kind {
        case .openTransport: EffectShape(operationField)
        case .armHandshakeTimer, .cancelHandshakeTimer: EffectShape(timerField)
        case .sendHello:
            EffectShape(
                generationField | identityField | authVersionField | localEnrollmentKeyField,
                mediaRole: true
            )
        case .loadCredential, .claimAdmission:
            EffectShape(operationField | identityField)
        case .openEnrollment, .prepareEnrollment:
            EffectShape(
                operationField | identityField | localEnrollmentKeyField
                    | peerEnrollmentKeyField
            )
        case .requestEnrollmentApproval:
            EffectShape(operationField | identityField | peerEnrollmentKeyField)
        case .generateChallenge, .cancelCredentialWrite:
            EffectShape(operationField)
        case .sendHelloAck:
            EffectShape(
                generationField | identityField,
                optional: authVersionField | challengeField | localEnrollmentKeyField,
                mediaRole: true,
                enrollment: true
            )
        case .sendEnrollment: EffectShape(envelopeField)
        case .createAuthProof, .createMutualProof:
            EffectShape(operationField | credentialField | challengeField)
        case .verifyPeerProof, .verifyMutualProof:
            EffectShape(operationField | credentialField | challengeField | proofField)
        case .submitFinalAuthAck:
            EffectShape(operationField | proofField)
        case .submitFinalHelloAck:
            EffectShape(operationField | generationField | identityField, mediaRole: true)
        case .sendAuth:
            EffectShape(proofField | challengeField)
        case .writeCredential:
            EffectShape(operationField | identityField | credentialField)
        case .commitCapabilities:
            EffectShape(operationField | identityField, mediaRole: true)
        case .notifyReady, .notifyStreaming, .closeTransport, .notifyClosed:
            EffectShape()
        case .releaseAdmission:
            EffectShape(claimField)
        case .notifyFatal:
            EffectShape(fatal: true)
        }
    }
}
