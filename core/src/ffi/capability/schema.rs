use crate::capability::{
    CapabilityId, MediaRole, ProjectionIntent, TransportKind, MAX_NEGOTIATION_EFFECTS,
};

pub const SC_CAPABILITY_MAX_EFFECTS_V1: usize = MAX_NEGOTIATION_EFFECTS;

pub const SC_CAPABILITY_SIDE_OFFERER: u8 = 1;
pub const SC_CAPABILITY_SIDE_SELECTOR: u8 = 2;

pub const SC_CAPABILITY_ROLE_HOST: u8 = MediaRole::Host as u8;
pub const SC_CAPABILITY_ROLE_RECEIVER: u8 = MediaRole::Receiver as u8;

pub const SC_CAPABILITY_PROJECTION_EXTEND: u8 = ProjectionIntent::Extend as u8;
pub const SC_CAPABILITY_PROJECTION_MIRROR: u8 = ProjectionIntent::Mirror as u8;
pub const SC_CAPABILITY_PROJECTION_PRIMARY: u8 = ProjectionIntent::Primary as u8;

pub const SC_CAPABILITY_TRANSPORT_TCP: u8 = TransportKind::Tcp as u8;

pub const SC_CAPABILITY_ID_MEDIA_HOST: u8 = CapabilityId::MediaHost as u8;
pub const SC_CAPABILITY_ID_MEDIA_RECEIVER: u8 = CapabilityId::MediaReceiver as u8;
pub const SC_CAPABILITY_ID_PROJECTION_EXTEND: u8 = CapabilityId::ProjectionExtend as u8;
pub const SC_CAPABILITY_ID_PROJECTION_MIRROR: u8 = CapabilityId::ProjectionMirror as u8;
pub const SC_CAPABILITY_ID_PROJECTION_PRIMARY: u8 = CapabilityId::ProjectionPrimary as u8;
pub const SC_CAPABILITY_ID_TRANSPORT_TCP: u8 = CapabilityId::TransportTcp as u8;

pub const SC_CAPABILITY_BIT_MEDIA_HOST: u64 = 1_u64 << SC_CAPABILITY_ID_MEDIA_HOST;
pub const SC_CAPABILITY_BIT_MEDIA_RECEIVER: u64 = 1_u64 << SC_CAPABILITY_ID_MEDIA_RECEIVER;
pub const SC_CAPABILITY_BIT_PROJECTION_EXTEND: u64 = 1_u64 << SC_CAPABILITY_ID_PROJECTION_EXTEND;
pub const SC_CAPABILITY_BIT_PROJECTION_MIRROR: u64 = 1_u64 << SC_CAPABILITY_ID_PROJECTION_MIRROR;
pub const SC_CAPABILITY_BIT_PROJECTION_PRIMARY: u64 = 1_u64 << SC_CAPABILITY_ID_PROJECTION_PRIMARY;
pub const SC_CAPABILITY_BIT_TRANSPORT_TCP: u64 = 1_u64 << SC_CAPABILITY_ID_TRANSPORT_TCP;

pub(super) const KNOWN_CAPABILITY_BITS: u64 = SC_CAPABILITY_BIT_MEDIA_HOST
    | SC_CAPABILITY_BIT_MEDIA_RECEIVER
    | SC_CAPABILITY_BIT_PROJECTION_EXTEND
    | SC_CAPABILITY_BIT_PROJECTION_MIRROR
    | SC_CAPABILITY_BIT_PROJECTION_PRIMARY
    | SC_CAPABILITY_BIT_TRANSPORT_TCP;

pub const SC_CAPABILITY_EVENT_PEER_HELLO: u8 = 1;
pub const SC_CAPABILITY_EVENT_OFFER: u8 = 2;
pub const SC_CAPABILITY_EVENT_SELECTION: u8 = 3;
pub const SC_CAPABILITY_EVENT_COMMIT: u8 = 4;

pub const SC_CAPABILITY_EFFECT_SEND_OFFER: u8 = 1;
pub const SC_CAPABILITY_EFFECT_SEND_SELECTION: u8 = 2;
pub const SC_CAPABILITY_EFFECT_SEND_COMMIT: u8 = 3;
pub const SC_CAPABILITY_EFFECT_COMMITTED: u8 = 4;
pub const SC_CAPABILITY_EFFECT_CONNECTED: u8 = 5;
pub const SC_CAPABILITY_EFFECT_REJECTED: u8 = 6;
pub const SC_CAPABILITY_EFFECT_FATAL: u8 = 7;

pub const SC_CAPABILITY_REASON_NONE: u8 = 0;
pub const SC_CAPABILITY_REASON_OUT_OF_ORDER: u8 = 1;
pub const SC_CAPABILITY_REASON_STALE_GENERATION: u8 = 2;
pub const SC_CAPABILITY_REASON_UNSUPPORTED_VERSION: u8 = 3;
pub const SC_CAPABILITY_REASON_UNSUPPORTED_CAPABILITY: u8 = 4;
pub const SC_CAPABILITY_REASON_ROLE_MISMATCH: u8 = 5;
pub const SC_CAPABILITY_REASON_PROJECTION_MISMATCH: u8 = 6;
pub const SC_CAPABILITY_REASON_COMMIT_MISMATCH: u8 = 7;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub authorized_capabilities: u64,
    pub side: u8,
    pub local_role: u8,
    pub desired_peer_role: u8,
    pub projection: u8,
    pub transport: u8,
    pub reserved0: [u8; 3],
    pub reserved1: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityEventV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub capabilities: u64,
    pub negotiation_version: u16,
    pub event_type: u8,
    pub has_negotiation_version: u8,
    pub offerer_role: u8,
    pub selector_role: u8,
    pub projection: u8,
    pub transport: u8,
    pub reserved: [u8; 8],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityEffectV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub capabilities: u64,
    pub expected_generation: u64,
    pub received_generation: u64,
    pub negotiation_version: u16,
    pub expected_version: u16,
    pub received_version: u16,
    pub effect_type: u8,
    pub reason: u8,
    pub capability: u8,
    pub offerer_role: u8,
    pub selector_role: u8,
    pub local_role: u8,
    pub peer_role: u8,
    pub expected_role: u8,
    pub received_role: u8,
    pub projection: u8,
    pub expected_projection: u8,
    pub received_projection: u8,
    pub transport: u8,
    pub negotiated: u8,
    pub reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilitySnapshotV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub authorized_capabilities: u64,
    pub side: u8,
    pub local_role: u8,
    pub desired_peer_role: u8,
    pub projection: u8,
    pub transport: u8,
    pub has_binding: u8,
    pub binding_local_role: u8,
    pub binding_peer_role: u8,
    pub binding_projection: u8,
    pub binding_transport: u8,
    pub binding_negotiated: u8,
    pub reserved0: [u8; 5],
    pub reserved1: u64,
}
