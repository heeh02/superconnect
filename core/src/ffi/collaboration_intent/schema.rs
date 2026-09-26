use crate::collaboration_intent::{
    InputPolicy, IntentAxis, LocalRole, SinkPresentation, SourceTopology, Topology,
    TransportPreference,
};

use super::super::ScStatus;

pub const SC_COLLABORATION_INTENT_REJECTED: ScStatus = 110;

pub const SC_COLLABORATION_INTENT_ROLE_SOURCE: u8 = LocalRole::Source as u8;
pub const SC_COLLABORATION_INTENT_ROLE_SINK: u8 = LocalRole::Sink as u8;
pub const SC_COLLABORATION_INTENT_ROLE_RELAY: u8 = LocalRole::Relay as u8;

pub const SC_COLLABORATION_INTENT_SOURCE_EXTEND: u8 = SourceTopology::Extend as u8;
pub const SC_COLLABORATION_INTENT_SOURCE_MIRROR: u8 = SourceTopology::Mirror as u8;
pub const SC_COLLABORATION_INTENT_SOURCE_PRIMARY: u8 = SourceTopology::Primary as u8;
pub const SC_COLLABORATION_INTENT_SOURCE_APPLICATION: u8 = SourceTopology::Application as u8;

pub const SC_COLLABORATION_INTENT_SINK_WINDOWED: u8 = SinkPresentation::Windowed as u8;
pub const SC_COLLABORATION_INTENT_SINK_FULLSCREEN: u8 = SinkPresentation::Fullscreen as u8;
pub const SC_COLLABORATION_INTENT_SINK_PICTURE_IN_PICTURE: u8 =
    SinkPresentation::PictureInPicture as u8;

pub const SC_COLLABORATION_INTENT_INPUT_VIEW_ONLY: u8 = InputPolicy::ViewOnly as u8;
pub const SC_COLLABORATION_INTENT_INPUT_REMOTE_CONTROL: u8 = InputPolicy::RemoteControl as u8;
pub const SC_COLLABORATION_INTENT_INPUT_REQUEST_CONTROL: u8 = InputPolicy::RequestControl as u8;

pub const SC_COLLABORATION_INTENT_TRANSPORT_RELIABLE: u8 = TransportPreference::Reliable as u8;
pub const SC_COLLABORATION_INTENT_TRANSPORT_LOWEST_LATENCY: u8 =
    TransportPreference::LowestLatency as u8;
pub const SC_COLLABORATION_INTENT_TRANSPORT_AUTOMATIC: u8 = TransportPreference::Automatic as u8;

pub const SC_COLLABORATION_INTENT_TOPOLOGY_DIRECT: u8 = Topology::Direct as u8;
pub const SC_COLLABORATION_INTENT_TOPOLOGY_LOCAL_MULTI_PEER: u8 = Topology::LocalMultiPeer as u8;
pub const SC_COLLABORATION_INTENT_TOPOLOGY_RELAYED: u8 = Topology::Relayed as u8;

pub const SC_COLLABORATION_INTENT_AXIS_LOCAL_ROLE: u8 = IntentAxis::LocalRole as u8;
pub const SC_COLLABORATION_INTENT_AXIS_SOURCE_TOPOLOGY: u8 = IntentAxis::SourceTopology as u8;
pub const SC_COLLABORATION_INTENT_AXIS_SINK_PRESENTATION: u8 = IntentAxis::SinkPresentation as u8;
pub const SC_COLLABORATION_INTENT_AXIS_INPUT_POLICY: u8 = IntentAxis::InputPolicy as u8;
pub const SC_COLLABORATION_INTENT_AXIS_TRANSPORT_PREFERENCE: u8 =
    IntentAxis::TransportPreference as u8;
pub const SC_COLLABORATION_INTENT_AXIS_TOPOLOGY: u8 = IntentAxis::Topology as u8;

pub const SC_COLLABORATION_INTENT_SIDE_NONE: u8 = 0;
pub const SC_COLLABORATION_INTENT_SIDE_PRODUCT: u8 = 1;
pub const SC_COLLABORATION_INTENT_SIDE_PEER: u8 = 2;

pub const SC_COLLABORATION_INTENT_ERROR_NONE: u8 = 0;
pub const SC_COLLABORATION_INTENT_ERROR_INVALID_COMBINATION: u8 = 1;
pub const SC_COLLABORATION_INTENT_ERROR_MISSING_CAPABILITY: u8 = 2;

