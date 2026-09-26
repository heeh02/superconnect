use crate::capability::MAX_NEGOTIATION_EFFECTS;

pub const SC_CAPABILITY_INTENT_API_VERSION_V2: u32 = 2;
pub const SC_CAPABILITY_INTENT_MAX_EFFECTS_V2: usize = MAX_NEGOTIATION_EFFECTS;

pub const SC_CAPABILITY_INTENT_SIDE_OFFERER: u8 = 1;
pub const SC_CAPABILITY_INTENT_SIDE_SELECTOR: u8 = 2;

pub const SC_CAPABILITY_INTENT_EVENT_PEER_HELLO: u8 = 1;
pub const SC_CAPABILITY_INTENT_EVENT_OFFER: u8 = 2;
pub const SC_CAPABILITY_INTENT_EVENT_SELECTION: u8 = 3;
pub const SC_CAPABILITY_INTENT_EVENT_COMMIT: u8 = 4;

pub const SC_CAPABILITY_INTENT_EFFECT_SEND_OFFER: u8 = 1;
pub const SC_CAPABILITY_INTENT_EFFECT_SEND_SELECTION: u8 = 2;
pub const SC_CAPABILITY_INTENT_EFFECT_SEND_COMMIT: u8 = 3;
pub const SC_CAPABILITY_INTENT_EFFECT_COMMITTED: u8 = 4;
pub const SC_CAPABILITY_INTENT_EFFECT_CONNECTED: u8 = 5;
pub const SC_CAPABILITY_INTENT_EFFECT_REJECTED: u8 = 6;
pub const SC_CAPABILITY_INTENT_EFFECT_FATAL: u8 = 7;

pub const SC_CAPABILITY_INTENT_REASON_NONE: u8 = 0;
pub const SC_CAPABILITY_INTENT_REASON_OUT_OF_ORDER: u8 = 1;
pub const SC_CAPABILITY_INTENT_REASON_STALE_GENERATION: u8 = 2;
pub const SC_CAPABILITY_INTENT_REASON_UNSUPPORTED_VERSION: u8 = 3;
pub const SC_CAPABILITY_INTENT_REASON_ROLE_MISMATCH: u8 = 4;
pub const SC_CAPABILITY_INTENT_REASON_PROJECTION_MISMATCH: u8 = 5;
pub const SC_CAPABILITY_INTENT_REASON_TRANSPORT_MISMATCH: u8 = 6;
pub const SC_CAPABILITY_INTENT_REASON_INTENT_MISMATCH: u8 = 7;
pub const SC_CAPABILITY_INTENT_REASON_COMMIT_MISMATCH: u8 = 8;
pub const SC_CAPABILITY_INTENT_REASON_LEGACY_INTENT_MISMATCH: u8 = 9;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityIntentConfigV2 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub product_capabilities: u64,
    pub peer_capabilities: u64,
    pub side: u8,
    pub desired_peer_role: u8,
    pub local_role: u8,
    pub source_topology: u8,
    pub sink_presentation: u8,
    pub input_policy: u8,
    pub transport_preference: u8,
    pub topology: u8,
    pub reserved: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityIntentEventV2 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub negotiation_version: u16,
    pub event_type: u8,
    pub has_negotiation_version: u8,
    pub offerer_role: u8,
    pub selector_role: u8,
    pub projection: u8,
    pub transport: u8,
    pub local_role: u8,
    pub source_topology: u8,
    pub sink_presentation: u8,
    pub input_policy: u8,
    pub transport_preference: u8,
    pub topology: u8,
    pub reserved0: [u8; 2],
    pub reserved1: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityIntentProfileV2 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub capabilities: u64,
    pub sender_role: u8,
    pub reserved: [u8; 7],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityIntentEffectV2 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub expected_generation: u64,
    pub received_generation: u64,
    pub negotiation_version: u16,
    pub expected_version: u16,
    pub received_version: u16,
    pub effect_type: u8,
    pub reason: u8,
    pub offerer_role: u8,
    pub selector_role: u8,
    pub local_role: u8,
    pub peer_role: u8,
    pub projection: u8,
    pub transport: u8,
    pub negotiated: u8,
    pub reserved0: u8,
    pub resolved_local_role: u8,
    pub resolved_source_topology: u8,
    pub resolved_sink_presentation: u8,
    pub resolved_input_policy: u8,
    pub resolved_transport_preference: u8,
    pub resolved_topology: u8,
    pub expected_role: u8,
    pub received_role: u8,
    pub expected_projection: u8,
    pub received_projection: u8,
    pub expected_transport: u8,
    pub received_transport: u8,
    pub reserved1: u32,
    pub reserved2: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCapabilityIntentSnapshotV2 {
    pub struct_size: u32,
    pub api_version: u32,
    pub generation: u64,
    pub product_capabilities: u64,
    pub peer_capabilities: u64,
    pub side: u8,
    pub desired_peer_role: u8,
    pub has_binding: u8,
    pub binding_negotiated: u8,
    pub resolved_local_role: u8,
    pub resolved_source_topology: u8,
    pub resolved_sink_presentation: u8,
    pub resolved_input_policy: u8,
    pub resolved_transport_preference: u8,
    pub resolved_topology: u8,
    pub binding_local_role: u8,
    pub binding_source_topology: u8,
    pub binding_sink_presentation: u8,
    pub binding_input_policy: u8,
    pub binding_transport_preference: u8,
    pub binding_topology: u8,
    pub binding_peer_role: u8,
    pub reserved0: [u8; 7],
    pub reserved1: u64,
}
