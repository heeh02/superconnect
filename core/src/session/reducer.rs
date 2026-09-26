use super::state::Phase;
use super::{
    AdmissionClaimId, BoundedPeerIdentity, OperationId, SessionConfig, SessionEffect,
    SessionEffects, SessionEvent, SessionFatalReason, SessionPhase, SessionSide, TimerToken,
    AUTH_VERSION_1,
};

/// Stateful session owner. Deliberately neither `Clone` nor `Copy`.
///
/// ```compile_fail,E0599
/// use superconnect_core::capability::MediaRole;
/// use superconnect_core::SessionGeneration;
/// use superconnect_core::session::{
///     BoundedPeerIdentity, ScSession, SessionConfig, SessionOrigin, SessionSide,
/// };
/// let identity = BoundedPeerIdentity::new(b"local-peer").unwrap();
/// let config = SessionConfig::new(
///     SessionGeneration::new(1),
///     SessionSide::Initiator,
///     MediaRole::Host,
///     SessionOrigin::TrustedLocal,
///     identity,
///     superconnect_core::session::ArtifactId::new(1).unwrap(),
///     1,
/// ).unwrap();
/// let session = ScSession::new(config);
/// let duplicated = session.clone();
/// let _ = (session.phase(), duplicated.phase());
/// ```
#[derive(Debug, PartialEq, Eq)]
pub struct ScSession {
    pub(super) config: SessionConfig,
    pub(super) phase: Phase,
    pub(super) next_id: Option<u64>,
    pub(super) timer: Option<TimerToken>,
    pub(super) admission_claim: Option<AdmissionClaimId>,
    pub(super) transport_open: bool,
}

impl ScSession {
    pub const fn new(config: SessionConfig) -> Self {
        Self {
            next_id: Some(config.first_operation_id),
            config,
            phase: Phase::Idle,
            timer: None,
            admission_claim: None,
            transport_open: false,
        }
    }

    pub fn apply(&mut self, event: SessionEvent) -> SessionEffects {
        if event.generation() != self.config.generation {
            return SessionEffects::empty();
        }
        let effects = match event {
            SessionEvent::Start { .. } => self.start(),
            SessionEvent::TransportOpened { operation, .. } => self.transport_opened(operation),
            SessionEvent::PeerHelloAck {
                peer,
                auth_version,
                challenge,
                enrollment,
                peer_enrollment_key,
                ..
            } => self.peer_hello_ack(
                peer,
                auth_version,
                challenge,
                enrollment,
                peer_enrollment_key,
            ),
            SessionEvent::PeerHello {
                peer,
                auth_version,
                peer_enrollment_key,
                ..
            } => self.peer_hello(peer, auth_version, peer_enrollment_key),
            SessionEvent::CredentialLoaded {
                operation,
                credential,
                ..
            } => self.credential_loaded(operation, credential),
            SessionEvent::EnrollmentOpened {
                operation,
                candidate_credential,
                ..
            } => self.enrollment_opened(operation, candidate_credential),
            SessionEvent::EnrollmentApproved {
                operation,
                approved,
                ..
            } => self.enrollment_approved(operation, approved),
            SessionEvent::EnrollmentPrepared {
                operation,
                candidate_credential,
                challenge,
                envelope,
                ..
            } => self.enrollment_prepared(operation, candidate_credential, challenge, envelope),
            SessionEvent::ChallengeGenerated {
                operation,
                challenge,
                ..
            } => self.challenge_generated(operation, challenge),
            SessionEvent::AuthProofCreated {
                operation,
                proof,
                local_challenge,
                ..
            } => self.auth_proof_created(operation, proof, local_challenge),
            SessionEvent::PeerAuth {
                proof,
                peer_challenge,
                ..
            } => self.peer_auth(proof, peer_challenge),
            SessionEvent::PeerProofVerified {
                operation, valid, ..
            } => self.peer_proof_verified(operation, valid),
            SessionEvent::AdmissionClaimSucceeded {
                operation, claim, ..
            } => self.admission_claim_succeeded(operation, claim),
            SessionEvent::AdmissionClaimFailed { operation, .. } => {
                self.admission_claim_failed(operation)
            }
            SessionEvent::MutualProofCreated {
                operation, proof, ..
            } => self.mutual_proof_created(operation, proof),
            SessionEvent::PeerAuthAck { proof, .. } => self.peer_auth_ack(proof),
            SessionEvent::MutualProofVerified {
                operation, valid, ..
            } => self.mutual_proof_verified(operation, valid),
            SessionEvent::CredentialWriteCompleted {
                operation, success, ..
            } => self.credential_write_completed(operation, success),
            SessionEvent::FinalAckSubmitted {
                operation, success, ..
            } => self.final_ack_submitted(operation, success),
            SessionEvent::CapabilitiesCommitted {
                operation, success, ..
            } => self.capabilities_committed(operation, success),
            SessionEvent::StreamingStarted { .. } => self.streaming_started(),
            SessionEvent::CloseRequested { .. } => self.close_requested(),
            SessionEvent::TransportClosed { .. } => self.transport_closed(),
            SessionEvent::TransportFailed { .. } => self.transport_failed(),
            SessionEvent::TimerFired { token, .. } => self.timer_fired(token),
        };
        debug_assert!(self.invariants_hold());
        effects
    }

