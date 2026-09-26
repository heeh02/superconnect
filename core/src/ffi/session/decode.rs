use crate::capability::MediaRole;
use crate::session::{
    AdmissionClaimId, ArtifactId, BoundedPeerIdentity, CredentialState, OperationId, SessionConfig,
    SessionEvent, SessionGeneration, SessionOrigin, SessionSide, TimerToken,
    MAX_PEER_IDENTITY_BYTES,
};

use super::types::*;

fn decode_side(value: u32) -> Option<SessionSide> {
    match value {
        SC_SESSION_SIDE_INITIATOR => Some(SessionSide::Initiator),
        SC_SESSION_SIDE_RESPONDER => Some(SessionSide::Responder),
        _ => None,
    }
}

fn decode_origin(value: u32) -> Option<SessionOrigin> {
    match value {
        SC_SESSION_ORIGIN_TRUSTED_LOCAL => Some(SessionOrigin::TrustedLocal),
        SC_SESSION_ORIGIN_MUTUAL_AUTHENTICATION_REQUIRED => {
            Some(SessionOrigin::MutualAuthenticationRequired)
        }
        _ => None,
    }
}

fn decode_media_role(value: u32) -> Option<MediaRole> {
    match value {
        SC_SESSION_MEDIA_ROLE_HOST => Some(MediaRole::Host),
        SC_SESSION_MEDIA_ROLE_RECEIVER => Some(MediaRole::Receiver),
        _ => None,
    }
}

fn identity_is_canonical(value: &ScSessionPeerIdentityV1) -> bool {
    let length = value.length as usize;
    length <= MAX_PEER_IDENTITY_BYTES && value.bytes[length..].iter().all(|byte| *byte == 0)
}

fn decode_identity(value: ScSessionPeerIdentityV1) -> Option<BoundedPeerIdentity> {
    if !identity_is_canonical(&value) || value.length == 0 {
        return None;
    }
    BoundedPeerIdentity::new(&value.bytes[..value.length as usize]).ok()
}

pub(crate) fn encode_identity(value: BoundedPeerIdentity) -> ScSessionPeerIdentityV1 {
    let bytes = value.as_bytes();
    let mut output = ScSessionPeerIdentityV1 {
        length: bytes.len() as u32,
        ..ScSessionPeerIdentityV1::default()
    };
    output.bytes[..bytes.len()].copy_from_slice(bytes);
    output
}

pub(crate) fn decode_config(value: ScSessionConfigV1) -> Option<SessionConfig> {
    if value.generation == 0
        || value.first_operation_id == 0
        || value.local_enrollment_key == 0
        || value.reserved0 != 0
        || value.reserved1 != 0
        || value.reserved2 != 0
    {
        return None;
    }
    SessionConfig::new(
        SessionGeneration::new(value.generation),
        decode_side(value.side)?,
        decode_media_role(value.media_role)?,
        decode_origin(value.origin)?,
        decode_identity(value.local_identity)?,
        ArtifactId::new(value.local_enrollment_key)?,
        value.first_operation_id,
    )
    .ok()
}

fn field_is_canonical(presence: u64, bit: u64, value: u64) -> bool {
    if presence & bit == 0 {
        value == 0
    } else {
        value != 0
    }
}

fn presence_matches(presence: u64, required: u64, optional: u64) -> bool {
    presence & required == required && presence & !(required | optional) == 0
}

fn bool_is_canonical(value: u8) -> bool {
    matches!(value, 0 | 1)
}

fn event_fields_are_canonical(value: &ScSessionEventV1) -> bool {
    if value.presence & !KNOWN_FIELDS != 0
        || value.reserved0 != [0; 2]
        || value.reserved1 != 0
        || value.reserved2 != 0
        || !bool_is_canonical(value.enrollment)
        || !bool_is_canonical(value.approved)
        || !bool_is_canonical(value.valid)
        || !bool_is_canonical(value.success)
    {
        return false;
    }
    for (bit, field) in [
        (SC_SESSION_FIELD_GENERATION, value.generation),
        (SC_SESSION_FIELD_OPERATION, value.operation),
        (SC_SESSION_FIELD_TIMER_TOKEN, value.timer_token),
        (SC_SESSION_FIELD_ADMISSION_CLAIM, value.admission_claim),
        (SC_SESSION_FIELD_CREDENTIAL, value.credential),
        (
            SC_SESSION_FIELD_CANDIDATE_CREDENTIAL,
            value.candidate_credential,
        ),
        (SC_SESSION_FIELD_CHALLENGE, value.challenge),
        (SC_SESSION_FIELD_LOCAL_CHALLENGE, value.local_challenge),
        (SC_SESSION_FIELD_PEER_CHALLENGE, value.peer_challenge),
        (SC_SESSION_FIELD_PROOF, value.proof),
        (SC_SESSION_FIELD_ENVELOPE, value.envelope),
        (
            SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY,
            value.local_enrollment_key,
        ),
        (
            SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            value.peer_enrollment_key,
        ),
    ] {
        if !field_is_canonical(value.presence, bit, field) {
            return false;
        }
    }
    let identity_present = value.presence & SC_SESSION_FIELD_IDENTITY != 0;
    if !identity_is_canonical(&value.peer_identity)
        || identity_present != (value.peer_identity.length != 0)
    {
        return false;
    }
    let auth_present = value.presence & SC_SESSION_FIELD_AUTH_VERSION != 0;
    auth_present || value.auth_version == 0
}

