use aes_gcm::{
    aead::{array::Array, AeadInOut, KeyInit},
    Aes256Gcm,
};
use core::fmt;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use p256::{ecdh::diffie_hellman, elliptic_curve::sec1::ToEncodedPoint, PublicKey, SecretKey};
use sha2::Sha256;
use zeroize::{Zeroize, Zeroizing};

pub const MAX_PEER_ID_UTF8_BYTES: usize = 128;
pub const PAIR_SECRET_BYTES: usize = 32;
pub const AUTH_NONCE_BYTES: usize = 32;
pub const AUTH_PROOF_BYTES: usize = 32;
pub const P256_PRIVATE_SCALAR_BYTES: usize = 32;
pub const P256_PUBLIC_KEY_BYTES: usize = 65;
pub const PAIRING_SALT_BYTES: usize = 16;
pub const AEAD_NONCE_BYTES: usize = 12;
pub const PAIR_KEY_BYTES: usize = 32;
pub const SEALED_PAIR_SECRET_BYTES: usize = 48;

const AUTH_LABEL: &[u8] = b"SC-AUTH-v1";
const PAIR_INFO: &[u8] = b"SC-PAIR-v1";
const BASE64_NONCE_BYTES: usize = 44;
const AUTH_CONTEXT_BYTES: usize =
    AUTH_LABEL.len() + 3 + MAX_PEER_ID_UTF8_BYTES * 2 + BASE64_NONCE_BYTES;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthField {
    PairSecret,
    AuthNonce,
    AuthProof,
    P256PrivateScalar,
    P256PublicKey,
    PairingSalt,
    AeadNonce,
    PairKey,
    SealedPairSecret,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthV1Error {
    InvalidLength {
        field: AuthField,
        expected: usize,
        actual: usize,
    },
    EmptyPeerId,
    PeerIdTooLong,
    InvalidPeerIdUtf8,
    PeerIdContainsDelimiter,
    PeerIdContainsControl,
    InvalidPrivateScalar,
    InvalidPublicKey,
    ContextOverflow,
    HmacInitializationFailed,
    KeyDerivationFailed,
    SealFailed,
    OpenFailed,
}

fn require_length(value: &[u8], field: AuthField, expected: usize) -> Result<(), AuthV1Error> {
    if value.len() == expected {
        Ok(())
    } else {
        Err(AuthV1Error::InvalidLength {
            field,
            expected,
            actual: value.len(),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PeerId {
    bytes: [u8; MAX_PEER_ID_UTF8_BYTES],
    len: u8,
}

impl PeerId {
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..usize::from(self.len)]
    }
}

impl TryFrom<&str> for PeerId {
    type Error = AuthV1Error;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.as_bytes())
    }
}

impl TryFrom<&[u8]> for PeerId {
    type Error = AuthV1Error;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        if value.is_empty() {
            return Err(AuthV1Error::EmptyPeerId);
        }
        if value.len() > MAX_PEER_ID_UTF8_BYTES {
            return Err(AuthV1Error::PeerIdTooLong);
        }
        let text = core::str::from_utf8(value).map_err(|_| AuthV1Error::InvalidPeerIdUtf8)?;
        if text.contains('|') {
            return Err(AuthV1Error::PeerIdContainsDelimiter);
        }
        if text.chars().any(|character| {
            let scalar = u32::from(character);
            scalar <= 0x1f || (0x7f..=0x9f).contains(&scalar)
        }) {
            return Err(AuthV1Error::PeerIdContainsControl);
        }

        let len = u8::try_from(value.len()).map_err(|_| AuthV1Error::PeerIdTooLong)?;
        let mut bytes = [0_u8; MAX_PEER_ID_UTF8_BYTES];
        bytes[..value.len()].copy_from_slice(value);
        Ok(Self { bytes, len })
    }
}

pub struct AuthContext {
    bytes: [u8; AUTH_CONTEXT_BYTES],
    len: u16,
}

impl AuthContext {
    fn empty() -> Self {
        Self {
            bytes: [0_u8; AUTH_CONTEXT_BYTES],
            len: 0,
        }
    }

    fn append(&mut self, value: &[u8]) -> Result<(), AuthV1Error> {
        let start = usize::from(self.len);
        let end = start
            .checked_add(value.len())
            .ok_or(AuthV1Error::ContextOverflow)?;
        let destination = self
            .bytes
            .get_mut(start..end)
            .ok_or(AuthV1Error::ContextOverflow)?;
        destination.copy_from_slice(value);
        self.len = u16::try_from(end).map_err(|_| AuthV1Error::ContextOverflow)?;
        Ok(())
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..usize::from(self.len)]
    }
}

pub struct PairSecret([u8; PAIR_SECRET_BYTES]);

