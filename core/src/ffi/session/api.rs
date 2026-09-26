use std::mem::size_of;
use std::ptr;

use crate::session::{ScSession as CoreSession, SessionPhase, MAX_SESSION_EFFECTS};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_OK,
};
use super::decode::{decode_config, decode_event};
use super::encode::encode_effect;
use super::types::*;

fn phase_value(phase: SessionPhase) -> u32 {
    phase as u32
}

fn handle_range(handle: *const ScSessionV1) -> Option<(usize, usize)> {
    checked_byte_range(handle.cast(), size_of::<ScSessionV1>())
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_new_v1(
    config: *const ScSessionConfigV1,
    output: *mut *mut ScSessionV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if config.is_null()
            || output.is_null()
            || !pointer_is_aligned(config)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(config_range) = checked_byte_range(config.cast(), size_of::<ScSessionConfigV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output.cast(), size_of::<*mut ScSessionV1>())
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
        let raw_config = config.read();
        let Some(config) = decode_config(raw_config) else {
            return SC_INVALID_ARGUMENT;
        };
        output.write(Box::into_raw(Box::new(ScSessionV1 {
            inner: CoreSession::new(config),
            config: raw_config,
        })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_free_v1(session: *mut ScSessionV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if session.is_null() {
            return SC_OK;
        }
        if !pointer_is_aligned(session) || handle_range(session).is_none() {
            return SC_INVALID_ARGUMENT;
        }
        drop(Box::from_raw(session));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_apply_v1(
    session: *mut ScSessionV1,
    event: *const ScSessionEventV1,
    effects: *mut ScSessionEffectV1,
    effect_capacity: u32,
    written: *mut u32,
    needed: *mut u32,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if session.is_null()
            || event.is_null()
            || written.is_null()
            || needed.is_null()
            || !pointer_is_aligned(session)
            || !pointer_is_aligned(event)
            || !pointer_is_aligned(written)
            || !pointer_is_aligned(needed)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(session_range) = handle_range(session) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(event_range) = checked_byte_range(event.cast(), size_of::<ScSessionEventV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(written_range) = checked_byte_range(written.cast(), size_of::<u32>()) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<u32>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[session_range, event_range, written_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        written.write(0);
        needed.write(0);

        let status = versioned_pointer_status(event);
        if status != SC_OK {
            return status;
        }
        let Some(event) = decode_event(event.read()) else {
            return SC_INVALID_ARGUMENT;
        };
        if effect_capacity < SC_SESSION_MAX_EFFECTS_V1 {
            needed.write(SC_SESSION_MAX_EFFECTS_V1);
            return SC_BUFFER_TOO_SMALL;
        }
        if effects.is_null() || !pointer_is_aligned(effects) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(effects_bytes) = size_of::<ScSessionEffectV1>().checked_mul(MAX_SESSION_EFFECTS)
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(effects_range) = checked_byte_range(effects.cast(), effects_bytes) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[
            session_range,
            event_range,
            effects_range,
            written_range,
            needed_range,
        ]) {
            return SC_INVALID_ARGUMENT;
        }

        needed.write(SC_SESSION_MAX_EFFECTS_V1);
        let emitted = (&mut *session).inner.apply(event);
        if emitted.len() > MAX_SESSION_EFFECTS {
            return SC_INTERNAL_ERROR;
        }
        for (index, effect) in emitted.iter().copied().enumerate() {
            effects.add(index).write(encode_effect(effect));
        }
        written.write(emitted.len() as u32);
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_session_snapshot_v1(
    session: *const ScSessionV1,
    output: *mut ScSessionSnapshotV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if session.is_null()
            || output.is_null()
            || !pointer_is_aligned(session)
            || !pointer_is_aligned(output)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(session_range) = handle_range(session) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast(), size_of::<ScSessionSnapshotV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[session_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let struct_size = (*output).struct_size;
        let session = &*session;
        output.write(ScSessionSnapshotV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            generation: session.config.generation,
            first_operation_id: session.config.first_operation_id,
            local_enrollment_key: session.config.local_enrollment_key,
            phase: phase_value(session.inner.phase()),
            side: session.config.side,
            media_role: session.config.media_role,
            origin: session.config.origin,
            pending_timer_count: session.inner.pending_timer_count() as u32,
            pending_operation_count: session.inner.pending_operation_count() as u32,
            invariants_hold: u32::from(session.inner.invariants_hold()),
            reserved0: 0,
            local_identity: session.config.local_identity,
            reserved1: 0,
            reserved2: 0,
        });
        SC_OK
    })
}
