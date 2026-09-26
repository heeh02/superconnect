pub const SC_MEDIA_RECOVERY_WIRE_ANCHOR: u32 = 1;
pub const SC_MEDIA_RECOVERY_WIRE_ACCEPTED: u32 = 2;
pub const SC_MEDIA_RECOVERY_WIRE_OUTPUT: u32 = 3;

pub const SC_VIDEO_CODEC_H264_V1: u32 = 1;
pub const SC_VIDEO_HDR_OFF_V1: u32 = 1;

pub const SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED: u32 = 0;
pub const SC_KEYFRAME_REQUEST_REASON_UDP_GAP: u32 = 1;
pub const SC_KEYFRAME_REQUEST_REASON_UDP_REASSEMBLY_OVERFLOW: u32 = 2;
pub const SC_KEYFRAME_REQUEST_REASON_UDP_AUTH: u32 = 3;
pub const SC_KEYFRAME_REQUEST_REASON_DECODER_BACKLOG: u32 = 4;
pub const SC_KEYFRAME_REQUEST_REASON_DECODER_INPUT_FAILURE: u32 = 5;
pub const SC_KEYFRAME_REQUEST_REASON_DECODER_NOT_READY: u32 = 6;
pub const SC_KEYFRAME_REQUEST_REASON_DECODER_ERROR: u32 = 7;
pub const SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM: u32 = 8;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScMediaRecoveryWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub message_type: u32,
    pub reserved: u32,
    pub generation: u64,
    pub recovery_id: u64,
    pub source_frame_id: u64,
    pub reserved_u64: [u64; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScKeyframeRequestWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub reason: u32,
    pub reserved: u32,
    pub reserved_u64: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScVideoConfigWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub codec: u32,
    pub hdr: u32,
    pub width: u32,
    pub height: u32,
    pub refresh_rate: u32,
    pub low_latency: u8,
    pub reserved_u8: [u8; 3],
    pub reserved_u64: [u64; 2],
}