    pub const fn phase(&self) -> SessionPhase {
        match self.phase {
            Phase::Idle => SessionPhase::Idle,
            Phase::Transport { .. } => SessionPhase::Transport,
            Phase::Hello => SessionPhase::Hello,
            Phase::Credential { .. } => SessionPhase::Credential,
            Phase::OpeningEnrollment { .. }
            | Phase::AwaitingEnrollmentApproval { .. }
            | Phase::PreparingEnrollment { .. } => SessionPhase::Enrollment,
            Phase::CreatingAuth { .. }
            | Phase::AwaitingAuthAck { .. }
            | Phase::VerifyingAck { .. }
            | Phase::GeneratingChallenge { .. }
            | Phase::AwaitingPeerAuth { .. }
            | Phase::VerifyingPeer { .. }
            | Phase::CreatingMutualProof { .. } => SessionPhase::MutualAuth,
            Phase::Admission { .. } => SessionPhase::Admission,
            Phase::WritingCredential { .. } => SessionPhase::Credential,
            Phase::SubmittingFinalAck { .. } => SessionPhase::FinalAck,
            Phase::Capability { .. } => SessionPhase::CapabilityCommit,
            Phase::Ready => SessionPhase::Ready,
            Phase::Streaming => SessionPhase::Streaming,
            Phase::Closing => SessionPhase::Closing,
            Phase::Closed => SessionPhase::Closed,
            Phase::Fatal => SessionPhase::Fatal,
        }
    }

    pub const fn invariants_hold(&self) -> bool {
        match self.phase {
            Phase::Idle => {
                self.timer.is_none() && !self.transport_open && self.admission_claim.is_none()
            }
            Phase::Ready | Phase::Streaming => self.timer.is_none() && self.transport_open,
            Phase::Closing | Phase::Closed | Phase::Fatal => {
                self.timer.is_none() && !self.transport_open && self.admission_claim.is_none()
            }
            Phase::Transport { .. }
            | Phase::Hello
            | Phase::Credential { .. }
            | Phase::OpeningEnrollment { .. }
            | Phase::AwaitingEnrollmentApproval { .. }
            | Phase::PreparingEnrollment { .. }
            | Phase::CreatingAuth { .. }
            | Phase::AwaitingAuthAck { .. }
            | Phase::VerifyingAck { .. }
            | Phase::GeneratingChallenge { .. }
            | Phase::AwaitingPeerAuth { .. }
            | Phase::VerifyingPeer { .. }
            | Phase::Admission { .. }
            | Phase::CreatingMutualProof { .. }
            | Phase::WritingCredential { .. }
            | Phase::SubmittingFinalAck { .. }
            | Phase::Capability { .. } => self.timer.is_some() && self.transport_open,
        }
    }

    pub const fn pending_timer_count(&self) -> usize {
        if self.timer.is_some() {
            1
        } else {
            0
        }
    }

    pub const fn pending_operation_count(&self) -> usize {
        match self.phase {
            Phase::Transport { .. }
            | Phase::Credential { .. }
            | Phase::OpeningEnrollment { .. }
            | Phase::AwaitingEnrollmentApproval { .. }
            | Phase::PreparingEnrollment { .. }
            | Phase::CreatingAuth { .. }
            | Phase::VerifyingAck { .. }
            | Phase::GeneratingChallenge { .. }
            | Phase::VerifyingPeer { .. }
            | Phase::Admission { .. }
            | Phase::CreatingMutualProof { .. }
            | Phase::WritingCredential { .. }
            | Phase::SubmittingFinalAck { .. }
            | Phase::Capability { .. } => 1,
            Phase::Idle
            | Phase::Hello
            | Phase::AwaitingAuthAck { .. }
            | Phase::AwaitingPeerAuth { .. }
            | Phase::Ready
            | Phase::Streaming
            | Phase::Closing
            | Phase::Closed
            | Phase::Fatal => 0,
        }
    }

    pub(super) fn start(&mut self) -> SessionEffects {
        if self.phase != Phase::Idle {
            return SessionEffects::empty();
        }
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        let Some(token) = self.allocate_timer() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::Transport { operation };
        self.timer = Some(token);
        self.transport_open = true;
        SessionEffects::from_slice(&[
            SessionEffect::OpenTransport { operation },
            SessionEffect::ArmHandshakeTimer { token },
        ])
    }

