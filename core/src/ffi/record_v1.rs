use std::mem::size_of;
use std::ptr;
use std::slice;

use zeroize::Zeroizing;

use crate::record_v1::{
    derive_session_context, RecordDirection, RecordError, RecordOpener, RecordSealer, RecordType,
    MAX_RECORD_PLAINTEXT,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned,
    versioned_pointer_status, ScStatus, SC_AUTHENTICATION_FAILED, SC_BUFFER_TOO_SMALL,
    SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_RECORD_REPLAYED: ScStatus = 110;
pub const SC_RECORD_COUNTER_EXHAUSTED: ScStatus = 111;
pub const SC_RECORD_TOO_LARGE: ScStatus = 112;

#[repr(C)]
pub struct ScRecordConfigV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub pair_secret: [u8; 32],
    pub session_context: [u8; 32],
    pub session_generation: u64,
    pub max_plaintext_bytes: u64,
    pub direction: u8,
    pub reserved: [u8; 7],
}

#[repr(C)]
pub struct ScRecordContextRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub initiator_peer_id_length: u32,
    pub responder_peer_id_length: u32,
    pub reserved: [u32; 2],
    pub responder_challenge: [u8; 32],
    pub initiator_challenge: [u8; 32],
    pub initiator_peer_id: [u8; 128],
    pub responder_peer_id: [u8; 128],
}

#[repr(C)]
pub struct ScRecordContextV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub bytes: [u8; 32],
    pub session_generation: u64,
}

pub struct ScRecordSealerV1 {
    inner: RecordSealer,
}

pub struct ScRecordOpenerV1 {
    inner: RecordOpener,
}

fn record_status(error: RecordError) -> ScStatus {
    match error {
        RecordError::AuthenticationFailed => SC_AUTHENTICATION_FAILED,
        RecordError::ReplayOrReorder => SC_RECORD_REPLAYED,
        RecordError::CounterExhausted => SC_RECORD_COUNTER_EXHAUSTED,
        RecordError::PlaintextTooLarge | RecordError::LengthOverflow => SC_RECORD_TOO_LARGE,
        RecordError::KeyDerivationFailed | RecordError::SealFailed => SC_INTERNAL_ERROR,
        RecordError::InvalidSecret
        | RecordError::InvalidContext
        | RecordError::InvalidDirection
        | RecordError::InvalidRecordType
        | RecordError::InvalidGeneration
        | RecordError::InvalidMaximum
        | RecordError::InvalidRecord
        | RecordError::WrongDirection
        | RecordError::WrongGeneration => SC_INVALID_ARGUMENT,
    }
}

fn record_type(value: u8) -> Result<RecordType, ScStatus> {
    RecordType::try_from(value).map_err(record_status)
}

fn peer_id(length: u32, bytes: &[u8; 128]) -> Result<&[u8], ScStatus> {
    let length = usize::try_from(length).map_err(|_| SC_INVALID_ARGUMENT)?;
    if length == 0 || length > bytes.len() || bytes[length..].iter().any(|value| *value != 0) {
        return Err(SC_INVALID_ARGUMENT);
    }
    Ok(&bytes[..length])
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_context_derive_v1(
    request: *const ScRecordContextRequestV1,
    output: *mut ScRecordContextV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(request);
        if status != SC_OK {
            return status;
        }
        let status = versioned_pointer_status(output);
        if status != SC_OK {
            return status;
        }
        let Some(request_range) =
            checked_byte_range(request.cast::<u8>(), size_of::<ScRecordContextRequestV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) =
            checked_byte_range(output.cast::<u8>(), size_of::<ScRecordContextV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[request_range, output_range]) {
            return SC_INVALID_ARGUMENT;
        }
        let request = &*request;
        if request.reserved != [0; 2] {
            return SC_INVALID_ARGUMENT;
        }
        let initiator = match peer_id(request.initiator_peer_id_length, &request.initiator_peer_id)
        {
            Ok(value) => value,
            Err(status) => return status,
        };
        let responder = match peer_id(request.responder_peer_id_length, &request.responder_peer_id)
        {
            Ok(value) => value,
            Err(status) => return status,
        };
        let context = match derive_session_context(
            initiator,
            responder,
            &request.responder_challenge,
            &request.initiator_challenge,
        ) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScRecordContextV1 {
            struct_size,
            api_version: super::SC_API_VERSION_V1,
            bytes: context.bytes,
            session_generation: context.generation,
        });
        SC_OK
    })
}

unsafe fn config_values(
    config: *const ScRecordConfigV1,
) -> Result<(RecordDirection, u64, usize), ScStatus> {
    let status = versioned_pointer_status(config);
    if status != SC_OK {
        return Err(status);
    }
    let config = &*config;
    if config.reserved != [0; 7] {
        return Err(SC_INVALID_ARGUMENT);
    }
    let direction = RecordDirection::try_from(config.direction).map_err(record_status)?;
    let maximum = usize::try_from(config.max_plaintext_bytes).map_err(|_| SC_RECORD_TOO_LARGE)?;
    if maximum == 0 || maximum > MAX_RECORD_PLAINTEXT {
        return Err(SC_RECORD_TOO_LARGE);
    }
    Ok((direction, config.session_generation, maximum))
}

