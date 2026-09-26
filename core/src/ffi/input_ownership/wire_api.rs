use std::{mem::size_of, ptr, slice};

use crate::input_ownership::{
    decode_input_reset_wire_v1, encode_input_reset_wire_v1, INPUT_RESET_REASON_MAX_BYTES_V1,
    INPUT_RESET_WIRE_MAX_BYTES_V1,
};

use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_INPUT_RESET_REASON_MAX_BYTES_V1: u32 = INPUT_RESET_REASON_MAX_BYTES_V1 as u32;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScInputResetWireV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub reason_size: u32,
    pub reserved: u32,
    pub reason: [u8; INPUT_RESET_REASON_MAX_BYTES_V1],
    pub reserved_u64: u64,
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_reset_wire_encode_v1(
    value: *const ScInputResetWireV1,
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
        let Some(value_range) = checked_byte_range(value.cast(), size_of::<ScInputResetWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let value = value.read();
        let reason_size = value.reason_size as usize;
        if reason_size > value.reason.len()
            || value.reserved != 0
            || value.reserved_u64 != 0
            || value.reason[reason_size..].iter().any(|byte| *byte != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Ok(reason) = std::str::from_utf8(&value.reason[..reason_size]) else {
            return SC_INVALID_ARGUMENT;
        };
        let Ok(encoded) = encode_input_reset_wire_v1(reason) else {
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
pub unsafe extern "C" fn sc_input_reset_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScInputResetWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > INPUT_RESET_WIRE_MAX_BYTES_V1 {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output.cast(), size_of::<ScInputResetWireV1>())
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
        let Ok(reason) = decode_input_reset_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let mut result = ScInputResetWireV1 {
            struct_size: output.cast::<u32>().read_unaligned(),
            api_version: SC_API_VERSION_V1,
            reason_size: reason.len() as u32,
            reserved: 0,
            reason: [0; INPUT_RESET_REASON_MAX_BYTES_V1],
            reserved_u64: 0,
        };
        result.reason[..reason.len()].copy_from_slice(reason.as_bytes());
        output.write(result);
        SC_OK
    })
}