impl PairSecret {
    pub fn as_bytes(&self) -> &[u8; PAIR_SECRET_BYTES] {
        &self.0
    }
}

impl TryFrom<&[u8]> for PairSecret {
    type Error = AuthV1Error;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        require_length(value, AuthField::PairSecret, PAIR_SECRET_BYTES)?;
        let mut bytes = [0_u8; PAIR_SECRET_BYTES];
        bytes.copy_from_slice(value);
        Ok(Self(bytes))
    }
}

impl Drop for PairSecret {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl fmt::Debug for PairSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PairSecret(REDACTED)")
    }
}

macro_rules! fixed_public_bytes {
    ($name:ident, $size:ident, $field:ident) => {
        pub struct $name([u8; $size]);

        impl $name {
            pub fn as_bytes(&self) -> &[u8; $size] {
                &self.0
            }
        }

        impl TryFrom<&[u8]> for $name {
            type Error = AuthV1Error;

            fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
                require_length(value, AuthField::$field, $size)?;
                let mut bytes = [0_u8; $size];
                bytes.copy_from_slice(value);
                Ok(Self(bytes))
            }
        }
    };
}

fixed_public_bytes!(AuthNonce, AUTH_NONCE_BYTES, AuthNonce);
fixed_public_bytes!(AuthProof, AUTH_PROOF_BYTES, AuthProof);
fixed_public_bytes!(PairingSalt, PAIRING_SALT_BYTES, PairingSalt);
fixed_public_bytes!(AeadNonce, AEAD_NONCE_BYTES, AeadNonce);
fixed_public_bytes!(SealedPairSecret, SEALED_PAIR_SECRET_BYTES, SealedPairSecret);

pub struct P256PrivateScalar(SecretKey);

impl TryFrom<&[u8]> for P256PrivateScalar {
    type Error = AuthV1Error;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        require_length(
            value,
            AuthField::P256PrivateScalar,
            P256_PRIVATE_SCALAR_BYTES,
        )?;
        SecretKey::from_slice(value)
            .map(Self)
            .map_err(|_| AuthV1Error::InvalidPrivateScalar)
    }
}

impl fmt::Debug for P256PrivateScalar {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("P256PrivateScalar(REDACTED)")
    }
}

pub struct P256PublicKey([u8; P256_PUBLIC_KEY_BYTES]);

impl P256PublicKey {
    pub fn as_bytes(&self) -> &[u8; P256_PUBLIC_KEY_BYTES] {
        &self.0
    }
}

impl TryFrom<&[u8]> for P256PublicKey {
    type Error = AuthV1Error;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        require_length(value, AuthField::P256PublicKey, P256_PUBLIC_KEY_BYTES)?;
        if value.first() != Some(&0x04) || PublicKey::from_sec1_bytes(value).is_err() {
            return Err(AuthV1Error::InvalidPublicKey);
        }
        let mut bytes = [0_u8; P256_PUBLIC_KEY_BYTES];
        bytes.copy_from_slice(value);
        Ok(Self(bytes))
    }
}

pub struct PairKey([u8; PAIR_KEY_BYTES]);

impl PairKey {
    pub fn as_bytes(&self) -> &[u8; PAIR_KEY_BYTES] {
        &self.0
    }
}

impl TryFrom<&[u8]> for PairKey {
    type Error = AuthV1Error;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        require_length(value, AuthField::PairKey, PAIR_KEY_BYTES)?;
        let mut bytes = [0_u8; PAIR_KEY_BYTES];
        bytes.copy_from_slice(value);
        Ok(Self(bytes))
    }
}

impl Drop for PairKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl fmt::Debug for PairKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PairKey(REDACTED)")
    }
}

fn base64_nonce(nonce: &AuthNonce) -> [u8; BASE64_NONCE_BYTES] {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let input = nonce.as_bytes();
    let mut output = [0_u8; BASE64_NONCE_BYTES];
    let mut input_index = 0;
    let mut output_index = 0;
    while input_index + 3 <= 30 {
        let a = input[input_index];
        let b = input[input_index + 1];
        let c = input[input_index + 2];
        output[output_index] = TABLE[usize::from(a >> 2)];
        output[output_index + 1] = TABLE[usize::from(((a & 0x03) << 4) | (b >> 4))];
        output[output_index + 2] = TABLE[usize::from(((b & 0x0f) << 2) | (c >> 6))];
        output[output_index + 3] = TABLE[usize::from(c & 0x3f)];
        input_index += 3;
        output_index += 4;
    }
    let a = input[30];
    let b = input[31];
    output[40] = TABLE[usize::from(a >> 2)];
    output[41] = TABLE[usize::from(((a & 0x03) << 4) | (b >> 4))];
    output[42] = TABLE[usize::from((b & 0x0f) << 2)];
    output[43] = b'=';
    output
}

