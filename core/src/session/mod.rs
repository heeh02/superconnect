//! Platform-neutral semantic session reducer.
//!
//! The reducer retains only bounded value state. Drivers own transport, crypto,
//! credentials, entropy, clocks, admission, and capability negotiation, execute
//! typed effects, and return typed completion events.

mod authentication;
mod control_wire;
mod effect;
mod event;
mod handshake;
mod hello_wire;
mod reducer;
mod state;
mod types;

pub use control_wire::{
    decode_session_control_wire_v1, encode_session_control_wire_v1, SessionControlWireErrorV1,
    SessionControlWireKindV1, SessionControlWireV1, SESSION_CONTROL_WIRE_MAX_BYTES_V1,
};
pub use effect::{SessionEffect, SessionEffects};
pub use event::SessionEvent;
pub use hello_wire::{
    decode_session_hello_wire_v1, encode_session_hello_wire_v1, SessionHelloCapsV1,
    SessionHelloProjectionV1, SessionHelloRoleV1, SessionHelloWireErrorV1, SessionHelloWireKindV1,
    SessionHelloWireV1, SESSION_HELLO_WIRE_MAX_BYTES_V1,
};
pub use reducer::ScSession;
pub use types::{
    AdmissionClaimId, ArtifactId, BoundedPeerIdentity, CredentialState, OperationId,
    PeerIdentityError, SessionConfig, SessionConfigError, SessionFatalReason, SessionGeneration,
    SessionOrigin, SessionPhase, SessionSide, TimerToken, AUTH_VERSION_1, MAX_PEER_IDENTITY_BYTES,
    MAX_SESSION_EFFECTS,
};
