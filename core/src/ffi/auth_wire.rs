use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, versioned_pointer_status, ScStatus,
    SC_API_VERSION_V1, SC_BUFFER_TOO_SMALL, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};
use crate::{decode_auth_wire_v1, encode_auth_wire_v1, AuthWireMessageV1, AUTH_WIRE_MAX_BYTES_V1};
use std::{fmt, mem::size_of, ptr, slice};
use zeroize::{Zeroize, Zeroizing};

pub const SC_AUTH_WIRE_KIND_AUTH: u8 = 1;
pub const SC_AUTH_WIRE_KIND_AUTH_ACK: u8 = 2;
pub const SC_AUTH_WIRE_KIND_PAIR_SECRET: u8 = 3;

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ScAuthWireMessageV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub kind: u8,
    pub reserved0: [u8; 7],
    pub proof: [u8; 32],
    pub challenge: [u8; 32],
    pub sealed_secret: [u8; 48],
    pub pairing_salt: [u8; 16],
    pub aead_nonce: [u8; 12],
    pub reserved1: [u8; 4],
}

impl fmt::Debug for ScAuthWireMessageV1 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ScAuthWireMessageV1")
            .field("struct_size", &self.struct_size)
            .field("api_version", &self.api_version)
            .field("kind", &self.kind)
            .field("sensitive", &"<redacted>")
            .finish()
    }
}

impl Zeroize for ScAuthWireMessageV1 {
    fn zeroize(&mut self) {
        self.struct_size.zeroize();
        self.api_version.zeroize();
        self.kind.zeroize();
        self.reserved0.zeroize();
        self.proof.zeroize();
        self.challenge.zeroize();
        self.sealed_secret.zeroize();
        self.pairing_salt.zeroize();
        self.aead_nonce.zeroize();
        self.reserved1.zeroize();
    }
}

fn decode_record(value: &ScAuthWireMessageV1) -> Option<AuthWireMessageV1> {
    if value.reserved0 != [0; 7] || value.reserved1 != [0; 4] {
        return None;
    }
    match value.kind {
        SC_AUTH_WIRE_KIND_AUTH
            if value.sealed_secret == [0; 48]
                && value.pairing_salt == [0; 16]
                && value.aead_nonce == [0; 12] =>
        {
            Some(AuthWireMessageV1::Auth {
                proof: value.proof,
                challenge: value.challenge,
            })
        }
        SC_AUTH_WIRE_KIND_AUTH_ACK
            if value.challenge == [0; 32]
                && value.sealed_secret == [0; 48]
                && value.pairing_salt == [0; 16]
                && value.aead_nonce == [0; 12] =>
        {
            Some(AuthWireMessageV1::AuthAck { proof: value.proof })
        }
        SC_AUTH_WIRE_KIND_PAIR_SECRET if value.proof == [0; 32] && value.challenge == [0; 32] => {
            Some(AuthWireMessageV1::PairSecret {
                sealed_secret: value.sealed_secret,
                pairing_salt: value.pairing_salt,
                aead_nonce: value.aead_nonce,
            })
        }
        _ => None,
    }
}

fn encode_record(struct_size: u32, value: AuthWireMessageV1) -> ScAuthWireMessageV1 {
    let mut output = ScAuthWireMessageV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        kind: 0,
        reserved0: [0; 7],
        proof: [0; 32],
        challenge: [0; 32],
        sealed_secret: [0; 48],
        pairing_salt: [0; 16],
        aead_nonce: [0; 12],
        reserved1: [0; 4],
    };
    match &value {
        AuthWireMessageV1::Auth { proof, challenge } => {
            output.kind = SC_AUTH_WIRE_KIND_AUTH;
            output.proof = *proof;
            output.challenge = *challenge;
        }
        AuthWireMessageV1::AuthAck { proof } => {
            output.kind = SC_AUTH_WIRE_KIND_AUTH_ACK;
            output.proof = *proof;
        }
        AuthWireMessageV1::PairSecret {
            sealed_secret,
            pairing_salt,
            aead_nonce,
        } => {
            output.kind = SC_AUTH_WIRE_KIND_PAIR_SECRET;
            output.sealed_secret = *sealed_secret;
            output.pairing_salt = *pairing_salt;
            output.aead_nonce = *aead_nonce;
        }
    }
    output
}

