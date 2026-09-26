use crate::capability::MediaRole;
use crate::session::{
    ScSession as CoreSession, SessionFatalReason, SessionPhase, MAX_PEER_IDENTITY_BYTES,
    MAX_SESSION_EFFECTS,
};

pub const SC_SESSION_MAX_EFFECTS_V1: u32 = MAX_SESSION_EFFECTS as u32;
pub const SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1: u32 = MAX_PEER_IDENTITY_BYTES as u32;

pub const SC_SESSION_SIDE_INITIATOR: u32 = 1;
pub const SC_SESSION_SIDE_RESPONDER: u32 = 2;
pub const SC_SESSION_ORIGIN_TRUSTED_LOCAL: u32 = 1;
pub const SC_SESSION_ORIGIN_MUTUAL_AUTHENTICATION_REQUIRED: u32 = 2;
pub const SC_SESSION_MEDIA_ROLE_HOST: u32 = MediaRole::Host as u32;
pub const SC_SESSION_MEDIA_ROLE_RECEIVER: u32 = MediaRole::Receiver as u32;

pub const SC_SESSION_PHASE_IDLE: u32 = SessionPhase::Idle as u32;
pub const SC_SESSION_PHASE_TRANSPORT: u32 = SessionPhase::Transport as u32;
pub const SC_SESSION_PHASE_HELLO: u32 = SessionPhase::Hello as u32;
pub const SC_SESSION_PHASE_CREDENTIAL: u32 = SessionPhase::Credential as u32;
pub const SC_SESSION_PHASE_ENROLLMENT: u32 = SessionPhase::Enrollment as u32;
pub const SC_SESSION_PHASE_MUTUAL_AUTH: u32 = SessionPhase::MutualAuth as u32;
pub const SC_SESSION_PHASE_ADMISSION: u32 = SessionPhase::Admission as u32;
pub const SC_SESSION_PHASE_FINAL_ACK: u32 = SessionPhase::FinalAck as u32;
pub const SC_SESSION_PHASE_CAPABILITY_COMMIT: u32 = SessionPhase::CapabilityCommit as u32;
pub const SC_SESSION_PHASE_READY: u32 = SessionPhase::Ready as u32;
pub const SC_SESSION_PHASE_STREAMING: u32 = SessionPhase::Streaming as u32;
pub const SC_SESSION_PHASE_CLOSING: u32 = SessionPhase::Closing as u32;
pub const SC_SESSION_PHASE_CLOSED: u32 = SessionPhase::Closed as u32;
pub const SC_SESSION_PHASE_FATAL: u32 = SessionPhase::Fatal as u32;

pub const SC_SESSION_CREDENTIAL_NONE: u32 = 0;
pub const SC_SESSION_CREDENTIAL_MISSING: u32 = 1;
pub const SC_SESSION_CREDENTIAL_PRESENT: u32 = 2;
pub const SC_SESSION_CREDENTIAL_UNAVAILABLE: u32 = 3;

pub const SC_SESSION_FIELD_GENERATION: u64 = 1_u64 << 0;
pub const SC_SESSION_FIELD_OPERATION: u64 = 1_u64 << 1;
pub const SC_SESSION_FIELD_TIMER_TOKEN: u64 = 1_u64 << 2;
pub const SC_SESSION_FIELD_ADMISSION_CLAIM: u64 = 1_u64 << 3;
pub const SC_SESSION_FIELD_CREDENTIAL: u64 = 1_u64 << 4;
pub const SC_SESSION_FIELD_CANDIDATE_CREDENTIAL: u64 = 1_u64 << 5;
pub const SC_SESSION_FIELD_CHALLENGE: u64 = 1_u64 << 6;
pub const SC_SESSION_FIELD_LOCAL_CHALLENGE: u64 = 1_u64 << 7;
pub const SC_SESSION_FIELD_PEER_CHALLENGE: u64 = 1_u64 << 8;
pub const SC_SESSION_FIELD_PROOF: u64 = 1_u64 << 9;
pub const SC_SESSION_FIELD_ENVELOPE: u64 = 1_u64 << 10;
pub const SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY: u64 = 1_u64 << 11;
pub const SC_SESSION_FIELD_PEER_ENROLLMENT_KEY: u64 = 1_u64 << 12;
pub const SC_SESSION_FIELD_IDENTITY: u64 = 1_u64 << 13;
pub const SC_SESSION_FIELD_AUTH_VERSION: u64 = 1_u64 << 14;

