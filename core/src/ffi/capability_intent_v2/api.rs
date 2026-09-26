use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::capability::{IntentNegotiationConfig, ScCapabilityNegotiationV2};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned, ScStatus,
    SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK, SC_UNSUPPORTED_VERSION,
};
use super::mapping::{decode_config, decode_event, encode_effect, encode_side};
use super::schema::*;

pub struct ScCapabilityIntentNegotiationV2 {
    config: IntentNegotiationConfig,
    reducer: ScCapabilityNegotiationV2,
}

pub(super) unsafe fn pointer_status_v2<T>(pointer: *const T) -> ScStatus {
    if pointer.is_null() || !pointer_is_aligned(pointer) {
        return SC_INVALID_ARGUMENT;
    }
    if checked_byte_range(pointer.cast(), size_of::<T>()).is_none() {
        return SC_INVALID_ARGUMENT;
    }
    let bytes = pointer.cast::<u8>();
    let struct_size = bytes.cast::<u32>().read_unaligned();
    if struct_size < size_of::<T>() as u32 {
        return SC_INVALID_ARGUMENT;
    }
    let api_version = bytes.add(size_of::<u32>()).cast::<u32>().read_unaligned();
    if api_version == SC_CAPABILITY_INTENT_API_VERSION_V2 {
        SC_OK
    } else {
        SC_UNSUPPORTED_VERSION
    }
}

fn snapshot_value(
    handle: &ScCapabilityIntentNegotiationV2,
    struct_size: u32,
) -> ScCapabilityIntentSnapshotV2 {
    let config = handle.config;
    let resolved = config.resolved_intent();
    let mut output = ScCapabilityIntentSnapshotV2 {
        struct_size,
        api_version: SC_CAPABILITY_INTENT_API_VERSION_V2,
        generation: config.generation().get(),
        product_capabilities: config.product_profile().capabilities().bits(),
        peer_capabilities: config.peer_profile().capabilities().bits(),
        side: encode_side(config.side()),
        desired_peer_role: config.desired_peer_role() as u8,
        resolved_local_role: resolved.local_role() as u8,
        resolved_source_topology: resolved.source_topology() as u8,
        resolved_sink_presentation: resolved.sink_presentation() as u8,
        resolved_input_policy: resolved.input_policy() as u8,
        resolved_transport_preference: resolved.transport_preference() as u8,
        resolved_topology: resolved.topology() as u8,
        ..ScCapabilityIntentSnapshotV2::default()
    };
    if let Some(binding) = handle.reducer.binding() {
        output.has_binding = 1;
        output.binding_negotiated = u8::from(binding.negotiated);
        output.binding_local_role = binding.local_intent.local_role() as u8;
        output.binding_source_topology = binding.local_intent.source_topology() as u8;
        output.binding_sink_presentation = binding.local_intent.sink_presentation() as u8;
        output.binding_input_policy = binding.local_intent.input_policy() as u8;
        output.binding_transport_preference = binding.local_intent.transport_preference() as u8;
        output.binding_topology = binding.local_intent.topology() as u8;
        output.binding_peer_role = binding.peer_role as u8;
    }
    output
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_negotiation_new_v2(
    config: *const ScCapabilityIntentConfigV2,
    output: *mut *mut ScCapabilityIntentNegotiationV2,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if config.is_null()
            || output.is_null()
            || !pointer_is_aligned(config)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(config_range) =
            checked_byte_range(config.cast(), size_of::<ScCapabilityIntentConfigV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(
            output.cast(),
            size_of::<*mut ScCapabilityIntentNegotiationV2>(),
        ) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[config_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        output.write(ptr::null_mut());
        let status = pointer_status_v2(config);
        if status != SC_OK {
            return status;
        }
        let Some(config) = decode_config(config.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(Box::into_raw(Box::new(ScCapabilityIntentNegotiationV2 {
            config,
            reducer: ScCapabilityNegotiationV2::new(config),
        })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_negotiation_free_v2(
    handle: *mut ScCapabilityIntentNegotiationV2,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if handle.is_null() {
            return SC_OK;
        }
        if !pointer_is_aligned(handle)
            || checked_byte_range(handle.cast(), size_of::<ScCapabilityIntentNegotiationV2>())
                .is_none()
        {
            return SC_INVALID_ARGUMENT;
        }
        drop(Box::from_raw(handle));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_negotiation_apply_v2(
    handle: *mut ScCapabilityIntentNegotiationV2,
    event: *const ScCapabilityIntentEventV2,
    output: *mut ScCapabilityIntentEffectV2,
    output_capacity: usize,
    output_count: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if handle.is_null()
            || event.is_null()
            || output_count.is_null()
            || !pointer_is_aligned(handle)
            || !pointer_is_aligned(event)
            || !pointer_is_aligned(output_count)
            || (!output.is_null() && !pointer_is_aligned(output))
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(handle_range) =
            checked_byte_range(handle.cast(), size_of::<ScCapabilityIntentNegotiationV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(event_range) =
            checked_byte_range(event.cast(), size_of::<ScCapabilityIntentEventV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(count_range) = checked_byte_range(output_count.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity > SC_CAPABILITY_INTENT_MAX_EFFECTS_V2
            || (output.is_null() && output_capacity != 0)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(output_bytes) =
            output_capacity.checked_mul(size_of::<ScCapabilityIntentEffectV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output.cast(), output_bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[handle_range, event_range, output_range, count_range]) {
            return SC_INVALID_ARGUMENT;
        }
        output_count.write(0);
        let status = pointer_status_v2(event);
        if status != SC_OK {
            return status;
        }
        let Some(event) = decode_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity < SC_CAPABILITY_INTENT_MAX_EFFECTS_V2 {
            output_count.write(SC_CAPABILITY_INTENT_MAX_EFFECTS_V2);
            return SC_BUFFER_TOO_SMALL;
        }
        let handle = &mut *handle;
        let effects = handle.reducer.apply(event);
        let output = slice::from_raw_parts_mut(output, SC_CAPABILITY_INTENT_MAX_EFFECTS_V2);
        for (index, effect) in effects.iter().copied().enumerate() {
            output[index] = encode_effect(handle.config.generation(), effect);
        }
        output_count.write(effects.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_intent_negotiation_snapshot_v2(
    handle: *const ScCapabilityIntentNegotiationV2,
    output: *mut ScCapabilityIntentSnapshotV2,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if handle.is_null()
            || output.is_null()
            || !pointer_is_aligned(handle)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(handle_range) =
            checked_byte_range(handle.cast(), size_of::<ScCapabilityIntentNegotiationV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScCapabilityIntentSnapshotV2>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[handle_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = pointer_status_v2(output);
        if status != SC_OK {
            return status;
        }
        let struct_size = (*output).struct_size;
        output.write(snapshot_value(&*handle, struct_size));
        SC_OK
    })
}
