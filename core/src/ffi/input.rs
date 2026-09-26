use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::wire::input::{
    input_decode, input_encode, input_is_replaceable, input_sequenced_decode,
    input_sequenced_encode, ScInputEvent, INPUT_RECORD_SIZE, INPUT_SEQUENCED_RECORD_SIZE,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScInputEventV1, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL,
    SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};

fn wire_event(event: ScInputEventV1) -> Option<ScInputEvent> {
    if event.event_type > 7 || event.tool > 3 {
        return None;
    }
    Some(ScInputEvent {
        event_type: event.event_type,
        tool: event.tool,
        buttons: event.buttons,
        flags: event.flags,
        timestamp_ms: event.timestamp_ms,
        x: event.x,
        y: event.y,
        pressure: event.pressure,
        tilt_x: event.tilt_x,
        tilt_y: event.tilt_y,
        scroll_x: event.scroll_x,
        scroll_y: event.scroll_y,
        key_code: event.key_code,
        pointer_id: event.pointer_id,
    })
}

fn ffi_event(struct_size: u32, event: ScInputEvent) -> ScInputEventV1 {
    ScInputEventV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        event_type: event.event_type,
        tool: event.tool,
        buttons: event.buttons,
        flags: event.flags,
        reserved: 0,
        timestamp_ms: event.timestamp_ms,
        x: event.x,
        y: event.y,
        pressure: event.pressure,
        tilt_x: event.tilt_x,
        tilt_y: event.tilt_y,
        scroll_x: event.scroll_x,
        scroll_y: event.scroll_y,
        key_code: event.key_code,
        pointer_id: event.pointer_id,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_encode_v1(
    event: *const ScInputEventV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        if needed.is_null() || !pointer_is_aligned(needed) {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() && output_capacity != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event_range) = checked_byte_range(event.cast::<u8>(), size_of::<ScInputEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output, output_capacity.min(INPUT_RECORD_SIZE))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[event_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event) = wire_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity < INPUT_RECORD_SIZE {
            needed.write(INPUT_RECORD_SIZE);
            return SC_BUFFER_TOO_SMALL;
        }
        let encoded = input_encode(&event);
        needed.write(INPUT_RECORD_SIZE);
        ptr::copy_nonoverlapping(encoded.as_ptr(), output, INPUT_RECORD_SIZE);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_decode_v1(
    bytes: *const u8,
    length: usize,
    output: *mut ScInputEventV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if length != INPUT_RECORD_SIZE {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(bytes_range) = checked_byte_range(bytes, length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<ScInputEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[bytes_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let struct_size = output.cast::<u32>().read_unaligned();
        let Some(event) = input_decode(slice::from_raw_parts(bytes, length)) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(ffi_event(struct_size, event));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_is_replaceable_v1(
    event: *const ScInputEventV1,
    replaceable: *mut u8,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        if replaceable.is_null() {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event_range) = checked_byte_range(event.cast::<u8>(), size_of::<ScInputEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(replaceable, size_of::<u8>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[event_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event) = wire_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        replaceable.write(input_is_replaceable(&event) as u8);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_sequenced_encode_v1(
    event: *const ScInputEventV1,
    sequence: u64,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        if sequence == 0 || needed.is_null() || !pointer_is_aligned(needed) {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() && output_capacity != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event_range) = checked_byte_range(event.cast::<u8>(), size_of::<ScInputEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output, output_capacity.min(INPUT_SEQUENCED_RECORD_SIZE))
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[event_range, output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(event) = wire_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity < INPUT_SEQUENCED_RECORD_SIZE {
            needed.write(INPUT_SEQUENCED_RECORD_SIZE);
            return SC_BUFFER_TOO_SMALL;
        }
        let Some(encoded) = input_sequenced_encode(&event, sequence) else {
            return SC_INVALID_ARGUMENT;
        };
        needed.write(INPUT_SEQUENCED_RECORD_SIZE);
        ptr::copy_nonoverlapping(encoded.as_ptr(), output, INPUT_SEQUENCED_RECORD_SIZE);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_input_sequenced_decode_v1(
    bytes: *const u8,
    length: usize,
    output: *mut ScInputEventV1,
    sequence: *mut u64,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if length != INPUT_SEQUENCED_RECORD_SIZE {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        if sequence.is_null() || !pointer_is_aligned(sequence) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(bytes_range) = checked_byte_range(bytes, length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<ScInputEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(sequence_range) = checked_byte_range(sequence.cast::<u8>(), size_of::<u64>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[bytes_range, output_range, sequence_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let struct_size = output.cast::<u32>().read_unaligned();
        let Some((event, decoded_sequence)) =
            input_sequenced_decode(slice::from_raw_parts(bytes, length))
        else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(ffi_event(struct_size, event));
        sequence.write(decoded_sequence);
        SC_OK
    })
}
