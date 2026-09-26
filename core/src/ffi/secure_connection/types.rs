use std::collections::VecDeque;

use crate::secure_connection::{
    ScSecureConnection as CoreSecureConnection, SecureConnectionEffect, SecureInboundFrame,
    MAX_SECURE_CONNECTION_EFFECTS, MAX_SECURE_INBOUND_FRAMES,
};

use super::super::{ScControlEnvelopeV1, ScSessionConfigV1, ScSessionEffectV1};

pub const SC_SECURE_CONNECTION_MAX_EFFECTS_V1: u32 = MAX_SECURE_CONNECTION_EFFECTS as u32;
pub const SC_SECURE_CONNECTION_MAX_INBOUND_FRAMES_V1: u32 = MAX_SECURE_INBOUND_FRAMES as u32;
pub const SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1: usize = 32;

pub const SC_SECURE_CONNECTION_RECORD_NOT_REQUIRED_V1: u32 = 0;
pub const SC_SECURE_CONNECTION_RECORD_INACTIVE_V1: u32 = 1;
pub const SC_SECURE_CONNECTION_RECORD_PREPARING_V1: u32 = 2;
pub const SC_SECURE_CONNECTION_RECORD_ACTIVATING_V1: u32 = 3;
pub const SC_SECURE_CONNECTION_RECORD_ACTIVE_V1: u32 = 4;
pub const SC_SECURE_CONNECTION_RECORD_DISPOSED_V1: u32 = 5;

pub const SC_SECURE_CONNECTION_EFFECT_SESSION_V1: u32 = 1;
pub const SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1: u32 = 2;
pub const SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1: u32 = 3;
pub const SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1: u32 = 4;

pub const SC_SECURE_CONNECTION_PROTOCOL_REJECTED: i32 = 120;
pub const SC_SECURE_CONNECTION_NOT_ACTIVE: i32 = 121;
pub const SC_SECURE_CONNECTION_PENDING_OUTPUT: i32 = 122;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSecureConnectionConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub session: ScSessionConfigV1,
    pub max_plaintext_bytes: u64,
    pub reserved0: u64,
    pub reserved1: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScSecureRecordMaterialV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub operation: u64,
    pub success: u8,
    pub reserved0: [u8; 7],
    pub pair_secret: [u8; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
    pub responder_challenge: [u8; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
    pub initiator_challenge: [u8; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
    pub reserved1: u64,
}

impl Default for ScSecureRecordMaterialV1 {
    fn default() -> Self {
        Self {
            struct_size: 0,
            api_version: 0,
            generation: 0,
            operation: 0,
            success: 0,
            reserved0: [0; 7],
            pair_secret: [0; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
            responder_challenge: [0; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
            initiator_challenge: [0; SC_SECURE_CONNECTION_RECORD_SECRET_BYTES_V1],
            reserved1: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSecureConnectionEffectV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub effect_type: u32,
    pub reserved0: u32,
    pub generation: u64,
    pub operation: u64,
    pub session_effect: ScSessionEffectV1,
    pub reserved1: u64,
    pub reserved2: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSecureConnectionSnapshotV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub session_phase: u32,
    pub record_phase: u32,
    pub records_active: u32,
    pub records_required: u32,
    pub invariants_hold: u32,
    pub pending_effect_count: u32,
    pub pending_inbound_count: u32,
    pub inbound_view_outstanding: u32,
    pub reserved0: u64,
    pub reserved1: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScSecureInboundViewV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub channel: u8,
    pub flags: u8,
    pub control_present: u8,
    pub reserved0: u8,
    pub reserved1: u32,
    pub payload: *const u8,
    pub payload_length: usize,
    pub generation: u64,
    pub control: ScControlEnvelopeV1,
    pub reserved2: u64,
}

pub(super) struct QueuedInbound {
    pub(super) generation: u64,
    pub(super) frame: SecureInboundFrame,
}

#[repr(C)]
pub struct ScSecureConnectionV1 {
    pub(super) inner: CoreSecureConnection,
    pub(super) effects: VecDeque<SecureConnectionEffect>,
    pub(super) inbound: VecDeque<QueuedInbound>,
    pub(super) next_inbound_generation: u64,
    pub(super) borrowed_inbound_generation: Option<u64>,
}
