use std::mem::size_of;

use crate::secure_connection::{
    SecureConnectionConfig, SecureConnectionEffect, SecureConnectionError, SecureRecordMaterial,
    SecureRecordPhase, MAX_SECURE_PLAINTEXT,
};

use super::super::control_envelope::encode_control_envelope_record;
use super::super::session::{decode_config, encode_effect};
use super::super::{
    ScStatus, SC_API_VERSION_V1, SC_INVALID_ARGUMENT, SC_SECURE_CONNECTION_NOT_ACTIVE,
    SC_SECURE_CONNECTION_PROTOCOL_REJECTED,
};
use super::types::*;

pub(super) fn decode_secure_config(
    value: ScSecureConnectionConfigV1,
) -> Option<SecureConnectionConfig> {
    if value.reserved0 != 0 || value.reserved1 != 0 {
        return None;
    }
    let session = decode_config(value.session)?;
    let maximum = if value.max_plaintext_bytes == 0 {
        MAX_SECURE_PLAINTEXT
    } else {
        usize::try_from(value.max_plaintext_bytes).ok()?
    };
    SecureConnectionConfig::with_max_plaintext(session, maximum).ok()
}

pub(super) fn decode_material(
    value: &ScSecureRecordMaterialV1,
) -> Option<Option<SecureRecordMaterial>> {
    if value.generation == 0
        || value.operation == 0
        || !matches!(value.success, 0 | 1)
        || value.reserved0 != [0; 7]
        || value.reserved1 != 0
    {
        return None;
    }
    if value.success == 0 {
        let canonical = value.pair_secret == [0; 32]
            && value.responder_challenge == [0; 32]
            && value.initiator_challenge == [0; 32];
        return canonical.then_some(None);
    }
    SecureRecordMaterial::new(
        value.pair_secret,
        value.responder_challenge,
        value.initiator_challenge,
    )
    .ok()
    .map(Some)
}

pub(super) fn encode_secure_effect(
    effect: SecureConnectionEffect,
    struct_size: u32,
) -> ScSecureConnectionEffectV1 {
    let mut output = ScSecureConnectionEffectV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        ..ScSecureConnectionEffectV1::default()
    };
    match effect {
        SecureConnectionEffect::Session(effect) => {
            output.effect_type = SC_SECURE_CONNECTION_EFFECT_SESSION_V1;
            output.session_effect = encode_effect(effect);
        }
        SecureConnectionEffect::PrepareRecordContext {
            generation,
            operation,
        } => {
            output.effect_type = SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1;
            output.generation = generation.get();
            output.operation = operation.get();
        }
        SecureConnectionEffect::ActivateRecords {
            generation,
            operation,
        } => {
            output.effect_type = SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1;
            output.generation = generation.get();
            output.operation = operation.get();
        }
        SecureConnectionEffect::DisposeRecords { generation } => {
            output.effect_type = SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1;
            output.generation = generation.get();
        }
    }
    output
}

pub(super) fn encode_control(
    value: crate::control_envelope::ControlEnvelopeV1,
) -> super::super::ScControlEnvelopeV1 {
    encode_control_envelope_record(value, size_of::<super::super::ScControlEnvelopeV1>() as u32)
}

pub(super) const fn record_phase_value(value: SecureRecordPhase) -> u32 {
    match value {
        SecureRecordPhase::NotRequired => SC_SECURE_CONNECTION_RECORD_NOT_REQUIRED_V1,
        SecureRecordPhase::Inactive => SC_SECURE_CONNECTION_RECORD_INACTIVE_V1,
        SecureRecordPhase::Preparing => SC_SECURE_CONNECTION_RECORD_PREPARING_V1,
        SecureRecordPhase::Activating => SC_SECURE_CONNECTION_RECORD_ACTIVATING_V1,
        SecureRecordPhase::Active => SC_SECURE_CONNECTION_RECORD_ACTIVE_V1,
        SecureRecordPhase::Disposed => SC_SECURE_CONNECTION_RECORD_DISPOSED_V1,
    }
}

pub(super) const fn error_status(error: SecureConnectionError) -> ScStatus {
    match error {
        SecureConnectionError::InvalidRecordMaterial | SecureConnectionError::InvalidChannel => {
            SC_INVALID_ARGUMENT
        }
        SecureConnectionError::RecordsNotActive => SC_SECURE_CONNECTION_NOT_ACTIVE,
        SecureConnectionError::FrameRejected
        | SecureConnectionError::ControlRejected
        | SecureConnectionError::RecordRejected
        | SecureConnectionError::PlaintextDowngrade
        | SecureConnectionError::TooManyFrames => SC_SECURE_CONNECTION_PROTOCOL_REJECTED,
    }
}
