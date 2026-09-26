use super::{ArtifactId, BoundedPeerIdentity, OperationId};

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Phase {
    Idle,
    Transport {
        operation: OperationId,
    },
    Hello,
    Credential {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        challenge: Option<ArtifactId>,
        enrollment: bool,
        peer_enrollment_key: Option<ArtifactId>,
    },
    OpeningEnrollment {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        challenge: ArtifactId,
    },
    AwaitingEnrollmentApproval {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        peer_enrollment_key: ArtifactId,
    },
    PreparingEnrollment {
        operation: OperationId,
        peer: BoundedPeerIdentity,
    },
    CreatingAuth {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    AwaitingAuthAck {
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        local_challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    VerifyingAck {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    GeneratingChallenge {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
    },
    AwaitingPeerAuth {
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    VerifyingPeer {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        peer_challenge: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    Admission {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        authenticated: Option<(ArtifactId, ArtifactId, Option<ArtifactId>)>,
    },
    CreatingMutualProof {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        credential: ArtifactId,
        candidate_credential: Option<ArtifactId>,
    },
    WritingCredential {
        operation: OperationId,
        peer: BoundedPeerIdentity,
        continuation: WriteContinuation,
    },
    SubmittingFinalAck {
        operation: OperationId,
        peer: BoundedPeerIdentity,
    },
    Capability {
        operation: OperationId,
    },
    Ready,
    Streaming,
    Closing,
    Closed,
    Fatal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum WriteContinuation {
    InitiatorCapability,
    ResponderMutualProof {
        credential: ArtifactId,
        peer_challenge: ArtifactId,
    },
}
