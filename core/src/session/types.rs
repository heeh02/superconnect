use crate::{
    auth_v1::{AuthV1Error, PeerId, MAX_PEER_ID_UTF8_BYTES},
    capability::MediaRole,
};

pub use crate::session_generation::SessionGeneration;

pub const AUTH_VERSION_1: u16 = 1;
pub const MAX_PEER_IDENTITY_BYTES: usize = MAX_PEER_ID_UTF8_BYTES;
pub const MAX_SESSION_EFFECTS: usize = 8;

macro_rules! nonzero_id {
    ($name:ident) => {
        #[repr(transparent)]
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(u64);

        impl $name {
            pub const fn new(value: u64) -> Option<Self> {
                if value == 0 {
                    None
                } else {
                    Some(Self(value))
                }
            }

            pub const fn get(self) -> u64 {
                self.0
            }
        }
    };
}

nonzero_id!(OperationId);
nonzero_id!(TimerToken);
nonzero_id!(ArtifactId);
nonzero_id!(AdmissionClaimId);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeerIdentityError {
    Empty,
    TooLong { requested: usize, maximum: usize },
    InvalidUtf8,
    ContainsDelimiter,
    ContainsControl,
    AuthContractRejected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BoundedPeerIdentity(PeerId);

impl BoundedPeerIdentity {
    pub fn from_static(value: &[u8]) -> Result<Self, PeerIdentityError> {
        Self::parse(value)
    }

    pub fn new(value: &[u8]) -> Result<Self, PeerIdentityError> {
        Self::parse(value)
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }

    fn parse(value: &[u8]) -> Result<Self, PeerIdentityError> {
        PeerId::try_from(value)
            .map(Self)
            .map_err(|error| Self::map_auth_error(error, value.len()))
    }

    fn map_auth_error(error: AuthV1Error, requested: usize) -> PeerIdentityError {
        match error {
            AuthV1Error::EmptyPeerId => PeerIdentityError::Empty,
            AuthV1Error::PeerIdTooLong => PeerIdentityError::TooLong {
                requested,
                maximum: MAX_PEER_IDENTITY_BYTES,
            },
            AuthV1Error::InvalidPeerIdUtf8 => PeerIdentityError::InvalidUtf8,
            AuthV1Error::PeerIdContainsDelimiter => PeerIdentityError::ContainsDelimiter,
            AuthV1Error::PeerIdContainsControl => PeerIdentityError::ContainsControl,
            AuthV1Error::InvalidLength { .. }
            | AuthV1Error::InvalidPrivateScalar
            | AuthV1Error::InvalidPublicKey
            | AuthV1Error::ContextOverflow
            | AuthV1Error::HmacInitializationFailed
            | AuthV1Error::KeyDerivationFailed
            | AuthV1Error::SealFailed
            | AuthV1Error::OpenFailed => PeerIdentityError::AuthContractRejected,
        }
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionSide {
    Initiator = 1,
    Responder = 2,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionOrigin {
    TrustedLocal = 1,
    MutualAuthenticationRequired = 2,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    Idle = 0,
    Transport = 1,
    Hello = 2,
    Credential = 3,
    Enrollment = 4,
    MutualAuth = 5,
    Admission = 6,
    FinalAck = 7,
    CapabilityCommit = 8,
    Ready = 9,
    Streaming = 10,
    Closing = 11,
    Closed = 12,
    Fatal = 13,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionConfigError {
    InvalidGeneration,
    InvalidFirstOperationId,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionConfig {
    pub(super) generation: SessionGeneration,
    pub(super) side: SessionSide,
    pub(super) media_role: MediaRole,
    pub(super) origin: SessionOrigin,
    pub(super) local_identity: BoundedPeerIdentity,
    pub(super) local_enrollment_key: ArtifactId,
    pub(super) first_operation_id: u64,
}

impl SessionConfig {
    pub const fn new(
        generation: SessionGeneration,
        side: SessionSide,
        media_role: MediaRole,
        origin: SessionOrigin,
        local_identity: BoundedPeerIdentity,
        local_enrollment_key: ArtifactId,
        first_operation_id: u64,
    ) -> Result<Self, SessionConfigError> {
        if generation.get() == SessionGeneration::INVALID.get() {
            return Err(SessionConfigError::InvalidGeneration);
        }
        if first_operation_id == 0 {
            return Err(SessionConfigError::InvalidFirstOperationId);
        }
        Ok(Self {
            generation,
            side,
            media_role,
            origin,
            local_identity,
            local_enrollment_key,
            first_operation_id,
        })
    }

    pub const fn generation(&self) -> SessionGeneration {
        self.generation
    }
    pub const fn side(&self) -> SessionSide {
        self.side
    }
    pub const fn media_role(&self) -> MediaRole {
        self.media_role
    }
    pub const fn origin(&self) -> SessionOrigin {
        self.origin
    }
    pub const fn local_identity(&self) -> BoundedPeerIdentity {
        self.local_identity
    }
    pub const fn local_enrollment_key(&self) -> ArtifactId {
        self.local_enrollment_key
    }
    pub const fn first_operation_id(&self) -> u64 {
        self.first_operation_id
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialState {
    Missing,
    Present(ArtifactId),
    Unavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionFatalReason {
    AuthenticationRequired,
    AuthenticationFailed,
    UnexpectedReenrollment,
    CredentialUnavailable,
    CapabilityCommitFailed,
    AdmissionRejected,
    HandshakeTimedOut,
    IdentifierSpaceExhausted,
    TransportFailed,
    FinalAckFailed,
    PairingRejected,
    ProtocolViolation,
}
