use crate::record_v1::{
    derive_session_context, RecordDirection, RecordOpener, RecordSealer, RecordType,
};
use crate::session::{BoundedPeerIdentity, SessionSide};

use super::{SecureConnectionError, SecureRecordMaterial};

pub(super) struct RecordLayer {
    pub(super) sealer: RecordSealer,
    pub(super) opener: RecordOpener,
}

impl RecordLayer {
    pub(super) fn new(
        side: SessionSide,
        local: BoundedPeerIdentity,
        peer: BoundedPeerIdentity,
        material: &SecureRecordMaterial,
        max_plaintext: usize,
    ) -> Result<Self, SecureConnectionError> {
        let (initiator, responder, outbound, inbound) = match side {
            SessionSide::Initiator => (
                local,
                peer,
                RecordDirection::InitiatorToResponder,
                RecordDirection::ResponderToInitiator,
            ),
            SessionSide::Responder => (
                peer,
                local,
                RecordDirection::ResponderToInitiator,
                RecordDirection::InitiatorToResponder,
            ),
        };
        let context = derive_session_context(
            initiator.as_bytes(),
            responder.as_bytes(),
            &material.responder_challenge,
            &material.initiator_challenge,
        )
        .map_err(|_| SecureConnectionError::InvalidRecordMaterial)?;
        let sealer = RecordSealer::new(
            &material.pair_secret,
            &context.bytes,
            outbound,
            context.generation,
            max_plaintext,
        )
        .map_err(|_| SecureConnectionError::InvalidRecordMaterial)?;
        let opener = RecordOpener::new(
            &material.pair_secret,
            &context.bytes,
            inbound,
            context.generation,
            max_plaintext,
        )
        .map_err(|_| SecureConnectionError::InvalidRecordMaterial)?;
        Ok(Self { sealer, opener })
    }
}

pub(super) fn record_type(channel: u8) -> Result<RecordType, SecureConnectionError> {
    match channel {
        0 => Ok(RecordType::Control),
        1 => Ok(RecordType::Video),
        2 => Ok(RecordType::Input),
        _ => Err(SecureConnectionError::InvalidChannel),
    }
}
