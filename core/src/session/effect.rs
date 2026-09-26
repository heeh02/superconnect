use super::{
    AdmissionClaimId, ArtifactId, BoundedPeerIdentity, OperationId, SessionFatalReason,
    SessionGeneration, TimerToken, MAX_SESSION_EFFECTS,
};
use crate::capability::MediaRole;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionEffect {
    OpenTransport {
        operation: OperationId,
    },
    ArmHandshakeTimer {
        token: TimerToken,
    },
    CancelHandshakeTimer {
        token: TimerToken,
    },
    SendHello {
        generation: SessionGeneration,
        identity: BoundedPeerIdentity,
        media_role: MediaRole,
        auth_version: u16,
        local_enrollment_key: ArtifactId,
    },
    LoadCredential {
        operation: OperationId,
        peer: BoundedPeerIdentity,
    },
    OpenEnrollment {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        local_enrollment_key: ArtifactId,
        peer_enrollment_key: ArtifactId,
    },
    RequestEnrollmentApproval {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        peer_enrollment_key: ArtifactId,
    },
    PrepareEnrollment {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        local_enrollment_key: ArtifactId,
        peer_enrollment_key: ArtifactId,
    },
    GenerateChallenge {
        operation: OperationId,
    },
    SendHelloAck {
        generation: SessionGeneration,
        identity: BoundedPeerIdentity,
        media_role: MediaRole,
        auth_version: Option<u16>,
        challenge: Option<ArtifactId>,
        enrollment: bool,
        local_enrollment_key: Option<ArtifactId>,
    },
    SendEnrollment {
        envelope: ArtifactId,
    },
    CreateAuthProof {
        operation: OperationId,
        credential: ArtifactId,
        challenge: ArtifactId,
    },
    VerifyPeerProof {
        operation: OperationId,
        credential: ArtifactId,
        challenge: ArtifactId,
        proof: ArtifactId,
    },
    ClaimAdmission {
        operation: OperationId,
        peer: BoundedPeerIdentity,
    },
    CreateMutualProof {
        operation: OperationId,
        credential: ArtifactId,
        challenge: ArtifactId,
    },
    SubmitFinalAuthAck {
        operation: OperationId,
        proof: ArtifactId,
    },
    SubmitFinalHelloAck {
        operation: OperationId,
        generation: SessionGeneration,
        identity: BoundedPeerIdentity,
        media_role: MediaRole,
    },
    SendAuth {
        proof: ArtifactId,
        challenge: ArtifactId,
    },
    VerifyMutualProof {
        operation: OperationId,
        credential: ArtifactId,
        challenge: ArtifactId,
        proof: ArtifactId,
    },
    WriteCredential {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
    },
    CancelCredentialWrite {
        operation: OperationId,
    },
    CommitCapabilities {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        media_role: MediaRole,
    },
    NotifyReady,
    NotifyStreaming,
    CloseTransport,
    NotifyClosed,
    ReleaseAdmission {
        claim: AdmissionClaimId,
    },
    NotifyFatal(SessionFatalReason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionEffects {
    entries: [Option<SessionEffect>; MAX_SESSION_EFFECTS],
    len: u8,
}

impl SessionEffects {
    pub const fn empty() -> Self {
        Self {
            entries: [None; MAX_SESSION_EFFECTS],
            len: 0,
        }
    }

    pub(super) fn from_slice(values: &[SessionEffect]) -> Self {
        debug_assert!(values.len() <= MAX_SESSION_EFFECTS);
        let mut output = Self::empty();
        for value in values {
            output.entries[usize::from(output.len)] = Some(*value);
            output.len += 1;
        }
        output
    }

    pub(super) fn push(&mut self, value: SessionEffect) {
        debug_assert!(self.len() < MAX_SESSION_EFFECTS);
        self.entries[usize::from(self.len)] = Some(value);
        self.len += 1;
    }

    pub fn iter(&self) -> impl Iterator<Item = &SessionEffect> {
        self.entries[..usize::from(self.len)]
            .iter()
            .map(|value| value.as_ref().expect("occupied effect slot"))
    }

    pub const fn len(&self) -> usize {
        self.len as usize
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}