pub const SC_COLLABORATION_INTENT_BIT_ROLE_SOURCE: u64 = 1_u64 << 0;
pub const SC_COLLABORATION_INTENT_BIT_ROLE_SINK: u64 = 1_u64 << 1;
pub const SC_COLLABORATION_INTENT_BIT_ROLE_RELAY: u64 = 1_u64 << 2;
pub const SC_COLLABORATION_INTENT_BIT_SOURCE_EXTEND: u64 = 1_u64 << 8;
pub const SC_COLLABORATION_INTENT_BIT_SOURCE_MIRROR: u64 = 1_u64 << 9;
pub const SC_COLLABORATION_INTENT_BIT_SOURCE_PRIMARY: u64 = 1_u64 << 10;
pub const SC_COLLABORATION_INTENT_BIT_SOURCE_APPLICATION: u64 = 1_u64 << 11;
pub const SC_COLLABORATION_INTENT_BIT_SINK_WINDOWED: u64 = 1_u64 << 16;
pub const SC_COLLABORATION_INTENT_BIT_SINK_FULLSCREEN: u64 = 1_u64 << 17;
pub const SC_COLLABORATION_INTENT_BIT_SINK_PICTURE_IN_PICTURE: u64 = 1_u64 << 18;
pub const SC_COLLABORATION_INTENT_BIT_INPUT_VIEW_ONLY: u64 = 1_u64 << 24;
pub const SC_COLLABORATION_INTENT_BIT_INPUT_REMOTE_CONTROL: u64 = 1_u64 << 25;
pub const SC_COLLABORATION_INTENT_BIT_INPUT_REQUEST_CONTROL: u64 = 1_u64 << 26;
pub const SC_COLLABORATION_INTENT_BIT_TRANSPORT_RELIABLE: u64 = 1_u64 << 32;
pub const SC_COLLABORATION_INTENT_BIT_TRANSPORT_LOWEST_LATENCY: u64 = 1_u64 << 33;
pub const SC_COLLABORATION_INTENT_BIT_TRANSPORT_AUTOMATIC: u64 = 1_u64 << 34;
pub const SC_COLLABORATION_INTENT_BIT_TOPOLOGY_DIRECT: u64 = 1_u64 << 40;
pub const SC_COLLABORATION_INTENT_BIT_TOPOLOGY_LOCAL_MULTI_PEER: u64 = 1_u64 << 41;
pub const SC_COLLABORATION_INTENT_BIT_TOPOLOGY_RELAYED: u64 = 1_u64 << 42;

pub(super) const KNOWN_INTENT_BITS: u64 = SC_COLLABORATION_INTENT_BIT_ROLE_SOURCE
    | SC_COLLABORATION_INTENT_BIT_ROLE_SINK
    | SC_COLLABORATION_INTENT_BIT_ROLE_RELAY
    | SC_COLLABORATION_INTENT_BIT_SOURCE_EXTEND
    | SC_COLLABORATION_INTENT_BIT_SOURCE_MIRROR
    | SC_COLLABORATION_INTENT_BIT_SOURCE_PRIMARY
    | SC_COLLABORATION_INTENT_BIT_SOURCE_APPLICATION
    | SC_COLLABORATION_INTENT_BIT_SINK_WINDOWED
    | SC_COLLABORATION_INTENT_BIT_SINK_FULLSCREEN
    | SC_COLLABORATION_INTENT_BIT_SINK_PICTURE_IN_PICTURE
    | SC_COLLABORATION_INTENT_BIT_INPUT_VIEW_ONLY
    | SC_COLLABORATION_INTENT_BIT_INPUT_REMOTE_CONTROL
    | SC_COLLABORATION_INTENT_BIT_INPUT_REQUEST_CONTROL
    | SC_COLLABORATION_INTENT_BIT_TRANSPORT_RELIABLE
    | SC_COLLABORATION_INTENT_BIT_TRANSPORT_LOWEST_LATENCY
    | SC_COLLABORATION_INTENT_BIT_TRANSPORT_AUTOMATIC
    | SC_COLLABORATION_INTENT_BIT_TOPOLOGY_DIRECT
    | SC_COLLABORATION_INTENT_BIT_TOPOLOGY_LOCAL_MULTI_PEER
    | SC_COLLABORATION_INTENT_BIT_TOPOLOGY_RELAYED;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCollaborationIntentProfileV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub capabilities: u64,
    pub reserved: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScCollaborationIntentDraftV1 {
    pub struct_size: u32,
    pub api_version: u32,
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
pub struct ScCollaborationIntentResolvedV1 {
    pub struct_size: u32,
    pub api_version: u32,
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
pub struct ScCollaborationIntentErrorV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub error_type: u8,
    pub side: u8,
    pub axis: u8,
    pub value: u8,
    pub reserved0: [u8; 4],
    pub reserved1: u64,
}
