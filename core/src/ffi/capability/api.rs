use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::capability::{NegotiationConfig, ScCapabilityNegotiation as CapabilityReducer};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};
use super::mapping::{decode_config, decode_event, encode_effect, encode_side};
use super::schema::*;

pub struct ScCapabilityNegotiationV1 {
    config: NegotiationConfig,
    reducer: CapabilityReducer,
}

fn snapshot_value(handle: &ScCapabilityNegotiationV1, struct_size: u32) -> ScCapabilitySnapshotV1 {
    let config = handle.config;
    let mut value = ScCapabilitySnapshotV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        generation: config.generation().get(),
        authorized_capabilities: config.authorized().bits(),
        side: encode_side(config.side()),
        local_role: config.local_role() as u8,
        desired_peer_role: config.desired_peer_role() as u8,
        projection: config.projection() as u8,
        transport: SC_CAPABILITY_TRANSPORT_TCP,
        ..ScCapabilitySnapshotV1::default()
    };
    if let Some(binding) = handle.reducer.binding() {
        value.has_binding = 1;
        value.binding_local_role = binding.local_role as u8;
        value.binding_peer_role = binding.peer_role as u8;
        value.binding_projection = binding.projection as u8;
        value.binding_transport = binding.transport as u8;
        value.binding_negotiated = u8::from(binding.negotiated);
    }
    value
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_negotiation_new_v1(
    config: *const ScCapabilityConfigV1,
    output: *mut *mut ScCapabilityNegotiationV1,
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
            checked_byte_range(config.cast(), size_of::<ScCapabilityConfigV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<*mut ScCapabilityNegotiationV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[config_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        output.write(ptr::null_mut());

        let status = versioned_pointer_status(config);
        if status != SC_OK {
            return status;
        }
        let Some(config) = decode_config(config.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(Box::into_raw(Box::new(ScCapabilityNegotiationV1 {
            config,
            reducer: CapabilityReducer::new(config),
        })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_negotiation_free_v1(
    handle: *mut ScCapabilityNegotiationV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if handle.is_null() {
            return SC_OK;
        }
        if !pointer_is_aligned(handle)
            || checked_byte_range(handle.cast(), size_of::<ScCapabilityNegotiationV1>()).is_none()
        {
            return SC_INVALID_ARGUMENT;
        }
        drop(Box::from_raw(handle));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_negotiation_apply_v1(
    handle: *mut ScCapabilityNegotiationV1,
    event: *const ScCapabilityEventV1,
    output: *mut ScCapabilityEffectV1,
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
            checked_byte_range(handle.cast(), size_of::<ScCapabilityNegotiationV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(event_range) = checked_byte_range(event.cast(), size_of::<ScCapabilityEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(count_range) = checked_byte_range(output_count.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[handle_range, event_range, count_range]) {
            return SC_INVALID_ARGUMENT;
        }
        output_count.write(0);

        if output_capacity > SC_CAPABILITY_MAX_EFFECTS_V1 {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() && output_capacity != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(output_bytes) = output_capacity.checked_mul(size_of::<ScCapabilityEffectV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output.cast(), output_bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[handle_range, event_range, output_range, count_range]) {
            return SC_INVALID_ARGUMENT;
        }

        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        let Some(event) = decode_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity < SC_CAPABILITY_MAX_EFFECTS_V1 {
            output_count.write(SC_CAPABILITY_MAX_EFFECTS_V1);
            return SC_BUFFER_TOO_SMALL;
        }

        let handle = &mut *handle;
        let effects = handle.reducer.apply(event);
        let output = slice::from_raw_parts_mut(output, SC_CAPABILITY_MAX_EFFECTS_V1);
        for (index, effect) in effects.iter().copied().enumerate() {
            output[index] = encode_effect(handle.config.generation(), effect);
        }
        output_count.write(effects.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_capability_negotiation_snapshot_v1(
    handle: *const ScCapabilityNegotiationV1,
    output: *mut ScCapabilitySnapshotV1,
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
            checked_byte_range(handle.cast(), size_of::<ScCapabilityNegotiationV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScCapabilitySnapshotV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[handle_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let struct_size = (*output).struct_size;
        output.write(snapshot_value(&*handle, struct_size));
        SC_OK
    })
}