unsafe fn encode(
    input: *const ScAuthWireMessageV1,
    output: *mut u8,
    capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    if versioned_pointer_status(input) != SC_OK
        || needed.is_null()
        || (output.is_null() && capacity != 0)
    {
        return SC_INVALID_ARGUMENT;
    }
    let Some(input_range) = checked_byte_range(input.cast(), size_of::<ScAuthWireMessageV1>())
    else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(needed_range) = checked_byte_range(needed.cast(), size_of::<usize>()) else {
        return SC_INVALID_ARGUMENT;
    };
    // The public C record is POD. Keep the caller-owned bytes untouched and guard only the
    // complete local copy; a Rust Drop implementation on the FFI record would incorrectly imply
    // ownership of foreign storage.
    let input_copy = Zeroizing::new(input.read());
    let Some(value) = decode_record(&input_copy) else {
        return SC_INVALID_ARGUMENT;
    };
    let Ok(text) = encode_auth_wire_v1(value) else {
        return SC_INVALID_ARGUMENT;
    };
    let bytes = text.as_bytes();
    let Some(output_range) = checked_byte_range(output, capacity.min(bytes.len())) else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[input_range, needed_range, output_range]) {
        return SC_INVALID_ARGUMENT;
    }
    needed.write(bytes.len());
    if capacity < bytes.len() {
        return SC_BUFFER_TOO_SMALL;
    }
    ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
    SC_OK
}

unsafe fn decode(input: *const u8, length: usize, output: *mut ScAuthWireMessageV1) -> ScStatus {
    if length > AUTH_WIRE_MAX_BYTES_V1 || versioned_pointer_status(output) != SC_OK {
        return SC_INVALID_ARGUMENT;
    }
    let Some(input_range) = checked_byte_range(input, length) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = checked_byte_range(output.cast(), size_of::<ScAuthWireMessageV1>())
    else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[input_range, output_range]) {
        return SC_INVALID_ARGUMENT;
    }
    let bytes = if length == 0 {
        &[]
    } else {
        slice::from_raw_parts(input, length)
    };
    let Ok(value) = decode_auth_wire_v1(bytes) else {
        return SC_INVALID_ARGUMENT;
    };
    let struct_size = (*output).struct_size;
    let replacement = Zeroizing::new(encode_record(struct_size, value));
    // The C contract requires only the versioned header to be initialized on entry. Never read or
    // construct a Rust value from the old payload: overwrite the complete POD record, then let the
    // guarded local replacement wipe its own stack copy.
    ptr::copy_nonoverlapping((&*replacement) as *const ScAuthWireMessageV1, output, 1);
    SC_OK
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_wire_encode_v1(
    input: *const ScAuthWireMessageV1,
    output: *mut u8,
    capacity: usize,
    needed: *mut usize,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        encode(input, output, capacity, needed)
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_wire_decode_v1(
    input: *const u8,
    length: usize,
    output: *mut ScAuthWireMessageV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || decode(input, length, output))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::MaybeUninit;

    #[test]
    fn ffi_record_zeroize_clears_header_and_all_sensitive_storage() {
        let mut value = ScAuthWireMessageV1 {
            struct_size: size_of::<ScAuthWireMessageV1>() as u32,
            api_version: SC_API_VERSION_V1,
            kind: SC_AUTH_WIRE_KIND_AUTH,
            reserved0: [0x41; 7],
            proof: [0x42; 32],
            challenge: [0x43; 32],
            sealed_secret: [0x44; 48],
            pairing_salt: [0x45; 16],
            aead_nonce: [0x46; 12],
            reserved1: [0x47; 4],
        };
        assert!(format!("{value:?}").contains("<redacted>"));
        value.zeroize();
        assert_eq!(value.struct_size, 0);
        assert_eq!(value.api_version, 0);
        assert_eq!(value.kind, 0);
        assert_eq!(value.proof, [0; 32]);
        assert_eq!(value.challenge, [0; 32]);
        assert_eq!(value.sealed_secret, [0; 48]);
        assert_eq!(value.pairing_salt, [0; 16]);
        assert_eq!(value.aead_nonce, [0; 12]);
    }

    #[test]
    fn decode_accepts_header_only_initialized_output_without_reading_old_payload() {
        let input =
            br#"{"type":"auth_ack","proof":"ERERERERERERERERERERERERERERERERERERERERERE="}"#;
        let mut output = MaybeUninit::<ScAuthWireMessageV1>::uninit();
        let output_ptr = output.as_mut_ptr();
        unsafe {
            ptr::addr_of_mut!((*output_ptr).struct_size)
                .write(size_of::<ScAuthWireMessageV1>() as u32);
            ptr::addr_of_mut!((*output_ptr).api_version).write(SC_API_VERSION_V1);
            assert_eq!(decode(input.as_ptr(), input.len(), output_ptr), SC_OK);
            let mut initialized = output.assume_init();
            assert_eq!(initialized.kind, SC_AUTH_WIRE_KIND_AUTH_ACK);
            assert_eq!(initialized.proof, [0x11; 32]);
            assert_eq!(initialized.challenge, [0; 32]);
            initialized.zeroize();
        }
    }
}
