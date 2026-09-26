use std::{mem::size_of, ptr, slice};

use crate::session::{
    decode_session_control_wire_v1, encode_session_control_wire_v1, SessionControlWireKindV1,
    SessionControlWireV1, SESSION_CONTROL_WIRE_MAX_BYTES_V1,
};

use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_SESSION_CONTROL_KIND_BYE_V1: u32 = 1;
pub const SC_SESSION_CONTROL_KIND_PING_V1: u32 = 2;
pub const SC_SESSION_CONTROL_KIND_PONG_V1: u32 = 3;
pub const SC_SESSION_CONTROL_FIELD_T0_V1: u32 = 1 << 0;
pub const SC_SESSION_CONTROL_FIELD_T1_V1: u32 = 1 << 1;
pub const SC_SESSION_CONTROL_FIELD_T2_V1: u32 = 1 << 2;
const ALL_FIELDS: u32 = SC_SESSION_CONTROL_FIELD_T0_V1
    | SC_SESSION_CONTROL_FIELD_T1_V1
    | SC_SESSION_CONTROL_FIELD_T2_V1;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScSessionControlWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u32,
    pub presence: u32,
    pub sequence: u64,
    pub t0: u64,
    pub t1: u64,
    pub t2: u64,
    pub reserved: u64,
}

fn decode_record(value: ScSessionControlWireV1) -> Option<SessionControlWireV1> {
    if value.reserved != 0 || value.presence & !ALL_FIELDS != 0 {
        return None;
    }
    let optional = |bit, number| -> Option<Option<u64>> {
        if value.presence & bit != 0 {
            Some(Some(number))
        } else if number == 0 {
            Some(None)
        } else {
            None
        }
    };
    let kind = match value.kind {
        SC_SESSION_CONTROL_KIND_BYE_V1 => SessionControlWireKindV1::Bye,
        SC_SESSION_CONTROL_KIND_PING_V1 => SessionControlWireKindV1::Ping,
        SC_SESSION_CONTROL_KIND_PONG_V1 => SessionControlWireKindV1::Pong,
        _ => return None,
    };
    SessionControlWireV1 {
        kind,
        sequence: value.sequence,
        t0: optional(SC_SESSION_CONTROL_FIELD_T0_V1, value.t0)?,
        t1: optional(SC_SESSION_CONTROL_FIELD_T1_V1, value.t1)?,
        t2: optional(SC_SESSION_CONTROL_FIELD_T2_V1, value.t2)?,
    }
    .validate()
    .ok()
}

fn encode_record(value: SessionControlWireV1, struct_size: u32) -> ScSessionControlWireV1 {
    let (kind, mut presence) = match value.kind {
        SessionControlWireKindV1::Bye => (SC_SESSION_CONTROL_KIND_BYE_V1, 0),
        SessionControlWireKindV1::Ping => (SC_SESSION_CONTROL_KIND_PING_V1, 0),
        SessionControlWireKindV1::Pong => (SC_SESSION_CONTROL_KIND_PONG_V1, 0),
    };
    if value.t0.is_some() {
        presence |= SC_SESSION_CONTROL_FIELD_T0_V1;
    }
    if value.t1.is_some() {
        presence |= SC_SESSION_CONTROL_FIELD_T1_V1;
    }
    if value.t2.is_some() {
        presence |= SC_SESSION_CONTROL_FIELD_T2_V1;
    }
    ScSessionControlWireV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        kind,
        presence,
        sequence: value.sequence,
        t0: value.t0.unwrap_or(0),
        t1: value.t1.unwrap_or(0),
        t2: value.t2.unwrap_or(0),
        reserved: 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_control_wire_encode_v1(
    value: *const ScSessionControlWireV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(value);
        if status != SC_OK {
            return status;
        }
        if needed.is_null()
            || !pointer_is_aligned(needed)
            || (output.is_null() && output_capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(value_range) =
            checked_byte_range(value.cast(), size_of::<ScSessionControlWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(value) = decode_record(value.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_session_control_wire_v1(value) else {
            return SC_INVALID_ARGUMENT;
        };
        let bytes = encoded.as_bytes();
        let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len()))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[value_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(bytes.len());
        if output_capacity < bytes.len() {
            return SC_BUFFER_TOO_SMALL;
        }
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_control_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScSessionControlWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > SESSION_CONTROL_WIRE_MAX_BYTES_V1 {
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
            checked_byte_range(output.cast(), size_of::<ScSessionControlWireV1>())
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
        let Ok(value) = decode_session_control_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(encode_record(value, struct_size));
        SC_OK
    })
}
