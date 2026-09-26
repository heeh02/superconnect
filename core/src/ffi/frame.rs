use std::mem::size_of;
use std::ptr;
use std::slice;

use crate::wire::frame::{
    encode_frame, encode_frame_header, FrameDecoder, FrameError, DEFAULT_MAX_BUFFERED_BYTES,
    FRAME_HEADER_SIZE, MAX_FRAME_PAYLOAD,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScFrameDecoderConfigV1, ScFrameDecoderV1, ScFrameV1, ScFrameViewV1,
    ScStatus, SC_BUFFER_TOO_SMALL, SC_DECODER_POISONED, SC_FRAME_TOO_LARGE, SC_INTERNAL_ERROR,
    SC_INVALID_ARGUMENT, SC_NO_FRAME, SC_OK, SC_STALE_VIEW,
};

fn frame_error_status(error: FrameError) -> ScStatus {
    match error {
        FrameError::BufferTooSmall => SC_BUFFER_TOO_SMALL,
        FrameError::TooLarge => SC_FRAME_TOO_LARGE,
        FrameError::StaleView => SC_STALE_VIEW,
        FrameError::Poisoned => SC_DECODER_POISONED,
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_encode_header_v1(
    channel: u8,
    flags: u8,
    payload_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if payload_length > MAX_FRAME_PAYLOAD || payload_length > u32::MAX as usize {
            return SC_FRAME_TOO_LARGE;
        }
        if needed.is_null() || !pointer_is_aligned(needed) {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() && output_capacity != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if output_capacity < FRAME_HEADER_SIZE {
            needed.write(FRAME_HEADER_SIZE);
            return SC_BUFFER_TOO_SMALL;
        }
        let Some(output_range) = checked_byte_range(output, FRAME_HEADER_SIZE) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[output_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(FRAME_HEADER_SIZE);
        let output = slice::from_raw_parts_mut(output, FRAME_HEADER_SIZE);
        match encode_frame_header(channel, flags, payload_length, output) {
            Ok(_) => SC_OK,
            Err(error) => frame_error_status(error),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_encode_v1(
    frame: *const ScFrameV1,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(frame);
        if status != SC_OK {
            return status;
        }
        if needed.is_null() || !pointer_is_aligned(needed) {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() && output_capacity != 0 {
            return SC_INVALID_ARGUMENT;
        }
        let Some(frame_range) = checked_byte_range(frame.cast::<u8>(), size_of::<ScFrameV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[frame_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let frame = frame.read();
        if frame.payload_length > MAX_FRAME_PAYLOAD || frame.payload_length > u32::MAX as usize {
            return SC_FRAME_TOO_LARGE;
        }
        let total = FRAME_HEADER_SIZE + frame.payload_length;
        let Some(payload_range) = checked_byte_range(frame.payload, frame.payload_length) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[payload_range, frame_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        if output_capacity < total {
            needed.write(total);
            return SC_BUFFER_TOO_SMALL;
        }
        let Some(output_range) = checked_byte_range(output, total) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[payload_range, output_range, frame_range, needed_range]) {
            return SC_INVALID_ARGUMENT;
        }
        needed.write(total);
        let payload = if frame.payload_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(frame.payload, frame.payload_length)
        };
        let output = slice::from_raw_parts_mut(output, total);
        match encode_frame(frame.channel, frame.flags, payload, output) {
            Ok(_) => SC_OK,
            Err(error) => frame_error_status(error),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_new_v1(
    config: *const ScFrameDecoderConfigV1,
    output: *mut *mut ScFrameDecoderV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if output.is_null() || !pointer_is_aligned(output) {
            return SC_INVALID_ARGUMENT;
        }
        let output = &mut *output;
        *output = ptr::null_mut();
        let status = versioned_pointer_status(config);
        if status != SC_OK {
            return status;
        }
        let config = &*config;
        let max_buffered_bytes = if config.max_buffered_bytes == 0 {
            DEFAULT_MAX_BUFFERED_BYTES
        } else {
            config.max_buffered_bytes
        };
        if !(FRAME_HEADER_SIZE..=DEFAULT_MAX_BUFFERED_BYTES).contains(&max_buffered_bytes) {
            return SC_INVALID_ARGUMENT;
        }
        *output = Box::into_raw(Box::new(ScFrameDecoderV1 {
            inner: FrameDecoder::new(max_buffered_bytes),
        }));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_free_v1(decoder: *mut ScFrameDecoderV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if !decoder.is_null() {
            drop(Box::from_raw(decoder));
        }
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_reset_v1(decoder: *mut ScFrameDecoderV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Some(decoder) = decoder.as_mut() else {
            return SC_INVALID_ARGUMENT;
        };
        decoder.inner.reset();
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_push_v1(
    decoder: *mut ScFrameDecoderV1,
    bytes: *const u8,
    length: usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if length > DEFAULT_MAX_BUFFERED_BYTES {
            if let Some(decoder) = decoder.as_mut() {
                if decoder.inner.is_poisoned() {
                    return SC_DECODER_POISONED;
                }
                decoder.inner.poison();
            }
            return SC_FRAME_TOO_LARGE;
        }
        let Some(decoder) = decoder.as_mut() else {
            return SC_INVALID_ARGUMENT;
        };
        if decoder.inner.is_poisoned() {
            return SC_DECODER_POISONED;
        }
        if checked_byte_range(bytes, length).is_none() {
            return SC_INVALID_ARGUMENT;
        }
        let incoming = if length == 0 {
            &[]
        } else {
            slice::from_raw_parts(bytes, length)
        };
        match decoder.inner.push(incoming) {
            Ok(()) => SC_OK,
            Err(error) => frame_error_status(error),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_next_v1(
    decoder: *mut ScFrameDecoderV1,
    output: *mut ScFrameViewV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Some(decoder) = decoder.as_mut() else {
            return SC_INVALID_ARGUMENT;
        };
        if decoder.inner.is_poisoned() {
            return SC_DECODER_POISONED;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let output = &mut *output;
        let meta = match decoder.inner.peek() {
            Ok(Some(meta)) => meta,
            Ok(None) => return SC_NO_FRAME,
            Err(error) => return frame_error_status(error),
        };
        output.api_version = super::SC_API_VERSION_V1;
        output.channel = meta.channel;
        output.flags = meta.flags;
        output.reserved = 0;
        output.payload = decoder.inner.payload_ptr(meta);
        output.payload_length = meta.payload_length;
        output.generation = meta.generation;
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_frame_decoder_consume_v1(
    decoder: *mut ScFrameDecoderV1,
    generation: u64,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let Some(decoder) = decoder.as_mut() else {
            return SC_INVALID_ARGUMENT;
        };
        match decoder.inner.consume(generation) {
            Ok(()) => SC_OK,
            Err(error) => frame_error_status(error),
        }
    })
}