pub(super) const KNOWN_FIELDS: u64 = SC_SESSION_FIELD_GENERATION
    | SC_SESSION_FIELD_OPERATION
    | SC_SESSION_FIELD_TIMER_TOKEN
    | SC_SESSION_FIELD_ADMISSION_CLAIM
    | SC_SESSION_FIELD_CREDENTIAL
    | SC_SESSION_FIELD_CANDIDATE_CREDENTIAL
    | SC_SESSION_FIELD_CHALLENGE
    | SC_SESSION_FIELD_LOCAL_CHALLENGE
    | SC_SESSION_FIELD_PEER_CHALLENGE
    | SC_SESSION_FIELD_PROOF
    | SC_SESSION_FIELD_ENVELOPE
    | SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY
    | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY
    | SC_SESSION_FIELD_IDENTITY
    | SC_SESSION_FIELD_AUTH_VERSION;

pub const SC_SESSION_EVENT_START: u32 = 1;
pub const SC_SESSION_EVENT_TRANSPORT_OPENED: u32 = 2;
pub const SC_SESSION_EVENT_PEER_HELLO_ACK: u32 = 3;
pub const SC_SESSION_EVENT_PEER_HELLO: u32 = 4;
pub const SC_SESSION_EVENT_CREDENTIAL_LOADED: u32 = 5;
pub const SC_SESSION_EVENT_ENROLLMENT_OPENED: u32 = 6;
pub const SC_SESSION_EVENT_ENROLLMENT_APPROVED: u32 = 7;
pub const SC_SESSION_EVENT_ENROLLMENT_PREPARED: u32 = 8;
pub const SC_SESSION_EVENT_CHALLENGE_GENERATED: u32 = 9;
pub const SC_SESSION_EVENT_AUTH_PROOF_CREATED: u32 = 10;
pub const SC_SESSION_EVENT_PEER_AUTH: u32 = 11;
pub const SC_SESSION_EVENT_PEER_PROOF_VERIFIED: u32 = 12;
pub const SC_SESSION_EVENT_ADMISSION_CLAIM_SUCCEEDED: u32 = 13;
pub const SC_SESSION_EVENT_ADMISSION_CLAIM_FAILED: u32 = 14;
pub const SC_SESSION_EVENT_MUTUAL_PROOF_CREATED: u32 = 15;
pub const SC_SESSION_EVENT_PEER_AUTH_ACK: u32 = 16;
pub const SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED: u32 = 17;
pub const SC_SESSION_EVENT_CREDENTIAL_WRITE_COMPLETED: u32 = 18;
pub const SC_SESSION_EVENT_FINAL_ACK_SUBMITTED: u32 = 19;
pub const SC_SESSION_EVENT_CAPABILITIES_COMMITTED: u32 = 20;
pub const SC_SESSION_EVENT_STREAMING_STARTED: u32 = 21;
pub const SC_SESSION_EVENT_CLOSE_REQUESTED: u32 = 22;
pub const SC_SESSION_EVENT_TRANSPORT_CLOSED: u32 = 23;
pub const SC_SESSION_EVENT_TRANSPORT_FAILED: u32 = 24;
pub const SC_SESSION_EVENT_TIMER_FIRED: u32 = 25;

