use super::state::{Phase, WriteContinuation};
use super::{
    AdmissionClaimId, ArtifactId, BoundedPeerIdentity, OperationId, ScSession, SessionEffect,
    SessionEffects, SessionFatalReason, AUTH_VERSION_1,
};

impl ScSession {
    pub(super) fn begin_auth_proof(
        &mut self,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    ) -> SessionEffects {
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::CreatingAuth {
            operation,
            peer,
            credential,
            challenge,
            candidate_credential,
        };
        SessionEffects::from_slice(&[SessionEffect::CreateAuthProof {
            operation,
            credential,
            challenge,
        }])
    }

    pub(super) fn challenge_generated(
        &mut self,
        received: OperationId,
        challenge: ArtifactId,
    ) -> SessionEffects {
        let Phase::GeneratingChallenge {
            operation,
            peer,
            credential,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.phase = Phase::AwaitingPeerAuth {
            peer,
            credential,
            challenge,
            candidate_credential: None,
        };
        SessionEffects::from_slice(&[SessionEffect::SendHelloAck {
            generation: self.config.generation,
            identity: self.config.local_identity,
            media_role: self.config.media_role,
            auth_version: Some(AUTH_VERSION_1),
            challenge: Some(challenge),
            enrollment: false,
            local_enrollment_key: None,
        }])
    }

    pub(super) fn peer_auth(
        &mut self,
        proof: ArtifactId,
        peer_challenge: ArtifactId,
    ) -> SessionEffects {
        let Phase::AwaitingPeerAuth {
            peer,
            credential,
            challenge,
            candidate_credential,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::VerifyingPeer {
            operation,
            peer,
            credential,
            peer_challenge,
            candidate_credential,
        };
        SessionEffects::from_slice(&[SessionEffect::VerifyPeerProof {
            operation,
            credential,
            challenge,
            proof,
        }])
    }

    pub(super) fn peer_proof_verified(
        &mut self,
        received: OperationId,
        valid: bool,
    ) -> SessionEffects {
        let Phase::VerifyingPeer {
            operation,
            peer,
            credential,
            peer_challenge,
            candidate_credential,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !valid {
            return self.fail(SessionFatalReason::AuthenticationFailed);
        }
        self.begin_admission(
            peer,
            Some((credential, peer_challenge, candidate_credential)),
        )
    }

    pub(super) fn begin_admission(
        &mut self,
        peer: BoundedPeerIdentity,
        authenticated: Option<(ArtifactId, ArtifactId, Option<ArtifactId>)>,
    ) -> SessionEffects {
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::Admission {
            operation,
            peer,
            authenticated,
        };
        SessionEffects::from_slice(&[SessionEffect::ClaimAdmission { operation, peer }])
    }

    pub(super) fn admission_claim_succeeded(
        &mut self,
        received: OperationId,
        claim: AdmissionClaimId,
    ) -> SessionEffects {
        let Phase::Admission {
            operation,
            peer,
            authenticated,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.admission_claim = Some(claim);
        if let Some((credential, peer_challenge, candidate_credential)) = authenticated {
            if let Some(candidate_credential) = candidate_credential {
                let Some(operation) = self.allocate_operation() else {
                    return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
                };
                self.phase = Phase::WritingCredential {
                    operation,
                    peer,
                    continuation: WriteContinuation::ResponderMutualProof {
                        credential,
                        peer_challenge,
                    },
                };
                SessionEffects::from_slice(&[SessionEffect::WriteCredential {
                    operation,
                    peer,
                    credential: candidate_credential,
                }])
            } else {
                self.begin_responder_mutual_proof(peer, credential, peer_challenge, None)
            }
        } else {
            let Some(operation) = self.allocate_operation() else {
                return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
            };
            self.phase = Phase::SubmittingFinalAck { operation, peer };
            SessionEffects::from_slice(&[SessionEffect::SubmitFinalHelloAck {
                operation,
                generation: self.config.generation,
                identity: self.config.local_identity,
                media_role: self.config.media_role,
            }])
        }
    }

    pub(super) fn admission_claim_failed(&mut self, received: OperationId) -> SessionEffects {
        let Phase::Admission { operation, .. } = self.phase else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.fail(SessionFatalReason::AdmissionRejected)
    }

    pub(super) fn begin_responder_mutual_proof(
        &mut self,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        peer_challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    ) -> SessionEffects {
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::CreatingMutualProof {
            operation,
            peer,
            credential,
            candidate_credential,
        };
        SessionEffects::from_slice(&[SessionEffect::CreateMutualProof {
            operation,
            credential,
            challenge: peer_challenge,
        }])
    }

    pub(super) fn mutual_proof_created(
        &mut self,
        received: OperationId,
        proof: ArtifactId,
    ) -> SessionEffects {
        let Phase::CreatingMutualProof {
            operation, peer, ..
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::SubmittingFinalAck { operation, peer };
        SessionEffects::from_slice(&[SessionEffect::SubmitFinalAuthAck { operation, proof }])
    }

    pub(super) fn auth_proof_created(
        &mut self,
        received: OperationId,
        proof: ArtifactId,
        local_challenge: ArtifactId,
    ) -> SessionEffects {
        let Phase::CreatingAuth {
            operation,
            peer,
            credential,
            candidate_credential,
            ..
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.phase = Phase::AwaitingAuthAck {
            peer,
            credential,
            local_challenge,
            candidate_credential,
        };
        SessionEffects::from_slice(&[SessionEffect::SendAuth {
            proof,
            challenge: local_challenge,
        }])
    }

    pub(super) fn peer_auth_ack(&mut self, proof: ArtifactId) -> SessionEffects {
        let Phase::AwaitingAuthAck {
            peer,
            credential,
            local_challenge,
            candidate_credential,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::VerifyingAck {
            operation,
            peer,
            credential,
            candidate_credential,
        };
        SessionEffects::from_slice(&[SessionEffect::VerifyMutualProof {
            operation,
            credential,
            challenge: local_challenge,
            proof,
        }])
    }

    pub(super) fn mutual_proof_verified(
        &mut self,
        received: OperationId,
        valid: bool,
    ) -> SessionEffects {
        let Phase::VerifyingAck {
            operation,
            peer,
            credential,
            candidate_credential,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !valid {
            return self.fail(SessionFatalReason::AuthenticationFailed);
        }
        if let Some(candidate_credential) = candidate_credential {
            let Some(operation) = self.allocate_operation() else {
                return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
            };
            self.phase = Phase::WritingCredential {
                operation,
                peer,
                continuation: WriteContinuation::InitiatorCapability,
            };
            SessionEffects::from_slice(&[SessionEffect::WriteCredential {
                operation,
                peer,
                credential: candidate_credential,
            }])
        } else {
            let _ = credential;
            self.begin_capability(peer)
        }
    }

    pub(super) fn credential_write_completed(
        &mut self,
        received: OperationId,
        success: bool,
    ) -> SessionEffects {
        let Phase::WritingCredential {
            operation,
            peer,
            continuation,
        } = self.phase
        else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !success {
            self.phase = Phase::Hello;
            return self.fail(SessionFatalReason::CredentialUnavailable);
        }
        match continuation {
            WriteContinuation::InitiatorCapability => self.begin_capability(peer),
            WriteContinuation::ResponderMutualProof {
                credential,
                peer_challenge,
            } => self.begin_responder_mutual_proof(peer, credential, peer_challenge, None),
        }
    }

    pub(super) fn final_ack_submitted(
        &mut self,
        received: OperationId,
        success: bool,
    ) -> SessionEffects {
        let Phase::SubmittingFinalAck { operation, peer } = self.phase else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !success {
            return self.fail(SessionFatalReason::FinalAckFailed);
        }
        self.begin_capability(peer)
    }
}
