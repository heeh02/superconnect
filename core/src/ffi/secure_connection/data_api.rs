use std::mem::size_of;
use std::ptr;

use crate::secure_connection::SecureConnectionEvent;
use crate::session::{SessionEvent, SessionGeneration};

use super::super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_NO_FRAME, SC_OK, SC_STALE_VIEW,
};
use super::mapping::{encode_control, error_status};
use super::types::*;
use super::util::{handle_range, outputs_are_drained, queue_effects, queue_pending_data_effects};

fn byte_slice<'a>(bytes: *const u8, length: usize) -> &'a [u8] {
    if length == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, length) }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_seal_frame_v1(
    connection: *mut ScSecureConnectionV1,
    channel: u8,
    flags: u8,
    plaintext: *const u8,
    plaintext_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || needed.is_null()
            || !pointer_is_aligned(connection)
            || !pointer_is_aligned(needed)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(input_range) = checked_byte_range(plaintext, plaintext_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, input_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(0);
        let connection = &mut *connection;
        if !outputs_are_drained(connection) {
            return SC_SECURE_CONNECTION_PENDING_OUTPUT;
        }
        let required = match connection
            .inner
            .sealed_frame_length(channel, plaintext_length)
        {
            Ok(required) => required,
            Err(error) => return error_status(error),
        };
        needed.write(required);
        if output_capacity < required {
            return SC_BUFFER_TOO_SMALL;
        }
        if output.is_null() {
            return SC_INVALID_ARGUMENT;
        }
        let Some(output_range) = checked_byte_range(output, required) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, input_range, needed_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let plaintext = byte_slice(plaintext, plaintext_length);
        let frame = match connection.inner.seal_outbound(channel, flags, plaintext) {
            Ok(frame) => frame,
            Err(error) => {
                queue_pending_data_effects(connection);
                return error_status(error);
            }
        };
        if frame.len() != required {
            queue_pending_data_effects(connection);
            return SC_INTERNAL_ERROR;
        }
        ptr::copy_nonoverlapping(frame.as_ptr(), output, frame.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_push_v1(
    connection: *mut ScSecureConnectionV1,
    bytes: *const u8,
    length: usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null() || !pointer_is_aligned(connection) {
            return SC_INVALID_ARGUMENT;
        }
        let Some(connection_range) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(input_range) = checked_byte_range(bytes, length) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[connection_range, input_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let connection = &mut *connection;
        if !outputs_are_drained(connection) {
            return SC_SECURE_CONNECTION_PENDING_OUTPUT;
        }
        let frames = match connection.inner.push_inbound(byte_slice(bytes, length)) {
            Ok(frames) => frames,
            Err(error) => {
                queue_pending_data_effects(connection);
                return error_status(error);
            }
        };
        let Some(last_generation) = connection
            .next_inbound_generation
            .checked_add(frames.len() as u64)
        else {
            let generation = connection.inner.generation();
            let effects = connection.inner.apply(SecureConnectionEvent::Session(
                SessionEvent::TransportFailed { generation },
            ));
            queue_effects(connection, effects);
            return SC_INTERNAL_ERROR;
        };
        for frame in frames {
            let generation = connection.next_inbound_generation;
            connection.next_inbound_generation += 1;
            connection
                .inbound
                .push_back(QueuedInbound { generation, frame });
        }
        connection.next_inbound_generation = last_generation;
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_next_inbound_v1(
    connection: *mut ScSecureConnectionV1,
    output: *mut ScSecureInboundViewV1,
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
            checked_byte_range(output.cast(), size_of::<ScSecureInboundViewV1>())
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
        let connection = &mut *connection;
        let Some(queued) = connection.inbound.front() else {
            return SC_NO_FRAME;
        };
        let Some(payload_range) =
            checked_byte_range(queued.frame.payload.as_ptr(), queued.frame.payload.len())
        else {
            return SC_INTERNAL_ERROR;
        };
        if !byte_ranges_are_disjoint(&[output_range, payload_range]) {
            return SC_INVALID_ARGUMENT;
        }
        if connection
            .borrowed_inbound_generation
            .is_some_and(|generation| generation != queued.generation)
        {
            return SC_INTERNAL_ERROR;
        }
        connection.borrowed_inbound_generation = Some(queued.generation);
        let struct_size = output.read().struct_size;
        output.write(ScSecureInboundViewV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            channel: queued.frame.channel,
            flags: queued.frame.flags,
            control_present: u8::from(queued.frame.control.is_some()),
            reserved0: 0,
            reserved1: 0,
            payload: queued.frame.payload.as_ptr(),
            payload_length: queued.frame.payload.len(),
            generation: queued.generation,
            control: queued.frame.control.map(encode_control).unwrap_or_default(),
            reserved2: 0,
        });
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_secure_connection_consume_inbound_v1(
    connection: *mut ScSecureConnectionV1,
    generation: u64,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if connection.is_null()
            || !pointer_is_aligned(connection)
            || generation == SessionGeneration::INVALID.get()
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(_) = handle_range(connection) else {
            return SC_INVALID_ARGUMENT;
        };
        let connection = &mut *connection;
        if connection.borrowed_inbound_generation != Some(generation)
            || connection
                .inbound
                .front()
                .is_none_or(|queued| queued.generation != generation)
        {
            return SC_STALE_VIEW;
        }
        connection.inbound.pop_front();
        connection.borrowed_inbound_generation = None;
        SC_OK
    })
}
