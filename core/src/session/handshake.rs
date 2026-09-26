use super::state::Phase;
use super::{
    ArtifactId, BoundedPeerIdentity, CredentialState, OperationId, ScSession, SessionEffect,
    SessionEffects, SessionFatalReason, SessionOrigin, SessionSide, AUTH_VERSION_1,
};

impl ScSession {
    pub(super) fn peer_hello_ack(
        &mut self,
        peer: BoundedPeerIdentity,
        auth_version: Option<u16>,
        challenge: Option<ArtifactId>,
        enrollment: bool,
        peer_enrollment_key: Option<ArtifactId>,
    ) -> SessionEffects {
        if self.phase != Phase::Hello || self.config.side != SessionSide::Initiator {
            return SessionEffects::empty();
        }
        if self.config.origin != SessionOrigin::MutualAuthenticationRequired {
            return self.begin_capability(peer);
        }
        if auth_version != Some(AUTH_VERSION_1) {
            return self.fail(SessionFatalReason::AuthenticationRequired);
        }
        let Some(challenge) = challenge else {
            return self.fail(SessionFatalReason::AuthenticationRequired);
        };
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::Credential {
            operation,
            peer,
            challenge: Some(challenge),
            enrollment,
            peer_enrollment_key,
        };
        SessionEffects::from_slice(&[SessionEffect::LoadCredential { operation, peer }])
    }

    pub(super) fn peer_hello(
        &mut self,
        peer: BoundedPeerIdentity,
        auth_version: Option<u16>,
        peer_enrollment_key: Option<ArtifactId>,
    ) -> SessionEffects {
        if self.phase != Phase::Hello || self.config.side != SessionSide::Responder {
            return SessionEffects::empty();
        }
        if self.config.origin == SessionOrigin::TrustedLocal {
            return self.begin_admission(peer, None);
        }
        if auth_version != Some(AUTH_VERSION_1) {
            return self.fail(SessionFatalReason::AuthenticationRequired);
        }
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::Credential {
            operation,
            peer,
            challenge: None,
            enrollment: false,
            peer_enrollment_key,
        };
        SessionEffects::from_slice(&[SessionEffect::LoadCredential { operation, peer }])
    }

    pub(super) fn credential_loaded(
        &mut self,
        received: OperationId,
        credential: CredentialState,
    ) -> SessionEffects {
        let Phase::Credential {
            operation,
            peer,
            challenge,
            enrollment,
            peer_enrollment_key,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        match self.config.side {
            SessionSide::Initiator => {
                let Some(challenge) = challenge else {
                    return self.fail(SessionFatalReason::AuthenticationFailed);
                };
                match (enrollment, credential) {
                    (_, CredentialState::Unavailable) => {
                        self.fail(SessionFatalReason::CredentialUnavailable)
                    }
                    (true, CredentialState::Present(_)) => {
                        self.fail(SessionFatalReason::UnexpectedReenrollment)
                    }
                    (true, CredentialState::Missing) => {
                        let Some(peer_enrollment_key) = peer_enrollment_key else {
                            return self.fail(SessionFatalReason::AuthenticationFailed);
                        };
                        let Some(operation) = self.allocate_operation() else {
                            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
                        };
                        self.phase = Phase::OpeningEnrollment {
                            operation,
                            peer,
                            challenge,
                        };
                        SessionEffects::from_slice(&[SessionEffect::OpenEnrollment {
                            operation,
                            peer,
                            local_enrollment_key: self.config.local_enrollment_key,
                            peer_enrollment_key,
                        }])
                    }
                    (false, CredentialState::Missing) => {
                        self.fail(SessionFatalReason::CredentialUnavailable)
                    }
                    (false, CredentialState::Present(credential)) => {
                        self.begin_auth_proof(peer, credential, challenge, None)
                    }
                }
            }
            SessionSide::Responder => match credential {
                CredentialState::Unavailable => {
                    self.fail(SessionFatalReason::CredentialUnavailable)
                }
                CredentialState::Present(credential) => {
                    let Some(operation) = self.allocate_operation() else {
                        return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
                    };
                    self.phase = Phase::GeneratingChallenge {
                        operation,
                        peer,
                        credential,
                    };
                    SessionEffects::from_slice(&[SessionEffect::GenerateChallenge { operation }])
                }
                CredentialState::Missing => {
                    let Some(peer_enrollment_key) = peer_enrollment_key else {
                        return self.fail(SessionFatalReason::AuthenticationRequired);
                    };
                    let Some(operation) = self.allocate_operation() else {
                        return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
                    };
                    self.phase = Phase::AwaitingEnrollmentApproval {
                        operation,
                        peer,
                        peer_enrollment_key,
                    };
                    SessionEffects::from_slice(&[SessionEffect::RequestEnrollmentApproval {
                        operation,
                        peer,
                        peer_enrollment_key,
                    }])
                }
            },
        }
    }

    pub(super) fn enrollment_approved(
        &mut self,
        received: OperationId,
        approved: bool,
    ) -> SessionEffects {
        let Phase::AwaitingEnrollmentApproval {
            operation,
            peer,
            peer_enrollment_key,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !approved {
            return self.fail(SessionFatalReason::PairingRejected);
        }
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::PreparingEnrollment { operation, peer };
        SessionEffects::from_slice(&[SessionEffect::PrepareEnrollment {
            operation,
            peer,
            local_enrollment_key: self.config.local_enrollment_key,
            peer_enrollment_key,
        }])
    }

    pub(super) fn enrollment_prepared(
        &mut self,
        received: OperationId,
        candidate_credential: ArtifactId,
        challenge: ArtifactId,
        envelope: ArtifactId,
    ) -> SessionEffects {
        let Phase::PreparingEnrollment { operation, peer } = self.phase else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.phase = Phase::AwaitingPeerAuth {
            peer,
            credential: candidate_credential,
            challenge,
            candidate_credential: Some(candidate_credential),
        };
        SessionEffects::from_slice(&[
            SessionEffect::SendHelloAck {
                generation: self.config.generation,
                identity: self.config.local_identity,
                media_role: self.config.media_role,
                auth_version: Some(AUTH_VERSION_1),
                challenge: Some(challenge),
                enrollment: true,
                local_enrollment_key: Some(self.config.local_enrollment_key),
            },
            SessionEffect::SendEnrollment { envelope },
        ])
    }

    pub(super) fn enrollment_opened(
        &mut self,
        received: OperationId,
        candidate_credential: ArtifactId,
    ) -> SessionEffects {
        let Phase::OpeningEnrollment {
            operation,
            peer,
            challenge,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.begin_auth_proof(
            peer,
            candidate_credential,
            challenge,
            Some(candidate_credential),
        )
    }
}
