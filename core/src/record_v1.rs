//! SC-RECORD-v1 authenticated record layer.
//!
//! This module owns no socket and no platform secret store. A host creates one
//! sealer and one opener per authenticated direction/session, then moves the
//! returned bytes over TCP or UDP. Keys, counters, and replay windows are
//! separated by direction and record type, so CONTROL ordering cannot be
//! invalidated by independently delivered VIDEO. Record headers are
//! authenticated as AAD; each type accepts only counters above its highest
//! authenticated counter so replay and late reordering fail closed.

use aes_gcm::{
    aead::{array::Array, AeadInOut, KeyInit},
    Aes256Gcm,
};
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::auth_v1::PeerId;

pub const RECORD_KEY_BYTES: usize = 32;
pub const RECORD_CONTEXT_BYTES: usize = 32;
pub const RECORD_CHALLENGE_BYTES: usize = 32;
pub const RECORD_NONCE_BYTES: usize = 12;
pub const RECORD_TAG_BYTES: usize = 16;
pub const RECORD_HEADER_BYTES: usize = 32;
pub const RECORD_OVERHEAD_BYTES: usize = RECORD_HEADER_BYTES + RECORD_TAG_BYTES;
pub const MAX_RECORD_PLAINTEXT: usize = 16 * 1024 * 1024;

const RECORD_MAGIC: [u8; 4] = *b"SCR1";
const RECORD_VERSION: u8 = 1;
const RECORD_LABEL: &[u8] = b"SC-RECORD-v1";
const RECORD_CONTEXT_LABEL: &[u8] = b"SC-RECORD-CONTEXT-v1\0";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum RecordDirection {
    InitiatorToResponder = 1,
    ResponderToInitiator = 2,
}

impl TryFrom<u8> for RecordDirection {
    type Error = RecordError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::InitiatorToResponder),
            2 => Ok(Self::ResponderToInitiator),
            _ => Err(RecordError::InvalidDirection),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum RecordType {
    Control = 1,
    Video = 2,
    Input = 3,
}

