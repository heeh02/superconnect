use std::{mem::size_of, slice};

use crate::control_envelope::{
    claim_control_envelope_kind_v1, ControlEnvelopeErrorV1, CONTROL_ENVELOPE_MAX_BYTES_V1,
};
use crate::ffi::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, pointer_is_aligned, ScStatus,
    SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK, SC_UNSUPPORTED_VERSION,
};

#[no_mangle]
pub unsafe extern "C" fn sc_control_envelope_claim_kind_v1(
    input: *const u8,
    input_length: usize,
    output_kind: *mut u32,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        if input_length > CONTROL_ENVELOPE_MAX_BYTES_V1
            || output_kind.is_null()
            || !pointer_is_aligned(output_kind)
        {
            return SC_INVALID_ARGUMENT;
        }
        let Some(input_range) = checked_byte_range(input, input_length) else {
            return SC_INVALID_ARGUMENT;
        };
        let Some(output_range) = checked_byte_range(output_kind.cast(), size_of::<u32>()) else {
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
        let kind = match claim_control_envelope_kind_v1(bytes) {
            Ok(value) => value,
            Err(ControlEnvelopeErrorV1::Unknown | ControlEnvelopeErrorV1::Legacy) => {
                return SC_UNSUPPORTED_VERSION
            }
            Err(ControlEnvelopeErrorV1::TooLarge | ControlEnvelopeErrorV1::Malformed) => {
                return SC_INVALID_ARGUMENT
            }
        };
        output_kind.write(kind);
        SC_OK
    })
}
