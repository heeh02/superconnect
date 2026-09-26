use std::{mem::size_of, ptr, slice};

use crate::session::{
    decode_session_hello_wire_v1, encode_session_hello_wire_v1, SessionHelloCapsV1,
    SessionHelloProjectionV1, SessionHelloRoleV1, SessionHelloWireKindV1, SessionHelloWireV1,
    SESSION_HELLO_WIRE_MAX_BYTES_V1,
};

use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

#[path = "hello_wire_record.rs"]
mod hello_wire_record;
use hello_wire_record::encode_record;

pub const SC_SESSION_HELLO_KIND_HELLO_V1: u32 = 1;
pub const SC_SESSION_HELLO_KIND_HELLO_ACK_V1: u32 = 2;
pub const SC_SESSION_HELLO_ROLE_SOURCE_V1: u32 = 1;
pub const SC_SESSION_HELLO_ROLE_RECEIVER_V1: u32 = 2;
pub const SC_SESSION_HELLO_PROJECTION_EXTEND_V1: u32 = 1;
pub const SC_SESSION_HELLO_PROJECTION_MIRROR_V1: u32 = 2;
pub const SC_SESSION_HELLO_PROJECTION_PRIMARY_V1: u32 = 3;
pub const SC_SESSION_HELLO_CODEC_H264_V1: u32 = 1 << 0;
pub const SC_SESSION_HELLO_CODEC_HEVC_V1: u32 = 1 << 1;

pub const SC_SESSION_HELLO_FIELD_CAPS_V1: u64 = 1 << 0;
pub const SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1: u64 = 1 << 1;
pub const SC_SESSION_HELLO_FIELD_CHALLENGE_V1: u64 = 1 << 2;
pub const SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1: u64 = 1 << 3;
const ALL_FIELDS: u64 = SC_SESSION_HELLO_FIELD_CAPS_V1
    | SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1
    | SC_SESSION_HELLO_FIELD_CHALLENGE_V1
    | SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1;

pub const SC_SESSION_HELLO_CAP_MAX_WIDTH_V1: u32 = 1 << 0;
pub const SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1: u32 = 1 << 1;
pub const SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1: u32 = 1 << 2;
pub const SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1: u32 = 1 << 3;
pub const SC_SESSION_HELLO_CAP_SCALE_V1: u32 = 1 << 4;
pub const SC_SESSION_HELLO_CAP_REFRESH_RATE_V1: u32 = 1 << 5;
pub const SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1: u32 = 1 << 6;
pub const SC_SESSION_HELLO_CAP_HIDPI_V1: u32 = 1 << 7;
pub const SC_SESSION_HELLO_CAP_PEN_V1: u32 = 1 << 8;
pub const SC_SESSION_HELLO_CAP_HDR_HLG_V1: u32 = 1 << 9;
pub const SC_SESSION_HELLO_CAP_HDR_PQ_V1: u32 = 1 << 10;
const ALL_CAPS: u32 = (1 << 11) - 1;

pub const SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1: u32 = 1 << 0;
pub const SC_SESSION_HELLO_CAP_VALUE_PEN_V1: u32 = 1 << 1;
pub const SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1: u32 = 1 << 2;
pub const SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1: u32 = 1 << 3;
const ALL_CAP_VALUES: u32 = (1 << 4) - 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScSessionHelloTextV1 {
    pub length: u32,
    pub bytes: [u8; 128],
}

