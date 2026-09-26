use std::collections::VecDeque;
use std::mem::size_of;
use std::ptr;

use zeroize::Zeroize;

use crate::secure_connection::{ScSecureConnection, SecureConnectionEvent};
use crate::session::{OperationId, SessionGeneration};

use super::super::session::decode_event;
use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT,
    SC_NO_FRAME, SC_OK,
};
use super::mapping::{
    decode_material, decode_secure_config, encode_secure_effect, record_phase_value,
};
use super::types::*;
use super::util::{handle_range, outputs_are_drained, queue_effects};

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_new_v1(
    config: *const ScSecureConnectionConfigV1,
    output: *mut *mut ScSecureConnectionV1,
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
            checked_byte_range(config.cast(), size_of::<ScSecureConnectionConfigV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<*mut ScSecureConnectionV1>())
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
        let raw = config.read();
        let nested_status = versioned_pointer_status(&raw.session);
        if nested_status != SC_OK {
            return nested_status;
        }
        let Some(config) = decode_secure_config(raw) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(Box::into_raw(Box::new(ScSecureConnectionV1 {
            inner: ScSecureConnection::new(config),
            effects: VecDeque::with_capacity(SC_SECURE_CONNECTION_MAX_EFFECTS_V1 as usize),
            inbound: VecDeque::with_capacity(SC_SECURE_CONNECTION_MAX_INBOUND_FRAMES_V1 as usize),
            next_inbound_generation: 1,
            borrowed_inbound_generation: None,
        })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_free_v1(
    connection: *mut ScSecureConnectionV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null() {
            return SC_OK;
        }
        if !pointer_is_aligned(connection) || handle_range(connection).is_none() {
            return SC_INVALID_ARGUMENT;
        }
        drop(Box::from_raw(connection));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_observe_record_version_v1(
    connection: *mut ScSecureConnectionV1,
    generation: u64,
    record_version: u16,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || !pointer_is_aligned(connection)
            || handle_range(connection).is_none()
        {
            return SC_INVALID_ARGUMENT;
        }
        let connection = &mut *connection;
        if !outputs_are_drained(connection) || generation == 0 {
            return if outputs_are_drained(connection) {
                SC_INVALID_ARGUMENT
            } else {
                SC_SECURE_CONNECTION_PENDING_OUTPUT
            };
        }
        let effects = connection
            .inner
            .apply(SecureConnectionEvent::PeerRecordVersion {
                generation: SessionGeneration::new(generation),
                version: (record_version != 0).then_some(record_version),
            });
        queue_effects(connection, effects);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_apply_session_v1(
    connection: *mut ScSecureConnectionV1,
    event: *const super::super::ScSessionEventV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || event.is_null()
            || !pointer_is_aligned(connection)
            || !pointer_is_aligned(event)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(event_range) =
            checked_byte_range(event.cast(), size_of::<super::super::ScSessionEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, event_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        let Some(event) = decode_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        let connection = &mut *connection;
        if !outputs_are_drained(connection) {
            return SC_SECURE_CONNECTION_PENDING_OUTPUT;
        }
        let effects = connection
            .inner
            .apply(SecureConnectionEvent::Session(event));
        queue_effects(connection, effects);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_record_material_prepared_v1(
    connection: *mut ScSecureConnectionV1,
    material: *const ScSecureRecordMaterialV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || material.is_null()
            || !pointer_is_aligned(connection)
            || !pointer_is_aligned(material)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(material_range) =
            checked_byte_range(material.cast(), size_of::<ScSecureRecordMaterialV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, material_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(material);
        if status != SC_OK {
            return status;
        }
        let mut raw = material.read();
        let generation = raw.generation;
        let operation = raw.operation;
        let decoded = decode_material(&raw);
        raw.pair_secret.zeroize();
        raw.responder_challenge.zeroize();
        raw.initiator_challenge.zeroize();
        let Some(material) = decoded else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(operation) = OperationId::new(operation) else {
            return SC_INVALID_ARGUMENT;
        };
        let connection = &mut *connection;
        if !outputs_are_drained(connection) {
            return SC_SECURE_CONNECTION_PENDING_OUTPUT;
        }
        let effects = connection
            .inner
            .apply(SecureConnectionEvent::RecordMaterialPrepared {
                generation: SessionGeneration::new(generation),
                operation,
                material,
            });
        queue_effects(connection, effects);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_records_activated_v1(
    connection: *mut ScSecureConnectionV1,
    generation: u64,
    operation: u64,
    success: u8,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || !pointer_is_aligned(connection)
            || handle_range(connection).is_none()
        {
            return SC_INVALID_ARGUMENT;
        }
        let connection = &mut *connection;
        let Some(operation) = OperationId::new(operation) else {
            return SC_INVALID_ARGUMENT;
        };
        if generation == 0 || !matches!(success, 0 | 1) {
            return SC_INVALID_ARGUMENT;
        }
        if !outputs_are_drained(connection) {
            return SC_SECURE_CONNECTION_PENDING_OUTPUT;
        }
        let effects = connection
            .inner
            .apply(SecureConnectionEvent::RecordsActivated {
                generation: SessionGeneration::new(generation),
                operation,
                success: success == 1,
            });
        queue_effects(connection, effects);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_pop_effect_v1(
    connection: *mut ScSecureConnectionV1,
    output: *mut ScSecureConnectionEffectV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || output.is_null()
            || !pointer_is_aligned(connection)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScSecureConnectionEffectV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(effect) = (&mut *connection).effects.pop_front() else {
            return SC_NO_FRAME;
        };
        let struct_size = output.read().struct_size;
        output.write(encode_secure_effect(effect, struct_size));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_snapshot_v1(
    connection: *const ScSecureConnectionV1,
    output: *mut ScSecureConnectionSnapshotV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || output.is_null()
            || !pointer_is_aligned(connection)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScSecureConnectionSnapshotV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let connection = &*connection;
        let struct_size = output.read().struct_size;
        output.write(ScSecureConnectionSnapshotV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            generation: connection.inner.generation().get(),
            session_phase: connection.inner.session_phase() as u32,
            record_phase: record_phase_value(connection.inner.record_phase()),
            records_active: u32::from(connection.inner.records_active()),
            records_required: u32::from(connection.inner.records_required()),
            invariants_hold: u32::from(connection.inner.invariants_hold()),
            pending_effect_count: connection.effects.len() as u32,
            pending_inbound_count: connection.inbound.len() as u32,
            inbound_view_outstanding: u32::from(connection.borrowed_inbound_generation.is_some()),
            reserved0: 0,
            reserved1: 0,
        });
        SC_OK
    })
}