pub fn auth_context(
    prover: &PeerId,
    verifier: &PeerId,
    nonce: &AuthNonce,
) -> Result<AuthContext, AuthV1Error> {
    let nonce_base64 = base64_nonce(nonce);
    let mut context = AuthContext::empty();
    context.append(AUTH_LABEL)?;
    context.append(b"|")?;
    context.append(prover.as_bytes())?;
    context.append(b"|")?;
    context.append(verifier.as_bytes())?;
    context.append(b"|")?;
    context.append(&nonce_base64)?;
    Ok(context)
}

pub fn auth_proof(
    secret: &PairSecret,
    prover: &PeerId,
    verifier: &PeerId,
    nonce: &AuthNonce,
) -> Result<AuthProof, AuthV1Error> {
    let context = auth_context(prover, verifier, nonce)?;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .map_err(|_| AuthV1Error::HmacInitializationFailed)?;
    mac.update(context.as_bytes());
    let output = mac.finalize().into_bytes();
    let mut proof = [0_u8; AUTH_PROOF_BYTES];
    proof.copy_from_slice(&output);
    Ok(AuthProof(proof))
}

pub fn verify_auth_proof(
    proof: &AuthProof,
    secret: &PairSecret,
    prover: &PeerId,
    verifier: &PeerId,
    nonce: &AuthNonce,
) -> bool {
    let Ok(context) = auth_context(prover, verifier, nonce) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(context.as_bytes());
    mac.verify_slice(proof.as_bytes()).is_ok()
}

pub fn p256_public_key(private: &P256PrivateScalar) -> P256PublicKey {
    let encoded = private.0.public_key().to_encoded_point(false);
    let mut output = [0_u8; P256_PUBLIC_KEY_BYTES];
    output.copy_from_slice(encoded.as_bytes());
    P256PublicKey(output)
}

pub fn derive_pair_key(
    private: &P256PrivateScalar,
    peer_public: &P256PublicKey,
    salt: &PairingSalt,
) -> Result<PairKey, AuthV1Error> {
    let peer = PublicKey::from_sec1_bytes(peer_public.as_bytes())
        .map_err(|_| AuthV1Error::InvalidPublicKey)?;
    let shared = diffie_hellman(private.0.to_nonzero_scalar(), peer.as_affine());
    let hkdf = Hkdf::<Sha256>::new(Some(salt.as_bytes()), shared.raw_secret_bytes());
    let mut output = Zeroizing::new([0_u8; PAIR_KEY_BYTES]);
    hkdf.expand(PAIR_INFO, &mut output[..])
        .map_err(|_| AuthV1Error::KeyDerivationFailed)?;
    Ok(PairKey(*output))
}

pub fn seal_pair_secret(
    secret: &PairSecret,
    key: &PairKey,
    nonce: &AeadNonce,
) -> Result<SealedPairSecret, AuthV1Error> {
    let mut cipher_key = Array(*key.as_bytes());
    let cipher = Aes256Gcm::new(&cipher_key);
    cipher_key.as_mut_slice().zeroize();
    let nonce = Array(*nonce.as_bytes());
    let mut ciphertext = Zeroizing::new(*secret.as_bytes());
    let tag = cipher
        .encrypt_inout_detached(&nonce, PAIR_INFO, ciphertext.as_mut_slice().into())
        .map_err(|_| AuthV1Error::SealFailed)?;
    let mut output = [0_u8; SEALED_PAIR_SECRET_BYTES];
    output[..PAIR_SECRET_BYTES].copy_from_slice(&ciphertext[..]);
    output[PAIR_SECRET_BYTES..].copy_from_slice(&tag);
    Ok(SealedPairSecret(output))
}

pub fn open_pair_secret(
    sealed: &SealedPairSecret,
    key: &PairKey,
    nonce: &AeadNonce,
) -> Result<PairSecret, AuthV1Error> {
    let mut cipher_key = Array(*key.as_bytes());
    let cipher = Aes256Gcm::new(&cipher_key);
    cipher_key.as_mut_slice().zeroize();
    let nonce = Array(*nonce.as_bytes());
    let mut plaintext = Zeroizing::new([0_u8; PAIR_SECRET_BYTES]);
    plaintext.copy_from_slice(&sealed.as_bytes()[..PAIR_SECRET_BYTES]);
    let mut tag_bytes = [0_u8; SEALED_PAIR_SECRET_BYTES - PAIR_SECRET_BYTES];
    tag_bytes.copy_from_slice(&sealed.as_bytes()[PAIR_SECRET_BYTES..]);
    let tag = Array(tag_bytes);
    if cipher
        .decrypt_inout_detached(&nonce, PAIR_INFO, plaintext.as_mut_slice().into(), &tag)
        .is_err()
    {
        return Err(AuthV1Error::OpenFailed);
    }
    Ok(PairSecret(*plaintext))
}