impl TryFrom<u8> for RecordType {
    type Error = RecordError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Control),
            2 => Ok(Self::Video),
            3 => Ok(Self::Input),
            _ => Err(RecordError::InvalidRecordType),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RecordMetadata {
    pub record_type: RecordType,
    pub direction: RecordDirection,
    pub flags: u8,
    pub session_generation: u64,
    pub counter: u64,
    pub plaintext_length: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RecordSessionContext {
    pub bytes: [u8; RECORD_CONTEXT_BYTES],
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecordError {
    InvalidSecret,
    InvalidContext,
    InvalidDirection,
    InvalidRecordType,
    InvalidGeneration,
    InvalidMaximum,
    PlaintextTooLarge,
    LengthOverflow,
    InvalidRecord,
    WrongDirection,
    WrongGeneration,
    ReplayOrReorder,
    CounterExhausted,
    KeyDerivationFailed,
    SealFailed,
    AuthenticationFailed,
}

struct RecordKey([u8; RECORD_KEY_BYTES]);

impl Drop for RecordKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

pub fn derive_session_context(
    initiator_peer_id: &[u8],
    responder_peer_id: &[u8],
    responder_challenge: &[u8],
    initiator_challenge: &[u8],
) -> Result<RecordSessionContext, RecordError> {
    let initiator = PeerId::try_from(initiator_peer_id).map_err(|_| RecordError::InvalidContext)?;
    let responder = PeerId::try_from(responder_peer_id).map_err(|_| RecordError::InvalidContext)?;
    if responder_challenge.len() != RECORD_CHALLENGE_BYTES
        || initiator_challenge.len() != RECORD_CHALLENGE_BYTES
        || responder_challenge.iter().all(|value| *value == 0)
        || initiator_challenge.iter().all(|value| *value == 0)
    {
        return Err(RecordError::InvalidContext);
    }
    let mut hash = Sha256::new();
    hash.update(RECORD_CONTEXT_LABEL);
    hash.update((initiator.as_bytes().len() as u16).to_le_bytes());
    hash.update(initiator.as_bytes());
    hash.update((responder.as_bytes().len() as u16).to_le_bytes());
    hash.update(responder.as_bytes());
    hash.update(responder_challenge);
    hash.update(initiator_challenge);
    let bytes: [u8; RECORD_CONTEXT_BYTES] = hash.finalize().into();
    let mut generation = u64::from_le_bytes(bytes[..8].try_into().unwrap());
    if generation == 0 {
        generation = 1;
    }
    Ok(RecordSessionContext { bytes, generation })
}

fn derive_key(
    pair_secret: &[u8],
    context: &[u8],
    direction: RecordDirection,
    record_type: RecordType,
    generation: u64,
) -> Result<RecordKey, RecordError> {
    if pair_secret.len() != RECORD_KEY_BYTES || pair_secret.iter().all(|value| *value == 0) {
        return Err(RecordError::InvalidSecret);
    }
    if context.len() != RECORD_CONTEXT_BYTES || context.iter().all(|value| *value == 0) {
        return Err(RecordError::InvalidContext);
    }
    if generation == 0 {
        return Err(RecordError::InvalidGeneration);
    }
    let mut info = [0_u8; 24];
    info[..RECORD_LABEL.len()].copy_from_slice(RECORD_LABEL);
    info[RECORD_LABEL.len()] = 0;
    info[RECORD_LABEL.len() + 1] = direction as u8;
    info[RECORD_LABEL.len() + 2] = record_type as u8;
    info[16..24].copy_from_slice(&generation.to_le_bytes());
    let hkdf = Hkdf::<Sha256>::new(Some(context), pair_secret);
    let mut key = Zeroizing::new([0_u8; RECORD_KEY_BYTES]);
    hkdf.expand(&info, &mut key[..])
        .map_err(|_| RecordError::KeyDerivationFailed)?;
    Ok(RecordKey(*key))
}

struct RecordKeys {
    control: RecordKey,
    video: RecordKey,
    input: RecordKey,
}

impl RecordKeys {
    fn new(
        pair_secret: &[u8],
        context: &[u8],
        direction: RecordDirection,
        generation: u64,
    ) -> Result<Self, RecordError> {
        Ok(Self {
            control: derive_key(
                pair_secret,
                context,
                direction,
                RecordType::Control,
                generation,
            )?,
            video: derive_key(
                pair_secret,
                context,
                direction,
                RecordType::Video,
                generation,
            )?,
            input: derive_key(
                pair_secret,
                context,
                direction,
                RecordType::Input,
                generation,
            )?,
        })
    }

    fn get(&self, record_type: RecordType) -> &RecordKey {
        match record_type {
            RecordType::Control => &self.control,
            RecordType::Video => &self.video,
            RecordType::Input => &self.input,
        }
    }
}

fn type_index(record_type: RecordType) -> usize {
    record_type as usize - 1
}

fn require_maximum(max_plaintext: usize) -> Result<usize, RecordError> {
    if (1..=MAX_RECORD_PLAINTEXT).contains(&max_plaintext) {
        Ok(max_plaintext)
    } else {
        Err(RecordError::InvalidMaximum)
    }
}

fn nonce(counter: u64) -> [u8; RECORD_NONCE_BYTES] {
    let mut value = [0_u8; RECORD_NONCE_BYTES];
    value[4..].copy_from_slice(&counter.to_be_bytes());
    value
}

fn header(metadata: RecordMetadata) -> Result<[u8; RECORD_HEADER_BYTES], RecordError> {
    let length =
        u32::try_from(metadata.plaintext_length).map_err(|_| RecordError::LengthOverflow)?;
    let mut output = [0_u8; RECORD_HEADER_BYTES];
    output[..4].copy_from_slice(&RECORD_MAGIC);
    output[4] = RECORD_VERSION;
    output[5] = metadata.record_type as u8;
    output[6] = metadata.direction as u8;
    output[7] = metadata.flags;
    output[8..16].copy_from_slice(&metadata.session_generation.to_le_bytes());
    output[16..24].copy_from_slice(&metadata.counter.to_le_bytes());
    output[24..28].copy_from_slice(&length.to_le_bytes());
    Ok(output)
}

fn parse_header(value: &[u8]) -> Result<RecordMetadata, RecordError> {
    let source: &[u8; RECORD_HEADER_BYTES] = value
        .get(..RECORD_HEADER_BYTES)
        .ok_or(RecordError::InvalidRecord)?
        .try_into()
        .map_err(|_| RecordError::InvalidRecord)?;
    if source[..4] != RECORD_MAGIC || source[4] != RECORD_VERSION || source[28..32] != [0; 4] {
        return Err(RecordError::InvalidRecord);
    }
    let record_type = RecordType::try_from(source[5])?;
    let direction = RecordDirection::try_from(source[6])?;
    let generation = u64::from_le_bytes(source[8..16].try_into().unwrap());
    let counter = u64::from_le_bytes(source[16..24].try_into().unwrap());
    let plaintext_length = u32::from_le_bytes(source[24..28].try_into().unwrap()) as usize;
    if generation == 0 || counter == 0 {
        return Err(RecordError::InvalidRecord);
    }
    Ok(RecordMetadata {
        record_type,
        direction,
        flags: source[7],
        session_generation: generation,
        counter,
        plaintext_length,
    })
}

pub struct RecordSealer {
    keys: RecordKeys,
    direction: RecordDirection,
    generation: u64,
    max_plaintext: usize,
    next_counters: [u64; 3],
}

impl RecordSealer {
    pub fn new(
        pair_secret: &[u8],
        context: &[u8],
        direction: RecordDirection,
        generation: u64,
        max_plaintext: usize,
    ) -> Result<Self, RecordError> {
        Ok(Self {
            keys: RecordKeys::new(pair_secret, context, direction, generation)?,
            direction,
            generation,
            max_plaintext: require_maximum(max_plaintext)?,
            next_counters: [1; 3],
        })
    }

    pub fn required_length(&self, plaintext_length: usize) -> Result<usize, RecordError> {
        if plaintext_length > self.max_plaintext {
            return Err(RecordError::PlaintextTooLarge);
        }
        plaintext_length
            .checked_add(RECORD_OVERHEAD_BYTES)
            .ok_or(RecordError::LengthOverflow)
    }

    pub fn seal(
        &mut self,
        record_type: RecordType,
        flags: u8,
        plaintext: &[u8],
    ) -> Result<(RecordMetadata, Vec<u8>), RecordError> {
        let required = self.required_length(plaintext.len())?;
        let index = type_index(record_type);
        let counter = self.next_counters[index];
        if counter == 0 {
            return Err(RecordError::CounterExhausted);
        }
        let metadata = RecordMetadata {
            record_type,
            direction: self.direction,
            flags,
            session_generation: self.generation,
            counter,
            plaintext_length: plaintext.len(),
        };
        let aad = header(metadata)?;
        let mut output = Zeroizing::new(vec![0_u8; required]);
        output[..RECORD_HEADER_BYTES].copy_from_slice(&aad);
        let ciphertext_end = RECORD_HEADER_BYTES + plaintext.len();
        output[RECORD_HEADER_BYTES..ciphertext_end].copy_from_slice(plaintext);
        let mut cipher_key = Array(self.keys.get(record_type).0);
        let cipher = Aes256Gcm::new(&cipher_key);
        cipher_key.as_mut_slice().zeroize();
        let nonce_bytes = nonce(counter);
        let tag = cipher
            .encrypt_inout_detached(
                &Array(nonce_bytes),
                &aad,
                (&mut output[RECORD_HEADER_BYTES..ciphertext_end]).into(),
            )
            .map_err(|_| RecordError::SealFailed)?;
        output[ciphertext_end..].copy_from_slice(&tag);
        self.next_counters[index] = counter.wrapping_add(1);
        Ok((metadata, core::mem::take(&mut *output)))
    }
}

pub struct RecordOpener {
    keys: RecordKeys,
    direction: RecordDirection,
    generation: u64,
    max_plaintext: usize,
    highest_counters: [u64; 3],
}

impl RecordOpener {
    pub fn new(
        pair_secret: &[u8],
        context: &[u8],
        direction: RecordDirection,
        generation: u64,
        max_plaintext: usize,
    ) -> Result<Self, RecordError> {
        Ok(Self {
            keys: RecordKeys::new(pair_secret, context, direction, generation)?,
            direction,
            generation,
            max_plaintext: require_maximum(max_plaintext)?,
            highest_counters: [0; 3],
        })
    }

    pub fn plaintext_length(&self, record: &[u8]) -> Result<usize, RecordError> {
        Ok(self.inspect(record)?.plaintext_length)
    }

    pub fn inspect(&self, record: &[u8]) -> Result<RecordMetadata, RecordError> {
        self.validate_envelope(record)
    }

    fn validate_envelope(&self, record: &[u8]) -> Result<RecordMetadata, RecordError> {
        let metadata = parse_header(record)?;
        if metadata.direction != self.direction {
            return Err(RecordError::WrongDirection);
        }
        if metadata.session_generation != self.generation {
            return Err(RecordError::WrongGeneration);
        }
        if metadata.counter <= self.highest_counters[type_index(metadata.record_type)] {
            return Err(RecordError::ReplayOrReorder);
        }
        if metadata.plaintext_length > self.max_plaintext {
            return Err(RecordError::PlaintextTooLarge);
        }
        let expected = metadata
            .plaintext_length
            .checked_add(RECORD_OVERHEAD_BYTES)
            .ok_or(RecordError::LengthOverflow)?;
        if record.len() != expected {
            return Err(RecordError::InvalidRecord);
        }
        Ok(metadata)
    }

    pub fn open(&mut self, record: &[u8]) -> Result<(RecordMetadata, Vec<u8>), RecordError> {
        let metadata = self.validate_envelope(record)?;
        let aad: &[u8; RECORD_HEADER_BYTES] = record[..RECORD_HEADER_BYTES]
            .try_into()
            .map_err(|_| RecordError::InvalidRecord)?;
        let ciphertext_end = RECORD_HEADER_BYTES + metadata.plaintext_length;
        let mut plaintext = Zeroizing::new(record[RECORD_HEADER_BYTES..ciphertext_end].to_vec());
        let tag = Array(
            record[ciphertext_end..]
                .try_into()
                .map_err(|_| RecordError::InvalidRecord)?,
        );
        let mut cipher_key = Array(self.keys.get(metadata.record_type).0);
        let cipher = Aes256Gcm::new(&cipher_key);
        cipher_key.as_mut_slice().zeroize();
        let nonce_bytes = nonce(metadata.counter);
        cipher
            .decrypt_inout_detached(
                &Array(nonce_bytes),
                aad,
                plaintext.as_mut_slice().into(),
                &tag,
            )
            .map_err(|_| RecordError::AuthenticationFailed)?;
        self.highest_counters[type_index(metadata.record_type)] = metadata.counter;
        Ok((metadata, core::mem::take(&mut *plaintext)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_exhaustion_fails_closed() {
        let mut sealer = RecordSealer::new(
            &[0x11; RECORD_KEY_BYTES],
            &[0x22; RECORD_CONTEXT_BYTES],
            RecordDirection::InitiatorToResponder,
            7,
            1,
        )
        .unwrap();
        sealer.next_counters[type_index(RecordType::Control)] = u64::MAX;
        let (metadata, _) = sealer.seal(RecordType::Control, 0, &[]).unwrap();
        assert_eq!(metadata.counter, u64::MAX);
        assert_eq!(
            sealer.seal(RecordType::Control, 0, &[]),
            Err(RecordError::CounterExhausted)
        );
    }
}