impl Default for ScSessionHelloTextV1 {
    fn default() -> Self {
        Self {
            length: 0,
            bytes: [0; 128],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScSessionHelloWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u32,
    pub supported_roles: u32,
    pub presence: u64,
    pub protocol_version: u16,
    pub auth_version: u16,
    pub record_version: u16,
    pub capability_version: u16,
    pub capability_intent_version: u16,
    pub frame_meta_version: u16,
    pub media_recovery_version: u16,
    pub udp_video_version: u16,
    pub udp_video_port: u16,
    pub reserved0: u16,
    pub desired_role: u32,
    pub accepted_role: u32,
    pub projection: u32,
    pub codecs: u32,
    pub caps_presence: u32,
    pub caps_values: u32,
    pub max_width: u32,
    pub max_height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
    pub refresh_rate: u32,
    pub refresh_rate_max: u32,
    pub reserved_scale: u32,
    pub scale: f64,
    pub legacy_role: ScSessionHelloTextV1,
    pub peer_id: ScSessionHelloTextV1,
    pub platform: ScSessionHelloTextV1,
    pub device_name: ScSessionHelloTextV1,
    pub app_version: ScSessionHelloTextV1,
    pub pairing_token: ScSessionHelloTextV1,
    pub enrollment_key: [u8; 65],
    pub challenge: [u8; 32],
    pub needs_pairing: u8,
    pub reserved1: [u8; 6],
    pub reserved2: u64,
}

fn text(value: ScSessionHelloTextV1) -> Option<String> {
    let length = usize::try_from(value.length).ok()?.min(value.bytes.len());
    if length != usize::try_from(value.length).ok()? || value.bytes[length..] != [0; 128][length..]
    {
        return None;
    }
    std::str::from_utf8(&value.bytes[..length])
        .ok()
        .map(str::to_owned)
}

fn optional_text(value: ScSessionHelloTextV1) -> Option<Option<String>> {
    let value = text(value)?;
    Some((!value.is_empty()).then_some(value))
}

fn role(value: u32) -> Option<Option<SessionHelloRoleV1>> {
    match value {
        0 => Some(None),
        SC_SESSION_HELLO_ROLE_SOURCE_V1 => Some(Some(SessionHelloRoleV1::Source)),
        SC_SESSION_HELLO_ROLE_RECEIVER_V1 => Some(Some(SessionHelloRoleV1::Receiver)),
        _ => None,
    }
}

fn projection(value: u32) -> Option<Option<SessionHelloProjectionV1>> {
    match value {
        0 => Some(None),
        SC_SESSION_HELLO_PROJECTION_EXTEND_V1 => Some(Some(SessionHelloProjectionV1::Extend)),
        SC_SESSION_HELLO_PROJECTION_MIRROR_V1 => Some(Some(SessionHelloProjectionV1::Mirror)),
        SC_SESSION_HELLO_PROJECTION_PRIMARY_V1 => Some(Some(SessionHelloProjectionV1::Primary)),
        _ => None,
    }
}

fn optional_u16(value: u16) -> Option<u16> {
    (value != 0).then_some(value)
}
fn optional_u32(presence: u32, bit: u32, value: u32) -> Option<Option<u32>> {
    if presence & bit != 0 {
        Some(Some(value))
    } else if value == 0 {
        Some(None)
    } else {
        None
    }
}
fn optional_bool(presence: u32, bit: u32, values: u32, value: u32) -> Option<Option<bool>> {
    if presence & bit != 0 {
        Some(Some(values & value != 0))
    } else if values & value == 0 {
        Some(None)
    } else {
        None
    }
}

fn decode_record(value: ScSessionHelloWireV1) -> Option<SessionHelloWireV1> {
    if value.presence & !ALL_FIELDS != 0
        || value.caps_presence & !ALL_CAPS != 0
        || value.caps_values & !ALL_CAP_VALUES != 0
        || value.reserved0 != 0
        || value.reserved_scale != 0
        || value.reserved1 != [0; 6]
        || value.reserved2 != 0
        || value.needs_pairing > 1
    {
        return None;
    }
    let kind = match value.kind {
        SC_SESSION_HELLO_KIND_HELLO_V1 => SessionHelloWireKindV1::Hello,
        SC_SESSION_HELLO_KIND_HELLO_ACK_V1 => SessionHelloWireKindV1::HelloAck,
        _ => return None,
    };
    let caps = if value.presence & SC_SESSION_HELLO_FIELD_CAPS_V1 != 0 {
        Some(SessionHelloCapsV1 {
            codecs: value.codecs,
            max_width: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_MAX_WIDTH_V1,
                value.max_width,
            )?,
            max_height: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1,
                value.max_height,
            )?,
            screen_width: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1,
                value.screen_width,
            )?,
            screen_height: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1,
                value.screen_height,
            )?,
            scale: if value.caps_presence & SC_SESSION_HELLO_CAP_SCALE_V1 != 0 {
                Some(value.scale)
            } else if value.scale == 0.0 {
                None
            } else {
                return None;
            },
            refresh_rate: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_REFRESH_RATE_V1,
                value.refresh_rate,
            )?,
            refresh_rate_max: optional_u32(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1,
                value.refresh_rate_max,
            )?,
            hidpi: optional_bool(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_HIDPI_V1,
                value.caps_values,
                SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1,
            )?,
            pen: optional_bool(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_PEN_V1,
                value.caps_values,
                SC_SESSION_HELLO_CAP_VALUE_PEN_V1,
            )?,
            hdr_hlg: optional_bool(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_HDR_HLG_V1,
                value.caps_values,
                SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1,
            )?,
            hdr_pq: optional_bool(
                value.caps_presence,
                SC_SESSION_HELLO_CAP_HDR_PQ_V1,
                value.caps_values,
                SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1,
            )?,
        })
    } else if value.codecs == 0
        && value.caps_presence == 0
        && value.caps_values == 0
        && value.max_width == 0
        && value.max_height == 0
        && value.screen_width == 0
        && value.screen_height == 0
        && value.refresh_rate == 0
        && value.refresh_rate_max == 0
        && value.scale == 0.0
    {
        None
    } else {
        return None;
    };
    let enrollment_key = if value.presence & SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1 != 0 {
        Some(value.enrollment_key)
    } else if value.enrollment_key == [0; 65] {
        None
    } else {
        return None;
    };
    let challenge = if value.presence & SC_SESSION_HELLO_FIELD_CHALLENGE_V1 != 0 {
        Some(value.challenge)
    } else if value.challenge == [0; 32] {
        None
    } else {
        return None;
    };
    let needs_pairing = if value.presence & SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1 != 0 {
        Some(value.needs_pairing == 1)
    } else if value.needs_pairing == 0 {
        None
    } else {
        return None;
    };
    SessionHelloWireV1 {
        kind,
        legacy_role: text(value.legacy_role)?,
        protocol_version: value.protocol_version,
        auth_version: optional_u16(value.auth_version),
        record_version: optional_u16(value.record_version),
        capability_version: optional_u16(value.capability_version),
        capability_intent_version: optional_u16(value.capability_intent_version),
        frame_meta_version: optional_u16(value.frame_meta_version),
        media_recovery_version: optional_u16(value.media_recovery_version),
        udp_video_version: optional_u16(value.udp_video_version),
        udp_video_port: optional_u16(value.udp_video_port),
        peer_id: text(value.peer_id)?,
        platform: optional_text(value.platform)?,
        device_name: optional_text(value.device_name)?,
        app_version: optional_text(value.app_version)?,
        pairing_token: optional_text(value.pairing_token)?,
        supported_roles: value.supported_roles,
        desired_role: role(value.desired_role)?,
        accepted_role: role(value.accepted_role)?,
        projection: projection(value.projection)?,
        caps,
        enrollment_key,
        challenge,
        needs_pairing,
    }
    .validate()
    .ok()
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_hello_wire_encode_v1(
    value: *const ScSessionHelloWireV1,
    output: *mut u8,
    capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if versioned_pointer_status(value) != SC_OK
            || needed.is_null()
            || !pointer_is_aligned(needed)
            || (output.is_null() && capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(value_range) = checked_byte_range(value.cast(), size_of::<ScSessionHelloWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(value) = decode_record(value.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_session_hello_wire_v1(value) else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = encoded.as_bytes();
        let Some(output_range) = checked_byte_range(output, capacity.min(bytes.len())) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[value_range, needed_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(bytes.len());
        if capacity < bytes.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_hello_wire_decode_v1(
    input: *const u8,
    length: usize,
    output: *mut ScSessionHelloWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if length > SESSION_HELLO_WIRE_MAX_BYTES_V1 || versioned_pointer_status(output) != SC_OK {
            return SC_INVALID_ARGUMENT;
        }
        let Some(input_range) = checked_byte_range(input, length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScSessionHelloWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, length)
        };
        let Ok(value) = decode_session_hello_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(encode_record(value, struct_size));
        SC_OK
    })
}
