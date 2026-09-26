use std::{mem::size_of, ptr, slice};

use crate::control_envelope::{
    decode_control_caps_update_v1, decode_control_envelope_v1, decode_control_text_wire_v1,
    encode_control_aux_anchor_accepted_wire_v1, encode_control_caps_update_v1,
    encode_control_error_wire_v1, encode_control_session_fatal_error_wire_v1,
    encode_control_text_wire_v1, encode_control_udp_aux_wire_v1,
    encode_control_video_epoch_wire_v1, ControlCapsUpdateV1, ControlEnvelopeErrorV1,
    ControlEnvelopeV1, CONTROL_ENVELOPE_MAX_BYTES_V1,
};
use crate::control_envelope_types_generated::{
    SC_CONTROL_CAPS_FIELD_HDR_HLG_V1 as CONTROL_CAPS_FIELD_HDR_HLG_V1,
    SC_CONTROL_CAPS_FIELD_HDR_PQ_V1 as CONTROL_CAPS_FIELD_HDR_PQ_V1,
    SC_CONTROL_CAPS_FIELD_PEN_V1 as CONTROL_CAPS_FIELD_PEN_V1,
    SC_CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1 as CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1,
    SC_CONTROL_CAPS_FIELD_REFRESH_RATE_V1 as CONTROL_CAPS_FIELD_REFRESH_RATE_V1,
    SC_CONTROL_CAPS_FIELD_SCALE_V1 as CONTROL_CAPS_FIELD_SCALE_V1,
    SC_CONTROL_CAPS_VALUE_HDR_HLG_V1 as CONTROL_CAPS_VALUE_HDR_HLG_V1,
    SC_CONTROL_CAPS_VALUE_HDR_PQ_V1 as CONTROL_CAPS_VALUE_HDR_PQ_V1,
    SC_CONTROL_CAPS_VALUE_PEN_V1 as CONTROL_CAPS_VALUE_PEN_V1,
};

use crate::ffi::session_fatal_reason_from_value;
use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK, SC_UNSUPPORTED_VERSION,
};

mod claim;
pub use claim::sc_control_envelope_claim_kind_v1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScControlEnvelopeV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u32,
    pub presence: u32,
    pub generation: u64,
    pub operation: u64,
    pub value0: u64,
    pub value1: u64,
    pub detail: u32,
    pub reserved0: u32,
    pub reserved1: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScControlCapsUpdateV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub presence: u32,
    pub codecs: u32,
    pub values: u32,
    pub screen_width: u32,
    pub screen_height: u32,
    pub refresh_rate: u32,
    pub refresh_rate_max: u32,
    pub reserved0: u32,
    pub scale: f64,
    pub reserved1: u64,
    pub reserved2: u64,
}

const ALL_CAPS_FIELDS: u32 = CONTROL_CAPS_FIELD_SCALE_V1
    | CONTROL_CAPS_FIELD_REFRESH_RATE_V1
    | CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1
    | CONTROL_CAPS_FIELD_PEN_V1
    | CONTROL_CAPS_FIELD_HDR_HLG_V1
    | CONTROL_CAPS_FIELD_HDR_PQ_V1;
const ALL_CAPS_VALUES: u32 =
    CONTROL_CAPS_VALUE_PEN_V1 | CONTROL_CAPS_VALUE_HDR_HLG_V1 | CONTROL_CAPS_VALUE_HDR_PQ_V1;