pub const SC_SESSION_EFFECT_OPEN_TRANSPORT: u32 = 1;
pub const SC_SESSION_EFFECT_ARM_HANDSHAKE_TIMER: u32 = 2;
pub const SC_SESSION_EFFECT_CANCEL_HANDSHAKE_TIMER: u32 = 3;
pub const SC_SESSION_EFFECT_SEND_HELLO: u32 = 4;
pub const SC_SESSION_EFFECT_LOAD_CREDENTIAL: u32 = 5;
pub const SC_SESSION_EFFECT_OPEN_ENROLLMENT: u32 = 6;
pub const SC_SESSION_EFFECT_REQUEST_ENROLLMENT_APPROVAL: u32 = 7;
pub const SC_SESSION_EFFECT_PREPARE_ENROLLMENT: u32 = 8;
pub const SC_SESSION_EFFECT_GENERATE_CHALLENGE: u32 = 9;
pub const SC_SESSION_EFFECT_SEND_HELLO_ACK: u32 = 10;
pub const SC_SESSION_EFFECT_SEND_ENROLLMENT: u32 = 11;
pub const SC_SESSION_EFFECT_CREATE_AUTH_PROOF: u32 = 12;
pub const SC_SESSION_EFFECT_VERIFY_PEER_PROOF: u32 = 13;
pub const SC_SESSION_EFFECT_CLAIM_ADMISSION: u32 = 14;
pub const SC_SESSION_EFFECT_CREATE_MUTUAL_PROOF: u32 = 15;
pub const SC_SESSION_EFFECT_SUBMIT_FINAL_AUTH_ACK: u32 = 16;
pub const SC_SESSION_EFFECT_SUBMIT_FINAL_HELLO_ACK: u32 = 17;
pub const SC_SESSION_EFFECT_SEND_AUTH: u32 = 18;
pub const SC_SESSION_EFFECT_VERIFY_MUTUAL_PROOF: u32 = 19;
pub const SC_SESSION_EFFECT_WRITE_CREDENTIAL: u32 = 20;
pub const SC_SESSION_EFFECT_CANCEL_CREDENTIAL_WRITE: u32 = 21;
pub const SC_SESSION_EFFECT_COMMIT_CAPABILITIES: u32 = 22;
pub const SC_SESSION_EFFECT_NOTIFY_READY: u32 = 23;
pub const SC_SESSION_EFFECT_NOTIFY_STREAMING: u32 = 24;
pub const SC_SESSION_EFFECT_CLOSE_TRANSPORT: u32 = 25;
pub const SC_SESSION_EFFECT_NOTIFY_CLOSED: u32 = 26;
pub const SC_SESSION_EFFECT_RELEASE_ADMISSION: u32 = 27;
pub const SC_SESSION_EFFECT_NOTIFY_FATAL: u32 = 28;

pub const SC_SESSION_FATAL_NONE: u32 = 0;
pub const SC_SESSION_FATAL_AUTHENTICATION_REQUIRED: u32 = 1;
pub const SC_SESSION_FATAL_AUTHENTICATION_FAILED: u32 = 2;
pub const SC_SESSION_FATAL_UNEXPECTED_REENROLLMENT: u32 = 3;
pub const SC_SESSION_FATAL_CREDENTIAL_UNAVAILABLE: u32 = 4;
pub const SC_SESSION_FATAL_CAPABILITY_COMMIT_FAILED: u32 = 5;
pub const SC_SESSION_FATAL_ADMISSION_REJECTED: u32 = 6;
pub const SC_SESSION_FATAL_HANDSHAKE_TIMED_OUT: u32 = 7;
pub const SC_SESSION_FATAL_IDENTIFIER_SPACE_EXHAUSTED: u32 = 8;
pub const SC_SESSION_FATAL_TRANSPORT_FAILED: u32 = 9;
pub const SC_SESSION_FATAL_FINAL_ACK_FAILED: u32 = 10;
pub const SC_SESSION_FATAL_PAIRING_REJECTED: u32 = 11;
pub const SC_SESSION_FATAL_PROTOCOL_VIOLATION: u32 = 12;

