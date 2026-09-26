use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::capability::{
    decode_capability_intent_profile_wire_v2, decode_capability_intent_wire_v2,
    encode_capability_intent_profile_wire_v2, encode_capability_intent_wire_v2,
    CapabilityIntentProfileWireMessageV2, CapabilityIntentWireKindV2,
    CapabilityIntentWireMessageV2, CAPABILITY_INTENT_PROFILE_WIRE_MAX_BYTES_V2,
    CAPABILITY_INTENT_WIRE_MAX_BYTES_V2,
};
use crate::collaboration_intent::{IntentCapabilitySet, LocalRole, ProductCapabilityProfile};
use crate::session_generation::SessionGeneration;

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned, ScStatus,
    SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};
use super::api::pointer_status_v2;
use super::mapping::decode_event;
use super::schema::*;

unsafe fn encode_wire<T: Copy>(
    input: *const T,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
    encode: impl FnOnce(T) -> Option<String>,
) -> ScStatus {
    let status = pointer_status_v2(input);
    if status != SC_OK {
        return status;
    }
    if needed.is_null() || !pointer_is_aligned(needed) {
        return SC_INVALID_ARGUMENT;
    }
    if output.is_null() && output_capacity != 0 {
        return SC_INVALID_ARGUMENT;
    }
    let Some(input_range) = checked_byte_range(input.cast(), size_of::<T>()) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(encoded) = encode(input.read()) else {
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

unsafe fn decode_wire<T: Copy>(
    input: *const u8,
    input_length: usize,
    max_length: usize,
    output: *mut T,
    decode: impl FnOnce(&[u8], u32) -> Option<T>,
) -> ScStatus {
    if input_length > max_length {
        return SC_INVALID_ARGUMENT;
    }
    let status = pointer_status_v2(output);
    if status != SC_OK {
        return status;
    }
    let Some(input_range) = checked_byte_range(input, input_length) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output.cast(), size_of::<T>()) else {
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
    let struct_size = output.cast::<u32>().read_unaligned();
    let Some(value) = decode(bytes, struct_size) else {
        return SC_INVALID_ARGUMENT;
    };
    output.write(value);
    SC_OK
}

fn encode_intent_event(value: ScCapabilityIntentEventV2) -> Option<String> {
    let event = decode_event(value)?;
    let message = CapabilityIntentWireMessageV2::try_from_event(event).ok()?;
    encode_capability_intent_wire_v2(message).ok()
}

fn ffi_intent_event(
    struct_size: u32,
    value: CapabilityIntentWireMessageV2,
) -> ScCapabilityIntentEventV2 {
    let event_type = match value.kind {
        CapabilityIntentWireKindV2::Offer => SC_CAPABILITY_INTENT_EVENT_OFFER,
        CapabilityIntentWireKindV2::Selection => SC_CAPABILITY_INTENT_EVENT_SELECTION,
        CapabilityIntentWireKindV2::Commit => SC_CAPABILITY_INTENT_EVENT_COMMIT,
    };
    let intent = value.resolved_intent;
    ScCapabilityIntentEventV2 {
        struct_size,
        api_version: SC_CAPABILITY_INTENT_API_VERSION_V2,
        generation: value.generation.get(),
        negotiation_version: value.negotiation_version,
        event_type,
        has_negotiation_version: 1,
        offerer_role: value.offerer_role as u8,
        selector_role: value.selector_role as u8,
        projection: value.projection as u8,
        transport: value.transport as u8,
        local_role: intent.local_role() as u8,
        source_topology: intent.source_topology() as u8,
        sink_presentation: intent.sink_presentation() as u8,
        input_policy: intent.input_policy() as u8,
        transport_preference: intent.transport_preference() as u8,
        topology: intent.topology() as u8,
        reserved0: [0; 2],
        reserved1: 0,
    }
}

fn local_role(value: u8) -> Option<LocalRole> {
    match value {
        1 => Some(LocalRole::Source),
        2 => Some(LocalRole::Sink),
        3 => Some(LocalRole::Relay),
        _ => None,
    }
}

fn encode_profile(value: ScCapabilityIntentProfileV2) -> Option<String> {
    if value.generation == 0 || value.reserved != [0; 7] {
        return None;
    }
    let capabilities = IntentCapabilitySet::try_from_bits(value.capabilities).ok()?;
    let product_profile = ProductCapabilityProfile::new(capabilities).ok()?;
    let message = CapabilityIntentProfileWireMessageV2::try_from_product_profile(
        SessionGeneration::new(value.generation),
        local_role(value.sender_role)?,
        product_profile,
    )
    .ok()?;
    encode_capability_intent_profile_wire_v2(message).ok()
}

fn ffi_profile(
    struct_size: u32,
    value: CapabilityIntentProfileWireMessageV2,
) -> ScCapabilityIntentProfileV2 {
    ScCapabilityIntentProfileV2 {
        struct_size,
        api_version: SC_CAPABILITY_INTENT_API_VERSION_V2,
        generation: value.generation().get(),
        capabilities: value.peer_profile().capabilities().bits(),
        sender_role: value.sender_role() as u8,
        reserved: [0; 7],
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_wire_encode_v2(
    event: *const ScCapabilityIntentEventV2,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        encode_wire(event, output, output_capacity, needed, encode_intent_event)
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_wire_decode_v2(
    input: *const u8,
    input_length: usize,
    output: *mut ScCapabilityIntentEventV2,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        decode_wire(
            input,
            input_length,
            CAPABILITY_INTENT_WIRE_MAX_BYTES_V2,
            output,
            |bytes, struct_size| {
                decode_capability_intent_wire_v2(bytes)
                    .ok()
                    .map(|value| ffi_intent_event(struct_size, value))
            },
        )
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_profile_wire_encode_v2(
    profile: *const ScCapabilityIntentProfileV2,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        encode_wire(profile, output, output_capacity, needed, encode_profile)
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_profile_wire_decode_v2(
    input: *const u8,
    input_length: usize,
    output: *mut ScCapabilityIntentProfileV2,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        decode_wire(
            input,
            input_length,
            CAPABILITY_INTENT_PROFILE_WIRE_MAX_BYTES_V2,
            output,
            |bytes, struct_size| {
                decode_capability_intent_profile_wire_v2(bytes)
                    .ok()
                    .map(|value| ffi_profile(struct_size, value))
            },
        )
    })
}
