use super::{
    AdmissionClaimId, ArtifactId, BoundedPeerIdentity, CredentialState, OperationId,
    SessionGeneration, TimerToken,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionEvent {
    Start {
        generation: SessionGeneration,
    },
    TransportOpened {
        generation: SessionGeneration,
        operation: OperationId,
    },
    PeerHelloAck {
        generation: SessionGeneration,
        peer: BoundedPeerIdentity,
        auth_version: Option<u16>,
        challenge: Option<ArtifactId>,
        enrollment: bool,
        peer_enrollment_key: Option<ArtifactId>,
    },
    PeerHello {
        generation: SessionGeneration,
        peer: BoundedPeerIdentity,
        auth_version: Option<u16>,
        peer_enrollment_key: Option<ArtifactId>,
    },
    CredentialLoaded {
        generation: SessionGeneration,
        operation: OperationId,
        credential: CredentialState,
    },
    EnrollmentOpened {
        generation: SessionGeneration,
        operation: OperationId,
        candidate_credential: ArtifactId,
    },
    EnrollmentApproved {
        generation: SessionGeneration,
        operation: OperationId,
        approved: bool,
    },
    EnrollmentPrepared {
        generation: SessionGeneration,
        operation: OperationId,
        candidate_credential: ArtifactId,
        challenge: ArtifactId,
        envelope: ArtifactId,
    },
    ChallengeGenerated {
        generation: SessionGeneration,
        operation: OperationId,
        challenge: ArtifactId,
    },
    AuthProofCreated {
        generation: SessionGeneration,
        operation: OperationId,
        proof: ArtifactId,
        local_challenge: ArtifactId,
    },
    PeerAuth {
        generation: SessionGeneration,
        proof: ArtifactId,
        peer_challenge: ArtifactId,
    },
    PeerProofVerified {
        generation: SessionGeneration,
        operation: OperationId,
        valid: bool,
    },
    AdmissionClaimSucceeded {
        generation: SessionGeneration,
        operation: OperationId,
        claim: AdmissionClaimId,
    },
    AdmissionClaimFailed {
        generation: SessionGeneration,
        operation: OperationId,
    },
    MutualProofCreated {
        generation: SessionGeneration,
        operation: OperationId,
        proof: ArtifactId,
    },
    PeerAuthAck {
        generation: SessionGeneration,
        proof: ArtifactId,
    },
    MutualProofVerified {
        generation: SessionGeneration,
        operation: OperationId,
        valid: bool,
    },
    CredentialWriteCompleted {
        generation: SessionGeneration,
        operation: OperationId,
        success: bool,
    },
    FinalAckSubmitted {
        generation: SessionGeneration,
        operation: OperationId,
        success: bool,
    },
    CapabilitiesCommitted {
        generation: SessionGeneration,
        operation: OperationId,
        success: bool,
    },
    StreamingStarted {
        generation: SessionGeneration,
    },
    CloseRequested {
        generation: SessionGeneration,
    },
    TransportClosed {
        generation: SessionGeneration,
    },
    TransportFailed {
        generation: SessionGeneration,
    },
    TimerFired {
        generation: SessionGeneration,
        token: TimerToken,
    },
}

impl SessionEvent {
    pub const fn generation(self) -> SessionGeneration {
        match self {
            Self::Start { generation }
            | Self::TransportOpened { generation, .. }
            | Self::PeerHelloAck { generation, .. }
            | Self::PeerHello { generation, .. }
            | Self::CredentialLoaded { generation, .. }
            | Self::EnrollmentOpened { generation, .. }
            | Self::EnrollmentApproved { generation, .. }
            | Self::EnrollmentPrepared { generation, .. }
            | Self::ChallengeGenerated { generation, .. }
            | Self::AuthProofCreated { generation, .. }
            | Self::PeerAuth { generation, .. }
            | Self::PeerProofVerified { generation, .. }
            | Self::AdmissionClaimSucceeded { generation, .. }
            | Self::AdmissionClaimFailed { generation, .. }
            | Self::MutualProofCreated { generation, .. }
            | Self::PeerAuthAck { generation, .. }
            | Self::MutualProofVerified { generation, .. }
            | Self::CredentialWriteCompleted { generation, .. }
            | Self::FinalAckSubmitted { generation, .. }
            | Self::CapabilitiesCommitted { generation, .. }
            | Self::StreamingStarted { generation }
            | Self::CloseRequested { generation }
            | Self::TransportClosed { generation }
            | Self::TransportFailed { generation }
            | Self::TimerFired { generation, .. } => generation,
        }
    }
}
