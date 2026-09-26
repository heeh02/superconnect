use std::mem::size_of;

pub const INPUT_RECORD_SIZE: usize = 44;
pub const INPUT_SEQUENCED_RECORD_SIZE: usize = INPUT_RECORD_SIZE + size_of::<u64>();

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScInputEvent {
    pub event_type: u8,
    pub tool: u8,
    pub buttons: u8,
    pub flags: u8,
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

pub fn input_is_replaceable(event: &ScInputEvent) -> bool {
    matches!(event.event_type, 1 | 3) && event.buttons == 0
}

pub fn input_encode(event: &ScInputEvent) -> [u8; INPUT_RECORD_SIZE] {
    let mut output = [0_u8; INPUT_RECORD_SIZE];
    output[0] = event.event_type;
    output[1] = event.tool;
    output[2] = event.buttons;
    output[3] = event.flags;
    output[4..12].copy_from_slice(&event.timestamp_ms.to_le_bytes());
    output[12..16].copy_from_slice(&event.x.to_bits().to_le_bytes());
    output[16..20].copy_from_slice(&event.y.to_bits().to_le_bytes());
    output[20..24].copy_from_slice(&event.pressure.to_bits().to_le_bytes());
    output[24..28].copy_from_slice(&event.tilt_x.to_bits().to_le_bytes());
    output[28..32].copy_from_slice(&event.tilt_y.to_bits().to_le_bytes());
    output[32..36].copy_from_slice(&event.scroll_x.to_bits().to_le_bytes());
    output[36..40].copy_from_slice(&event.scroll_y.to_bits().to_le_bytes());
    output[40..42].copy_from_slice(&event.key_code.to_le_bytes());
    output[42..44].copy_from_slice(&event.pointer_id.to_le_bytes());
    output
}

pub fn input_decode(bytes: &[u8]) -> Option<ScInputEvent> {
    if bytes.len() != INPUT_RECORD_SIZE || bytes[0] > 7 || bytes[1] > 3 {
        return None;
    }
    Some(ScInputEvent {
        event_type: bytes[0],
        tool: bytes[1],
        buttons: bytes[2],
        flags: bytes[3],
        timestamp_ms: u64::from_le_bytes(bytes[4..12].try_into().ok()?),
        x: f32::from_bits(u32::from_le_bytes(bytes[12..16].try_into().ok()?)),
        y: f32::from_bits(u32::from_le_bytes(bytes[16..20].try_into().ok()?)),
        pressure: f32::from_bits(u32::from_le_bytes(bytes[20..24].try_into().ok()?)),
        tilt_x: f32::from_bits(u32::from_le_bytes(bytes[24..28].try_into().ok()?)),
        tilt_y: f32::from_bits(u32::from_le_bytes(bytes[28..32].try_into().ok()?)),
        scroll_x: f32::from_bits(u32::from_le_bytes(bytes[32..36].try_into().ok()?)),
        scroll_y: f32::from_bits(u32::from_le_bytes(bytes[36..40].try_into().ok()?)),
        key_code: u16::from_le_bytes(bytes[40..42].try_into().ok()?),
        pointer_id: u16::from_le_bytes(bytes[42..44].try_into().ok()?),
    })
}

pub fn input_sequenced_encode(
    event: &ScInputEvent,
    sequence: u64,
) -> Option<[u8; INPUT_SEQUENCED_RECORD_SIZE]> {
    if sequence == 0 {
        return None;
    }
    let mut output = [0_u8; INPUT_SEQUENCED_RECORD_SIZE];
    output[..INPUT_RECORD_SIZE].copy_from_slice(&input_encode(event));
    output[INPUT_RECORD_SIZE..].copy_from_slice(&sequence.to_le_bytes());
    Some(output)
}

pub fn input_sequenced_decode(bytes: &[u8]) -> Option<(ScInputEvent, u64)> {
    if bytes.len() != INPUT_SEQUENCED_RECORD_SIZE {
        return None;
    }
    let event = input_decode(&bytes[..INPUT_RECORD_SIZE])?;
    let sequence = u64::from_le_bytes(bytes[INPUT_RECORD_SIZE..].try_into().ok()?);
    (sequence != 0).then_some((event, sequence))
}
