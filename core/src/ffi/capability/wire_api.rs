use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::capability::{
    decode_capability_wire_v1, encode_capability_wire_v1, CapabilityWireKindV1,
    CapabilityWireMessageV1, CAPABILITY_WIRE_MAX_BYTES_V1,
};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};
use super::mapping::decode_event;
use super::schema::*;

unsafe fn encode_wire(
    input: *const ScCapabilityEventV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    let status = versioned_pointer_status(input);
    if status != SC_OK
        || needed.is_null()
        || !pointer_is_aligned(needed)
        || (output.is_null() && output_capacity != 0)
    {
        return SC_INVALID_ARGUMENT;
    }
    let Some(input_range) = checked_byte_range(input.cast(), size_of::<ScCapabilityEventV1>())
    else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(encoded) = decode_event(input.read())
        .and_then(|event| CapabilityWireMessageV1::try_from_event(event).ok())
        .and_then(|message| encode_capability_wire_v1(message).ok())
    else {
        return SC_INVALID_ARGUMENT;
    };
    let bytes = encoded.as_bytes();
    let Some(output_range) = checked_byte_range(output, output_capacity.min(bytes.len())) else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[input_range, output_range, needed_range]) {
        return SC_INVALID_ARGUMENT;
    }
    if output_capacity < bytes.len() {
        needed.write(bytes.len());
        return SC_BUFFER_TOO_SMALL;
    }
    needed.write(bytes.len());
    ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    SC_OK
}

fn ffi_event(struct_size: u32, value: CapabilityWireMessageV1) -> ScCapabilityEventV1 {
    let event_type = match value.kind {
        CapabilityWireKindV1::Offer => SC_CAPABILITY_EVENT_OFFER,
        CapabilityWireKindV1::Selection => SC_CAPABILITY_EVENT_SELECTION,
        CapabilityWireKindV1::Commit => SC_CAPABILITY_EVENT_COMMIT,
    };
    ScCapabilityEventV1 {
        struct_size,
        api_version: super::super::SC_API_VERSION_V1,
        generation: value.generation.get(),
        capabilities: value.capabilities.bits(),
        negotiation_version: value.negotiation_version,
        event_type,
        has_negotiation_version: 1,
        offerer_role: value.offerer_role as u8,
        selector_role: value.selector_role as u8,
        projection: value.projection as u8,
        transport: value.transport as u8,
        reserved: [0; 8],
    }
}

unsafe fn decode_wire(
    input: *const u8,
    input_length: usize,
    output: *mut ScCapabilityEventV1,
) -> ScStatus {
    if input_length > CAPABILITY_WIRE_MAX_BYTES_V1 {
        return SC_INVALID_ARGUMENT;
    }
    let status = versioned_pointer_status(output);
    if status != SC_OK {
        return status;
    }
    let Some(input_range) = checked_byte_range(input, input_length) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output.cast(), size_of::<ScCapabilityEventV1>())
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
    let Some(value) = decode_capability_wire_v1(bytes).ok() else {
        return SC_INVALID_ARGUMENT;
    };
    let struct_size = (*output).struct_size;
    output.write(ffi_event(struct_size, value));
    SC_OK
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_wire_encode_v1(
    event: *const ScCapabilityEventV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        encode_wire(event, output, output_capacity, needed)
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_wire_decode_v1(
    input: *const u8,
    input_length: usize,
    output: *mut ScCapabilityEventV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        decode_wire(input, input_length, output)
    })
}