pub(crate) fn session_fatal_reason_from_value(value: u32) -> Option<SessionFatalReason> {
    match value {
        SC_SESSION_FATAL_AUTHENTICATION_REQUIRED => {
            Some(SessionFatalReason::AuthenticationRequired)
        }
        SC_SESSION_FATAL_AUTHENTICATION_FAILED => Some(SessionFatalReason::AuthenticationFailed),
        SC_SESSION_FATAL_UNEXPECTED_REENROLLMENT => {
            Some(SessionFatalReason::UnexpectedReenrollment)
        }
        SC_SESSION_FATAL_CREDENTIAL_UNAVAILABLE => Some(SessionFatalReason::CredentialUnavailable),
        SC_SESSION_FATAL_CAPABILITY_COMMIT_FAILED => {
            Some(SessionFatalReason::CapabilityCommitFailed)
        }
        SC_SESSION_FATAL_ADMISSION_REJECTED => Some(SessionFatalReason::AdmissionRejected),
        SC_SESSION_FATAL_HANDSHAKE_TIMED_OUT => Some(SessionFatalReason::HandshakeTimedOut),
        SC_SESSION_FATAL_IDENTIFIER_SPACE_EXHAUSTED => {
            Some(SessionFatalReason::IdentifierSpaceExhausted)
        }
        SC_SESSION_FATAL_TRANSPORT_FAILED => Some(SessionFatalReason::TransportFailed),
        SC_SESSION_FATAL_FINAL_ACK_FAILED => Some(SessionFatalReason::FinalAckFailed),
        SC_SESSION_FATAL_PAIRING_REJECTED => Some(SessionFatalReason::PairingRejected),
        SC_SESSION_FATAL_PROTOCOL_VIOLATION => Some(SessionFatalReason::ProtocolViolation),
        _ => None,
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScSessionPeerIdentityV1 {
    pub length: u32,
    pub bytes: [u8; MAX_PEER_IDENTITY_BYTES],
}

impl Default for ScSessionPeerIdentityV1 {
    fn default() -> Self {
        Self {
            length: 0,
            bytes: [0; MAX_PEER_IDENTITY_BYTES],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSessionConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub first_operation_id: u64,
    pub local_enrollment_key: u64,
    pub side: u32,
    pub media_role: u32,
    pub origin: u32,
    pub reserved0: u32,
    pub local_identity: ScSessionPeerIdentityV1,
    pub reserved1: u32,
    pub reserved2: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSessionEventV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub event_type: u32,
    pub credential_state: u32,
    pub presence: u64,
    pub generation: u64,
    pub operation: u64,
    pub timer_token: u64,
    pub admission_claim: u64,
    pub credential: u64,
    pub candidate_credential: u64,
    pub challenge: u64,
    pub local_challenge: u64,
    pub peer_challenge: u64,
    pub proof: u64,
    pub envelope: u64,
    pub local_enrollment_key: u64,
    pub peer_enrollment_key: u64,
    pub auth_version: u16,
    pub enrollment: u8,
    pub approved: u8,
    pub valid: u8,
    pub success: u8,
    pub reserved0: [u8; 2],
    pub peer_identity: ScSessionPeerIdentityV1,
    pub reserved1: u32,
    pub reserved2: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSessionEffectV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub effect_type: u32,
    pub fatal_reason: u32,
    pub presence: u64,
    pub generation: u64,
    pub operation: u64,
    pub timer_token: u64,
    pub admission_claim: u64,
    pub credential: u64,
    pub candidate_credential: u64,
    pub challenge: u64,
    pub local_challenge: u64,
    pub peer_challenge: u64,
    pub proof: u64,
    pub envelope: u64,
    pub local_enrollment_key: u64,
    pub peer_enrollment_key: u64,
    pub auth_version: u16,
    pub media_role: u8,
    pub enrollment: u8,
    pub reserved0: u32,
    pub identity: ScSessionPeerIdentityV1,
    pub reserved1: u32,
    pub reserved2: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSessionSnapshotV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub first_operation_id: u64,
    pub local_enrollment_key: u64,
    pub phase: u32,
    pub side: u32,
    pub media_role: u32,
    pub origin: u32,
    pub pending_timer_count: u32,
    pub pending_operation_count: u32,
    pub invariants_hold: u32,
    pub reserved0: u32,
    pub local_identity: ScSessionPeerIdentityV1,
    pub reserved1: u32,
    pub reserved2: u64,
}

#[repr(C)]
pub struct ScSessionV1 {
    pub(super) inner: CoreSession,
    pub(super) config: ScSessionConfigV1,
}
