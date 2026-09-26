use crate::wire::frame::FrameDecoder;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ScFrameDecoderConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub max_buffered_bytes: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ScFrameV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub channel: u8,
    pub flags: u8,
    pub reserved: u16,
    pub payload: *const u8,
    pub payload_length: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ScFrameViewV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub channel: u8,
    pub flags: u8,
    pub reserved: u16,
    pub payload: *const u8,
    pub payload_length: usize,
    pub generation: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ScInputEventV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub event_type: u8,
    pub tool: u8,
    pub buttons: u8,
    pub flags: u8,
    pub reserved: u32,
    pub timestamp_ms: u64,
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
    pub tilt_x: f32,
    pub tilt_y: f32,
    pub scroll_x: f32,
    pub scroll_y: f32,
    pub key_code: u16,
    pub pointer_id: u16,
}

#[repr(C)]
pub struct ScFrameDecoderV1 {
    pub(super) inner: FrameDecoder,
}
