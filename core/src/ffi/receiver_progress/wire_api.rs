use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::receiver_progress::{
    decode_receiver_progress_wire_v1, encode_receiver_progress_wire_v1, ReceiverProgressWireV1,
    RECEIVER_PROGRESS_WIRE_MAX_BYTES_V1,
};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};
use super::schema::ScReceiverProgressWireV1;

fn from_ffi(value: ScReceiverProgressWireV1) -> Option<ReceiverProgressWireV1> {
    if value.awaiting_keyframe > 1 {
        return None;
    }
    ReceiverProgressWireV1 {
        session_generation: value.session_generation,
        decoder_generation: value.decoder_generation,
        stage_counts: value.stage_counts,
        latest_source_frame_ids: value.latest_source_frame_ids,
        awaiting_keyframe: value.awaiting_keyframe != 0,
    }
    .validate()
    .ok()
}

fn to_ffi(struct_size: u32, value: ReceiverProgressWireV1) -> ScReceiverProgressWireV1 {
    ScReceiverProgressWireV1 {
        struct_size,
        api_version: 1,
        session_generation: value.session_generation,
        awaiting_keyframe: u32::from(value.awaiting_keyframe),
        decoder_generation: value.decoder_generation,
        stage_counts: value.stage_counts,
        latest_source_frame_ids: value.latest_source_frame_ids,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_receiver_progress_wire_encode_v1(
    value: *const ScReceiverProgressWireV1,
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
            checked_byte_range(value.cast(), size_of::<ScReceiverProgressWireV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(encoded) =
            from_ffi(value.read()).and_then(|wire| encode_receiver_progress_wire_v1(wire).ok())
        else {
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
pub unsafe extern "C" fn sc_receiver_progress_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScReceiverProgressWireV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > RECEIVER_PROGRESS_WIRE_MAX_BYTES_V1 {
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
            checked_byte_range(output.cast(), size_of::<ScReceiverProgressWireV1>())
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
        let Ok(value) = decode_receiver_progress_wire_v1(bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(to_ffi(struct_size, value));
        SC_OK
    })
}
