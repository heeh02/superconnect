#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScReceiverProgressWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub session_generation: u32,
    pub awaiting_keyframe: u32,
    pub decoder_generation: u64,
    pub stage_counts: [u64; 4],
    pub latest_source_frame_ids: [u32; 4],
}