fn decode_caps_record(value: ScControlCapsUpdateV1) -> Option<ControlCapsUpdateV1> {
    if value.presence & !ALL_CAPS_FIELDS != 0
        || value.values & !ALL_CAPS_VALUES != 0
        || value.reserved0 != 0
        || value.reserved1 != 0
        || value.reserved2 != 0
        || (value.presence & CONTROL_CAPS_FIELD_SCALE_V1 == 0 && value.scale != 0.0)
        || (value.presence & CONTROL_CAPS_FIELD_REFRESH_RATE_V1 == 0 && value.refresh_rate != 0)
        || (value.presence & CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1 == 0
            && value.refresh_rate_max != 0)
        || (value.presence & CONTROL_CAPS_FIELD_PEN_V1 == 0
            && value.values & CONTROL_CAPS_VALUE_PEN_V1 != 0)
        || (value.presence & CONTROL_CAPS_FIELD_HDR_HLG_V1 == 0
            && value.values & CONTROL_CAPS_VALUE_HDR_HLG_V1 != 0)
        || (value.presence & CONTROL_CAPS_FIELD_HDR_PQ_V1 == 0
            && value.values & CONTROL_CAPS_VALUE_HDR_PQ_V1 != 0)
    {
        return None;
    }
    ControlCapsUpdateV1 {
        codecs: value.codecs,
        screen_width: value.screen_width,
        screen_height: value.screen_height,
        scale: (value.presence & CONTROL_CAPS_FIELD_SCALE_V1 != 0).then_some(value.scale),
        refresh_rate: (value.presence & CONTROL_CAPS_FIELD_REFRESH_RATE_V1 != 0)
            .then_some(value.refresh_rate),
        refresh_rate_max: (value.presence & CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1 != 0)
            .then_some(value.refresh_rate_max),
        pen: (value.presence & CONTROL_CAPS_FIELD_PEN_V1 != 0)
            .then_some(value.values & CONTROL_CAPS_VALUE_PEN_V1 != 0),
        hdr_hlg: (value.presence & CONTROL_CAPS_FIELD_HDR_HLG_V1 != 0)
            .then_some(value.values & CONTROL_CAPS_VALUE_HDR_HLG_V1 != 0),
        hdr_pq: (value.presence & CONTROL_CAPS_FIELD_HDR_PQ_V1 != 0)
            .then_some(value.values & CONTROL_CAPS_VALUE_HDR_PQ_V1 != 0),
    }
    .validate()
    .ok()
}

fn encode_caps_record(value: ControlCapsUpdateV1, struct_size: u32) -> ScControlCapsUpdateV1 {
    let mut presence = 0;
    let mut values = 0;
    if value.scale.is_some() {
        presence |= CONTROL_CAPS_FIELD_SCALE_V1;
    }
    if value.refresh_rate.is_some() {
        presence |= CONTROL_CAPS_FIELD_REFRESH_RATE_V1;
    }
    if value.refresh_rate_max.is_some() {
        presence |= CONTROL_CAPS_FIELD_REFRESH_RATE_MAX_V1;
    }
    for (item, field, bit) in [
        (
            value.pen,
            CONTROL_CAPS_FIELD_PEN_V1,
            CONTROL_CAPS_VALUE_PEN_V1,
        ),
        (
            value.hdr_hlg,
            CONTROL_CAPS_FIELD_HDR_HLG_V1,
            CONTROL_CAPS_VALUE_HDR_HLG_V1,
        ),
        (
            value.hdr_pq,
            CONTROL_CAPS_FIELD_HDR_PQ_V1,
            CONTROL_CAPS_VALUE_HDR_PQ_V1,
        ),
    ] {
        if let Some(item) = item {
            presence |= field;
            if item {
                values |= bit;
            }
        }
    }
    ScControlCapsUpdateV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        presence,
        codecs: value.codecs,
        values,
        screen_width: value.screen_width,
        screen_height: value.screen_height,
        refresh_rate: value.refresh_rate.unwrap_or(0),
        refresh_rate_max: value.refresh_rate_max.unwrap_or(0),
        reserved0: 0,
        scale: value.scale.unwrap_or(0.0),
        reserved1: 0,
        reserved2: 0,
    }
}

unsafe fn write_bytes(
    bytes: &[u8],
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
    protected: &[(usize, usize)],
) -> ScStatus {
    if needed.is_null() || !pointer_is_aligned(needed) || (output.is_null() && output_capacity != 0)
    {
        return SC_INVALID_ARGUMENT;
    }
    let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len())) else {
        return SC_INVALID_ARGUMENT;
    };
    let mut ranges = Vec::with_capacity(protected.len() + 2);
    ranges.extend_from_slice(protected);
    ranges.push(output_range);
    ranges.push(needed_range);
    if !byte_ranges_are_disjoint(&ranges) {
        return SC_INVALID_ARGUMENT;
    }
    needed.write(bytes.len());
    if output_capacity < bytes.len() {
        return SC_BUFFER_TOO_SMALL;
    }
    ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    SC_OK
}