    pub(super) fn transport_opened(&mut self, received: OperationId) -> SessionEffects {
        let Phase::Transport { operation } = self.phase else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        self.transport_open = true;
        self.phase = Phase::Hello;
        match self.config.side {
            SessionSide::Initiator => SessionEffects::from_slice(&[SessionEffect::SendHello {
                generation: self.config.generation,
                identity: self.config.local_identity,
                media_role: self.config.media_role,
                auth_version: AUTH_VERSION_1,
                local_enrollment_key: self.config.local_enrollment_key,
            }]),
            SessionSide::Responder => SessionEffects::empty(),
        }
    }

    pub(super) fn begin_capability(&mut self, peer: BoundedPeerIdentity) -> SessionEffects {
        let Some(operation) = self.allocate_operation() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        self.phase = Phase::Capability { operation };
        SessionEffects::from_slice(&[SessionEffect::CommitCapabilities {
            operation,
            peer,
            media_role: self.config.media_role,
        }])
    }

    pub(super) fn capabilities_committed(
        &mut self,
        received: OperationId,
        success: bool,
    ) -> SessionEffects {
        let Phase::Capability { operation } = self.phase else {
            return SessionEffects::empty();
        };
        if operation != received {
            return SessionEffects::empty();
        }
        if !success {
            return self.fail(SessionFatalReason::CapabilityCommitFailed);
        }
        self.phase = Phase::Ready;
        let Some(token) = self.timer.take() else {
            return self.fail(SessionFatalReason::IdentifierSpaceExhausted);
        };
        SessionEffects::from_slice(&[
            SessionEffect::CancelHandshakeTimer { token },
            SessionEffect::NotifyReady,
        ])
    }

    pub(super) fn streaming_started(&mut self) -> SessionEffects {
        if self.phase != Phase::Ready {
            return SessionEffects::empty();
        }
        self.phase = Phase::Streaming;
        SessionEffects::from_slice(&[SessionEffect::NotifyStreaming])
    }

    pub(super) fn close_requested(&mut self) -> SessionEffects {
        if matches!(
            self.phase,
            Phase::Idle | Phase::Closing | Phase::Closed | Phase::Fatal
        ) {
            return SessionEffects::empty();
        }
        let mut effects = self.cleanup_resources();
        if self.transport_open {
            self.transport_open = false;
            effects.push(SessionEffect::CloseTransport);
        }
        self.phase = Phase::Closing;
        effects
    }

    pub(super) fn transport_closed(&mut self) -> SessionEffects {
        if self.phase == Phase::Closing {
            self.phase = Phase::Closed;
            return SessionEffects::from_slice(&[SessionEffect::NotifyClosed]);
        }
        if matches!(self.phase, Phase::Closed | Phase::Fatal | Phase::Idle) {
            return SessionEffects::empty();
        }
        self.transport_open = false;
        let mut effects = self.cleanup_resources();
        self.phase = Phase::Closed;
        effects.push(SessionEffect::NotifyClosed);
        effects
    }

    pub(super) fn transport_failed(&mut self) -> SessionEffects {
        if matches!(self.phase, Phase::Idle | Phase::Closed | Phase::Fatal) {
            return SessionEffects::empty();
        }
        self.fail(SessionFatalReason::TransportFailed)
    }

    pub(crate) fn protocol_violation(&mut self) -> SessionEffects {
        if matches!(self.phase, Phase::Idle | Phase::Closed | Phase::Fatal) {
            return SessionEffects::empty();
        }
        self.fail(SessionFatalReason::ProtocolViolation)
    }

    pub(super) fn timer_fired(&mut self, received: TimerToken) -> SessionEffects {
        if self.timer != Some(received) {
            return SessionEffects::empty();
        }
        self.fail(SessionFatalReason::HandshakeTimedOut)
    }

    pub(super) fn allocate_operation(&mut self) -> Option<OperationId> {
        let value = self.next_id?;
        self.next_id = value.checked_add(1);
        OperationId::new(value)
    }

    pub(super) fn allocate_timer(&mut self) -> Option<TimerToken> {
        let value = self.next_id?;
        self.next_id = value.checked_add(1);
        TimerToken::new(value)
    }

    pub(super) fn fail(&mut self, reason: SessionFatalReason) -> SessionEffects {
        if matches!(self.phase, Phase::Fatal | Phase::Closed) {
            return SessionEffects::empty();
        }
        let mut effects = self.cleanup_resources();
        if self.transport_open {
            self.transport_open = false;
            effects.push(SessionEffect::CloseTransport);
        }
        self.phase = Phase::Fatal;
        effects.push(SessionEffect::NotifyFatal(reason));
        effects
    }

    pub(super) fn cleanup_resources(&mut self) -> SessionEffects {
        let mut effects = SessionEffects::empty();
        if let Some(token) = self.timer.take() {
            effects.push(SessionEffect::CancelHandshakeTimer { token });
        }
        if let Phase::WritingCredential { operation, .. } = self.phase {
            effects.push(SessionEffect::CancelCredentialWrite { operation });
        }
        if let Some(claim) = self.admission_claim.take() {
            effects.push(SessionEffect::ReleaseAdmission { claim });
        }
        effects
    }
}
