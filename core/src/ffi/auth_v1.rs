use std::mem::size_of;
use std::ptr;

use crate::auth_v1::{
    auth_proof, derive_pair_key, open_pair_secret, p256_public_key, seal_pair_secret,
    verify_auth_proof, AeadNonce, AuthNonce, AuthProof, AuthV1Error, P256PrivateScalar,
    P256PublicKey, PairKey, PairSecret, PairingSalt, PeerId, SealedPairSecret,
    MAX_PEER_ID_UTF8_BYTES,
};

use super::{
    byte_ranges_are_disjoint, checked_byte_range, ffi_guard, versioned_pointer_status, ScStatus,
    SC_API_VERSION_V1, SC_INTERNAL_ERROR, SC_INVALID_ARGUMENT, SC_OK,
};

pub const SC_AUTHENTICATION_FAILED: ScStatus = 100;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAuthPeerIdV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub length: u32,
    pub reserved: u32,
    pub bytes: [u8; MAX_PEER_ID_UTF8_BYTES],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthProofCreateRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub prover_id_length: u32,
    pub verifier_id_length: u32,
    pub reserved: [u32; 2],
    pub pair_secret: [u8; 32],
    pub nonce: [u8; 32],
    pub prover_id: [u8; MAX_PEER_ID_UTF8_BYTES],
    pub verifier_id: [u8; MAX_PEER_ID_UTF8_BYTES],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthProofVerifyRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub prover_id_length: u32,
    pub verifier_id_length: u32,
    pub reserved: [u32; 2],
    pub pair_secret: [u8; 32],
    pub nonce: [u8; 32],
    pub prover_id: [u8; MAX_PEER_ID_UTF8_BYTES],
    pub verifier_id: [u8; MAX_PEER_ID_UTF8_BYTES],
    pub proof: [u8; 32],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthP256PrivateRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub private_scalar: [u8; 32],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthPairKeyDeriveRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub private_scalar: [u8; 32],
    pub peer_public_key: [u8; 65],
    pub pairing_salt: [u8; 16],
    pub reserved: [u8; 7],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthSealRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub pair_secret: [u8; 32],
    pub pair_key: [u8; 32],
    pub nonce: [u8; 12],
    pub reserved: [u8; 4],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthOpenRequestV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub sealed_secret: [u8; 48],
    pub pair_key: [u8; 32],
    pub nonce: [u8; 12],
    pub reserved: [u8; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAuthProofV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub proof: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAuthP256PublicKeyV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub public_key: [u8; 65],
    pub reserved: [u8; 7],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthPairKeyV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub pair_key: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScAuthSealedPairSecretV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub sealed_secret: [u8; 48],
}

#[repr(C)]
#[derive(PartialEq, Eq)]
pub struct ScAuthPairSecretV1 {
    pub struct_size: u32,
    pub api_version: u32,
    pub pair_secret: [u8; 32],
}

fn pointer_range<T>(pointer: *const T) -> Option<(usize, usize)> {
    checked_byte_range(pointer.cast::<u8>(), size_of::<T>())
}

unsafe fn input_output_status<I, O>(input: *const I, output: *mut O) -> ScStatus {
    let status = versioned_pointer_status(input);
    if status != SC_OK {
        return status;
    }
    let status = versioned_pointer_status(output);
    if status != SC_OK {
        return status;
    }
    let Some(input_range) = pointer_range(input) else {
        return SC_INVALID_ARGUMENT;
    };
    let Some(output_range) = pointer_range(output) else {
        return SC_INVALID_ARGUMENT;
    };
    if !byte_ranges_are_disjoint(&[input_range, output_range]) {
        return SC_INVALID_ARGUMENT;
    }
    SC_OK
}

fn peer_id(length: u32, bytes: &[u8; MAX_PEER_ID_UTF8_BYTES]) -> Option<PeerId> {
    let length = usize::try_from(length).ok()?;
    if length == 0
        || length > MAX_PEER_ID_UTF8_BYTES
        || bytes[length..].iter().any(|value| *value != 0)
    {
        return None;
    }
    PeerId::try_from(&bytes[..length]).ok()
}

fn proof_inputs(
    prover_length: u32,
    verifier_length: u32,
    prover: &[u8; MAX_PEER_ID_UTF8_BYTES],
    verifier: &[u8; MAX_PEER_ID_UTF8_BYTES],
) -> Option<(PeerId, PeerId)> {
    Some((
        peer_id(prover_length, prover)?,
        peer_id(verifier_length, verifier)?,
    ))
}

fn internal_or_invalid(error: AuthV1Error) -> ScStatus {
    match error {
        AuthV1Error::InvalidLength { .. }
        | AuthV1Error::EmptyPeerId
        | AuthV1Error::PeerIdTooLong
        | AuthV1Error::InvalidPeerIdUtf8
        | AuthV1Error::PeerIdContainsDelimiter
        | AuthV1Error::PeerIdContainsControl
        | AuthV1Error::InvalidPrivateScalar
        | AuthV1Error::InvalidPublicKey => SC_INVALID_ARGUMENT,
        AuthV1Error::ContextOverflow
        | AuthV1Error::HmacInitializationFailed
        | AuthV1Error::KeyDerivationFailed
        | AuthV1Error::SealFailed
        | AuthV1Error::OpenFailed => SC_INTERNAL_ERROR,
    }
}