pub(crate) fn encode_control_envelope_record(
    value: ControlEnvelopeV1,
    struct_size: u32,
) -> ScControlEnvelopeV1 {
    ScControlEnvelopeV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        kind: value.kind,
        presence: value.presence,
        generation: value.generation,
        operation: value.operation,
        value0: value.value0,
        value1: value.value1,
        detail: value.detail,
        reserved0: 0,
        reserved1: 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_envelope_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScControlEnvelopeV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > CONTROL_ENVELOPE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScControlEnvelopeV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let value = match decode_control_envelope_v1(bytes) {
            Ok(value) => value,
            Err(ControlEnvelopeErrorV1::Unknown | ControlEnvelopeErrorV1::Legacy) => {
                return SC_UNSUPPORTED_VERSION
            }
            Err(ControlEnvelopeErrorV1::TooLarge | ControlEnvelopeErrorV1::Malformed) => {
                return SC_INVALID_ARGUMENT
            }
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(encode_control_envelope_record(value, struct_size));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_caps_update_wire_encode_v1(
    value: *const ScControlCapsUpdateV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(value);
        if status != SC_OK {
            return status;
        }
        let Some(value_range) =
            checked_byte_range(value.cast(), size_of::<ScControlCapsUpdateV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(value) = decode_caps_record(value.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_control_caps_update_v1(value) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(
            encoded.as_bytes(),
            output,
            output_capacity,
            needed,
            &[value_range],
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_caps_update_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScControlCapsUpdateV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > CONTROL_ENVELOPE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScControlCapsUpdateV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[input_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let Ok(value) = decode_control_caps_update_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(encode_caps_record(value, struct_size));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_text_wire_encode_v1(
    text: *const u8,
    text_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if text_length == 0 || text_length > 4096 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(text_range) = checked_byte_range(text, text_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = slice::from_raw_parts(text, text_length);
        let Ok(text) = std::str::from_utf8(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_control_text_wire_v1(text) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(
            encoded.as_bytes(),
            output,
            output_capacity,
            needed,
            &[text_range],
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_text_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > CONTROL_ENVELOPE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = if input_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(input, input_length)
        };
        let Ok(text) = decode_control_text_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(
            text.as_bytes(),
            output,
            output_capacity,
            needed,
            &[input_range],
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_error_wire_encode_v1(
    reason: u32,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Ok(encoded) = encode_control_error_wire_v1(reason) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(encoded.as_bytes(), output, output_capacity, needed, &[])
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_session_fatal_error_wire_encode_v1(
    session_fatal_reason: u32,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Some(reason) = session_fatal_reason_from_value(session_fatal_reason) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_control_session_fatal_error_wire_v1(reason) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(encoded.as_bytes(), output, output_capacity, needed, &[])
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_udp_aux_wire_encode_v1(
    kind: u32,
    operation: u64,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Ok(encoded) = encode_control_udp_aux_wire_v1(kind, operation) else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(encoded.as_bytes(), output, output_capacity, needed, &[])
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_aux_anchor_accepted_wire_encode_v1(
    generation: u64,
    source_frame_id: u32,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Ok(encoded) = encode_control_aux_anchor_accepted_wire_v1(generation, source_frame_id)
        else {
            return SC_INVALID_ARGUMENT;
        };
        write_bytes(encoded.as_bytes(), output, output_capacity, needed, &[])
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_control_video_epoch_wire_encode_v1(
    epoch: u32,
    first_frame_sequence: u32,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let encoded = encode_control_video_epoch_wire_v1(epoch, first_frame_sequence);
        write_bytes(encoded.as_bytes(), output, output_capacity, needed, &[])
    })
}