unsafe fn new_ranges_status<T>(config: *const ScRecordConfigV1, output: *mut *mut T) -> ScStatus {
    if output.is_null() || !pointer_is_aligned(output) {
        return SC_INVALID_ARGUMENT;
    }
    let Some(config_range) = checked_byte_range(config.cast::<u8>(), size_of::<ScRecordConfigV1>())
    else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output.cast::<u8>(), size_of::<*mut T>()) else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[config_range, output_range]) {
        return SC_INVALID_ARGUMENT;
    }
    SC_OK
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_sealer_new_v1(
    config: *const ScRecordConfigV1,
    output: *mut *mut ScRecordSealerV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let (direction, generation, maximum) = match config_values(config) {
            Ok(value) => value,
            Err(status) => return status,
        };
        let status = new_ranges_status(config, output);
        if status != SC_OK {
            return status;
        }
        let config = &*config;
        let inner = match RecordSealer::new(
            &config.pair_secret,
            &config.session_context,
            direction,
            generation,
            maximum,
        ) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        output.write(Box::into_raw(Box::new(ScRecordSealerV1 { inner })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_sealer_free_v1(sealer: *mut ScRecordSealerV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if !sealer.is_null() {
            if !pointer_is_aligned(sealer) {
                return SC_INVALID_ARGUMENT;
            }
            drop(Box::from_raw(sealer));
        }
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_opener_new_v1(
    config: *const ScRecordConfigV1,
    output: *mut *mut ScRecordOpenerV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let (direction, generation, maximum) = match config_values(config) {
            Ok(value) => value,
            Err(status) => return status,
        };
        let status = new_ranges_status(config, output);
        if status != SC_OK {
            return status;
        }
        let config = &*config;
        let inner = match RecordOpener::new(
            &config.pair_secret,
            &config.session_context,
            direction,
            generation,
            maximum,
        ) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        output.write(Box::into_raw(Box::new(ScRecordOpenerV1 { inner })));
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_opener_free_v1(opener: *mut ScRecordOpenerV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if !opener.is_null() {
            if !pointer_is_aligned(opener) {
                return SC_INVALID_ARGUMENT;
            }
            drop(Box::from_raw(opener));
        }
        SC_OK
    })
}

unsafe fn io_ranges_status<H>(
    handle: *mut H,
    input: *const u8,
    input_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    if handle.is_null()
        || !pointer_is_aligned(handle)
        || needed.is_null()
        || !pointer_is_aligned(needed)
        || (output.is_null() && output_capacity != 0)
    {
        return SC_INVALID_ARGUMENT;
    }
    let Some(handle_range) = checked_byte_range(handle.cast::<u8>(), size_of::<H>()) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(input_range) = checked_byte_range(input, input_length) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output, output_capacity) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[handle_range, input_range, output_range, needed_range]) {
        return SC_INVALID_ARGUMENT;
    }
    SC_OK
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_seal_v1(
    sealer: *mut ScRecordSealerV1,
    record_type_value: u8,
    flags: u8,
    plaintext: *const u8,
    plaintext_length: usize,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = io_ranges_status(
            sealer,
            plaintext,
            plaintext_length,
            output,
            output_capacity,
            needed,
        );
        if status != SC_OK {
            return status;
        }
        let record_type = match record_type(record_type_value) {
            Ok(value) => value,
            Err(status) => return status,
        };
        let sealer = &mut *sealer;
        let required = match sealer.inner.required_length(plaintext_length) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        if output.is_null() || output_capacity < required {
            needed.write(required);
            return SC_BUFFER_TOO_SMALL;
        }
        let plaintext = if plaintext_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(plaintext, plaintext_length)
        };
        let record = match sealer.inner.seal(record_type, flags, plaintext) {
            Ok((_, value)) => value,
            Err(error) => return record_status(error),
        };
        ptr::copy_nonoverlapping(record.as_ptr(), output, record.len());
        needed.write(record.len());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_record_open_v1(
    opener: *mut ScRecordOpenerV1,
    expected_record_type_value: u8,
    record: *const u8,
    record_length: usize,
    authenticated_flags: *mut u8,
    output: *mut u8,
    output_capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = io_ranges_status(
            opener,
            record,
            record_length,
            output,
            output_capacity,
            needed,
        );
        if status != SC_OK {
            return status;
        }
        if authenticated_flags.is_null() {
            return SC_INVALID_ARGUMENT;
        }
        let Some(handle_range) =
            checked_byte_range(opener.cast::<u8>(), size_of::<ScRecordOpenerV1>())
        else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(record_range) = checked_byte_range(record, record_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(flags_range) = checked_byte_range(authenticated_flags, 1) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output, output_capacity) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(needed_range) = checked_byte_range(needed.cast::<u8>(), size_of::<usize>()) else {
            return SC_INVALID_ARGUMENT;
        };
        if !byte_ranges_are_disjoint(&[
            handle_range,
            record_range,
            flags_range,
            output_range,
            needed_range,
        ]) {
            return SC_INVALID_ARGUMENT;
        }
        let expected_type = match record_type(expected_record_type_value) {
            Ok(value) => value,
            Err(status) => return status,
        };
        let opener = &mut *opener;
        let metadata = match opener.inner.inspect(if record_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(record, record_length)
        }) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        if metadata.record_type != expected_type {
            return SC_INVALID_ARGUMENT;
        }
        if output.is_null() || output_capacity < metadata.plaintext_length {
            needed.write(metadata.plaintext_length);
            return SC_BUFFER_TOO_SMALL;
        }
        let (_, plaintext) = match opener.inner.open(if record_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(record, record_length)
        }) {
            Ok(value) => value,
            Err(error) => return record_status(error),
        };
        let plaintext = Zeroizing::new(plaintext);
        if !plaintext.is_empty() {
            ptr::copy_nonoverlapping(plaintext.as_ptr(), output, plaintext.len());
        }
        authenticated_flags.write(metadata.flags);
        needed.write(plaintext.len());
        SC_OK
    })
}