unsafe fn write_secret_32(output: *mut ScAuthPairSecretV1, struct_size: u32, secret: &[u8; 32]) {
    ptr::addr_of_mut!((*output).struct_size).write(struct_size);
    ptr::addr_of_mut!((*output).api_version).write(SC_API_VERSION_V1);
    ptr::copy_nonoverlapping(
        secret.as_ptr(),
        ptr::addr_of_mut!((*output).pair_secret).cast::<u8>(),
        secret.len(),
    );
}

unsafe fn write_pair_key(output: *mut ScAuthPairKeyV1, struct_size: u32, key: &[u8; 32]) {
    ptr::addr_of_mut!((*output).struct_size).write(struct_size);
    ptr::addr_of_mut!((*output).api_version).write(SC_API_VERSION_V1);
    ptr::copy_nonoverlapping(
        key.as_ptr(),
        ptr::addr_of_mut!((*output).pair_key).cast::<u8>(),
        key.len(),
    );
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_peer_id_validate_v1(input: *const ScAuthPeerIdV1) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(input);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != 0 || peer_id(input.length, &input.bytes).is_none() {
            return SC_INVALID_ARGUMENT;
        }
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_proof_create_v1(
    input: *const ScAuthProofCreateRequestV1,
    output: *mut ScAuthProofV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = input_output_status(input, output);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != [0; 2] {
            return SC_INVALID_ARGUMENT;
        }
        let Some((prover, verifier)) = proof_inputs(
            input.prover_id_length,
            input.verifier_id_length,
            &input.prover_id,
            &input.verifier_id,
        ) else {
            return SC_INVALID_ARGUMENT;
        };
        let secret = match PairSecret::try_from(input.pair_secret.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let nonce = match AuthNonce::try_from(input.nonce.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let proof = match auth_proof(&secret, &prover, &verifier, &nonce) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScAuthProofV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            proof: *proof.as_bytes(),
        });
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_proof_verify_v1(
    input: *const ScAuthProofVerifyRequestV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = versioned_pointer_status(input);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != [0; 2] {
            return SC_INVALID_ARGUMENT;
        }
        let Some((prover, verifier)) = proof_inputs(
            input.prover_id_length,
            input.verifier_id_length,
            &input.prover_id,
            &input.verifier_id,
        ) else {
            return SC_INVALID_ARGUMENT;
        };
        let secret = match PairSecret::try_from(input.pair_secret.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let nonce = match AuthNonce::try_from(input.nonce.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let proof = match AuthProof::try_from(input.proof.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        if verify_auth_proof(&proof, &secret, &prover, &verifier, &nonce) {
            SC_OK
        } else {
            SC_AUTHENTICATION_FAILED
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_p256_public_from_private_v1(
    input: *const ScAuthP256PrivateRequestV1,
    output: *mut ScAuthP256PublicKeyV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = input_output_status(input, output);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        let private = match P256PrivateScalar::try_from(input.private_scalar.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let public = p256_public_key(&private);
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScAuthP256PublicKeyV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            public_key: *public.as_bytes(),
            reserved: [0; 7],
        });
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_pair_key_derive_v1(
    input: *const ScAuthPairKeyDeriveRequestV1,
    output: *mut ScAuthPairKeyV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = input_output_status(input, output);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != [0; 7] {
            return SC_INVALID_ARGUMENT;
        }
        let private = match P256PrivateScalar::try_from(input.private_scalar.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let public = match P256PublicKey::try_from(input.peer_public_key.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let salt = match PairingSalt::try_from(input.pairing_salt.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let pair_key = match derive_pair_key(&private, &public, &salt) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        write_pair_key(output, struct_size, pair_key.as_bytes());
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_pair_secret_seal_v1(
    input: *const ScAuthSealRequestV1,
    output: *mut ScAuthSealedPairSecretV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = input_output_status(input, output);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != [0; 4] {
            return SC_INVALID_ARGUMENT;
        }
        let secret = match PairSecret::try_from(input.pair_secret.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let key = match PairKey::try_from(input.pair_key.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let nonce = match AeadNonce::try_from(input.nonce.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let sealed = match seal_pair_secret(&secret, &key, &nonce) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        output.write(ScAuthSealedPairSecretV1 {
            struct_size,
            api_version: SC_API_VERSION_V1,
            sealed_secret: *sealed.as_bytes(),
        });
        SC_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn sc_auth_pair_secret_open_v1(
    input: *const ScAuthOpenRequestV1,
    output: *mut ScAuthPairSecretV1,
) -> ScStatus {
    ffi_guard(SC_INTERNAL_ERROR, || {
        let status = input_output_status(input, output);
        if status != SC_OK {
            return status;
        }
        let input = &*input;
        if input.reserved != [0; 4] {
            return SC_INVALID_ARGUMENT;
        }
        let sealed = match SealedPairSecret::try_from(input.sealed_secret.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let key = match PairKey::try_from(input.pair_key.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let nonce = match AeadNonce::try_from(input.nonce.as_slice()) {
            Ok(value) => value,
            Err(error) => return internal_or_invalid(error),
        };
        let secret = match open_pair_secret(&sealed, &key, &nonce) {
            Ok(value) => value,
            Err(AuthV1Error::OpenFailed) => return SC_AUTHENTICATION_FAILED,
            Err(error) => return internal_or_invalid(error),
        };
        let struct_size = output.cast::<u32>().read_unaligned();
        write_secret_32(output, struct_size, secret.as_bytes());
        SC_OK
    })
}