fn operation(value: u64) -> Option<OperationId> {
    OperationId::new(value)
}

fn artifact(value: u64) -> Option<ArtifactId> {
    ArtifactId::new(value)
}

fn timer(value: u64) -> Option<TimerToken> {
    TimerToken::new(value)
}

fn claim(value: u64) -> Option<AdmissionClaimId> {
    AdmissionClaimId::new(value)
}

fn event_flags_are_zero(value: &ScSessionEventV1) -> bool {
    value.credential_state == SC_SESSION_CREDENTIAL_NONE
        && value.enrollment == 0
        && value.approved == 0
        && value.valid == 0
        && value.success == 0
}

pub(crate) fn decode_event(value: ScSessionEventV1) -> Option<SessionEvent> {
    if !event_fields_are_canonical(&value) {
        return None;
    }
    let generation = SessionGeneration::new(value.generation);
    let base = SC_SESSION_FIELD_GENERATION;
    match value.event_type {
        SC_SESSION_EVENT_START
            if presence_matches(value.presence, base, 0) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::Start { generation })
        }
        SC_SESSION_EVENT_TRANSPORT_OPENED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::TransportOpened {
                generation,
                operation: operation(value.operation)?,
            })
        }
        SC_SESSION_EVENT_PEER_HELLO_ACK
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_IDENTITY,
                SC_SESSION_FIELD_AUTH_VERSION
                    | SC_SESSION_FIELD_CHALLENGE
                    | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            ) && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.approved == 0
                && value.valid == 0
                && value.success == 0 =>
        {
            Some(SessionEvent::PeerHelloAck {
                generation,
                peer: decode_identity(value.peer_identity)?,
                auth_version: (value.presence & SC_SESSION_FIELD_AUTH_VERSION != 0)
                    .then_some(value.auth_version),
                challenge: (value.presence & SC_SESSION_FIELD_CHALLENGE != 0)
                    .then(|| artifact(value.challenge))
                    .flatten(),
                enrollment: value.enrollment == 1,
                peer_enrollment_key: (value.presence & SC_SESSION_FIELD_PEER_ENROLLMENT_KEY != 0)
                    .then(|| artifact(value.peer_enrollment_key))
                    .flatten(),
            })
        }
        SC_SESSION_EVENT_PEER_HELLO
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_IDENTITY,
                SC_SESSION_FIELD_AUTH_VERSION | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::PeerHello {
                generation,
                peer: decode_identity(value.peer_identity)?,
                auth_version: (value.presence & SC_SESSION_FIELD_AUTH_VERSION != 0)
                    .then_some(value.auth_version),
                peer_enrollment_key: (value.presence & SC_SESSION_FIELD_PEER_ENROLLMENT_KEY != 0)
                    .then(|| artifact(value.peer_enrollment_key))
                    .flatten(),
            })
        }
        SC_SESSION_EVENT_CREDENTIAL_LOADED
            if value.enrollment == 0
                && value.approved == 0
                && value.valid == 0
                && value.success == 0 =>
        {
            let credential = match value.credential_state {
                SC_SESSION_CREDENTIAL_MISSING
                    if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0) =>
                {
                    CredentialState::Missing
                }
                SC_SESSION_CREDENTIAL_PRESENT
                    if presence_matches(
                        value.presence,
                        base | SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_CREDENTIAL,
                        0,
                    ) =>
                {
                    CredentialState::Present(artifact(value.credential)?)
                }
                SC_SESSION_CREDENTIAL_UNAVAILABLE
                    if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0) =>
                {
                    CredentialState::Unavailable
                }
                _ => return None,
            };
            Some(SessionEvent::CredentialLoaded {
                generation,
                operation: operation(value.operation)?,
                credential,
            })
        }
        SC_SESSION_EVENT_ENROLLMENT_OPENED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_CANDIDATE_CREDENTIAL,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::EnrollmentOpened {
                generation,
                operation: operation(value.operation)?,
                candidate_credential: artifact(value.candidate_credential)?,
            })
        }
        SC_SESSION_EVENT_ENROLLMENT_APPROVED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.valid == 0
                && value.success == 0 =>
        {
            Some(SessionEvent::EnrollmentApproved {
                generation,
                operation: operation(value.operation)?,
                approved: value.approved == 1,
            })
        }
        SC_SESSION_EVENT_ENROLLMENT_PREPARED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION
                    | SC_SESSION_FIELD_CANDIDATE_CREDENTIAL
                    | SC_SESSION_FIELD_CHALLENGE
                    | SC_SESSION_FIELD_ENVELOPE,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::EnrollmentPrepared {
                generation,
                operation: operation(value.operation)?,
                candidate_credential: artifact(value.candidate_credential)?,
                challenge: artifact(value.challenge)?,
                envelope: artifact(value.envelope)?,
            })
        }
        SC_SESSION_EVENT_CHALLENGE_GENERATED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_CHALLENGE,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::ChallengeGenerated {
                generation,
                operation: operation(value.operation)?,
                challenge: artifact(value.challenge)?,
            })
        }
        SC_SESSION_EVENT_AUTH_PROOF_CREATED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION
                    | SC_SESSION_FIELD_PROOF
                    | SC_SESSION_FIELD_LOCAL_CHALLENGE,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::AuthProofCreated {
                generation,
                operation: operation(value.operation)?,
                proof: artifact(value.proof)?,
                local_challenge: artifact(value.local_challenge)?,
            })
        }
        SC_SESSION_EVENT_PEER_AUTH
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_PROOF | SC_SESSION_FIELD_PEER_CHALLENGE,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::PeerAuth {
                generation,
                proof: artifact(value.proof)?,
                peer_challenge: artifact(value.peer_challenge)?,
            })
        }
        SC_SESSION_EVENT_PEER_PROOF_VERIFIED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.approved == 0
                && value.success == 0 =>
        {
            Some(SessionEvent::PeerProofVerified {
                generation,
                operation: operation(value.operation)?,
                valid: value.valid == 1,
            })
        }
        SC_SESSION_EVENT_ADMISSION_CLAIM_SUCCEEDED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_ADMISSION_CLAIM,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::AdmissionClaimSucceeded {
                generation,
                operation: operation(value.operation)?,
                claim: claim(value.admission_claim)?,
            })
        }
        SC_SESSION_EVENT_ADMISSION_CLAIM_FAILED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::AdmissionClaimFailed {
                generation,
                operation: operation(value.operation)?,
            })
        }
        SC_SESSION_EVENT_MUTUAL_PROOF_CREATED
            if presence_matches(
                value.presence,
                base | SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_PROOF,
                0,
            ) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::MutualProofCreated {
                generation,
                operation: operation(value.operation)?,
                proof: artifact(value.proof)?,
            })
        }
        SC_SESSION_EVENT_PEER_AUTH_ACK
            if presence_matches(value.presence, base | SC_SESSION_FIELD_PROOF, 0)
                && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::PeerAuthAck {
                generation,
                proof: artifact(value.proof)?,
            })
        }
        SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.approved == 0
                && value.success == 0 =>
        {
            Some(SessionEvent::MutualProofVerified {
                generation,
                operation: operation(value.operation)?,
                valid: value.valid == 1,
            })
        }
        SC_SESSION_EVENT_CREDENTIAL_WRITE_COMPLETED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.approved == 0
                && value.valid == 0 =>
        {
            Some(SessionEvent::CredentialWriteCompleted {
                generation,
                operation: operation(value.operation)?,
                success: value.success == 1,
            })
        }
        SC_SESSION_EVENT_FINAL_ACK_SUBMITTED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.approved == 0
                && value.valid == 0 =>
        {
            Some(SessionEvent::FinalAckSubmitted {
                generation,
                operation: operation(value.operation)?,
                success: value.success == 1,
            })
        }
        SC_SESSION_EVENT_CAPABILITIES_COMMITTED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_OPERATION, 0)
                && value.credential_state == SC_SESSION_CREDENTIAL_NONE
                && value.enrollment == 0
                && value.approved == 0
                && value.valid == 0 =>
        {
            Some(SessionEvent::CapabilitiesCommitted {
                generation,
                operation: operation(value.operation)?,
                success: value.success == 1,
            })
        }
        SC_SESSION_EVENT_STREAMING_STARTED
            if presence_matches(value.presence, base, 0) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::StreamingStarted { generation })
        }
        SC_SESSION_EVENT_CLOSE_REQUESTED
            if presence_matches(value.presence, base, 0) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::CloseRequested { generation })
        }
        SC_SESSION_EVENT_TRANSPORT_CLOSED
            if presence_matches(value.presence, base, 0) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::TransportClosed { generation })
        }
        SC_SESSION_EVENT_TRANSPORT_FAILED
            if presence_matches(value.presence, base, 0) && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::TransportFailed { generation })
        }
        SC_SESSION_EVENT_TIMER_FIRED
            if presence_matches(value.presence, base | SC_SESSION_FIELD_TIMER_TOKEN, 0)
                && event_flags_are_zero(&value) =>
        {
            Some(SessionEvent::TimerFired {
                generation,
                token: timer(value.timer_token)?,
            })
        }
        _ => None,
    }
}
