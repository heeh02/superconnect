use zeroize::Zeroize;

use crate::control_envelope::ControlEnvelopeV1;
use crate::record_v1::{MAX_RECORD_PLAINTEXT, RECORD_OVERHEAD_BYTES};
use crate::session::{OperationId, SessionConfig, SessionEffect, SessionEvent, SessionGeneration};
use crate::wire::MAX_FRAME_PAYLOAD;

pub const MAX_SECURE_CONNECTION_EFFECTS: usize = 10;
pub const MAX_SECURE_INBOUND_FRAMES: usize = 1;
pub const MAX_SECURE_PLAINTEXT: usize =
    if MAX_RECORD_PLAINTEXT < MAX_FRAME_PAYLOAD - RECORD_OVERHEAD_BYTES {
        MAX_RECORD_PLAINTEXT
    } else {
        MAX_FRAME_PAYLOAD - RECORD_OVERHEAD_BYTES
    };

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum SecureRecordPhase {
    NotRequired = 0,
    Inactive = 1,
    Preparing = 2,
    Activating = 3,
    Active = 4,
    Disposed = 5,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecureConnectionConfigError {
    InvalidMaximum,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SecureConnectionConfig {
    pub(super) session: SessionConfig,
    pub(super) max_plaintext: usize,
}

impl SecureConnectionConfig {
    pub fn new(session: SessionConfig) -> Result<Self, SecureConnectionConfigError> {
        Self::with_max_plaintext(session, MAX_SECURE_PLAINTEXT)
    }

    pub fn with_max_plaintext(
        session: SessionConfig,
        max_plaintext: usize,
    ) -> Result<Self, SecureConnectionConfigError> {
        if !(1..=MAX_SECURE_PLAINTEXT).contains(&max_plaintext) {
            return Err(SecureConnectionConfigError::InvalidMaximum);
        }
        Ok(Self {
            session,
            max_plaintext,
        })
    }
}

pub struct SecureRecordMaterial {
    pub(super) pair_secret: [u8; 32],
    pub(super) responder_challenge: [u8; 32],
    pub(super) initiator_challenge: [u8; 32],
}

impl SecureRecordMaterial {
    pub fn new(
        pair_secret: [u8; 32],
        responder_challenge: [u8; 32],
        initiator_challenge: [u8; 32],
    ) -> Result<Self, SecureConnectionError> {
        let material = Self {
            pair_secret,
            responder_challenge,
            initiator_challenge,
        };
        if material.pair_secret.iter().all(|byte| *byte == 0)
            || material.responder_challenge.iter().all(|byte| *byte == 0)
            || material.initiator_challenge.iter().all(|byte| *byte == 0)
        {
            return Err(SecureConnectionError::InvalidRecordMaterial);
        }
        Ok(material)
    }
}

impl Drop for SecureRecordMaterial {
    fn drop(&mut self) {
        self.pair_secret.zeroize();
        self.responder_challenge.zeroize();
        self.initiator_challenge.zeroize();
    }
}

pub enum SecureConnectionEvent {
    PeerRecordVersion {
        generation: SessionGeneration,
        version: Option<u16>,
    },
    Session(SessionEvent),
    RecordMaterialPrepared {
        generation: SessionGeneration,
        operation: OperationId,
        material: Option<SecureRecordMaterial>,
    },
    RecordsActivated {
        generation: SessionGeneration,
        operation: OperationId,
        success: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecureConnectionEffect {
    Session(SessionEffect),
    PrepareRecordContext {
        generation: SessionGeneration,
        operation: OperationId,
    },
    ActivateRecords {
        generation: SessionGeneration,
        operation: OperationId,
    },
    DisposeRecords {
        generation: SessionGeneration,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SecureConnectionEffects {
    entries: [Option<SecureConnectionEffect>; MAX_SECURE_CONNECTION_EFFECTS],
    len: u8,
}

impl SecureConnectionEffects {
    pub(super) const fn empty() -> Self {
        Self {
            entries: [None; MAX_SECURE_CONNECTION_EFFECTS],
            len: 0,
        }
    }

    pub(super) fn push(&mut self, effect: SecureConnectionEffect) {
        debug_assert!((self.len as usize) < MAX_SECURE_CONNECTION_EFFECTS);
        self.entries[self.len as usize] = Some(effect);
        self.len += 1;
    }

    pub fn iter(&self) -> impl Iterator<Item = &SecureConnectionEffect> {
        self.entries[..self.len as usize]
            .iter()
            .map(|entry| entry.as_ref().unwrap())
    }

    pub const fn len(&self) -> usize {
        self.len as usize
    }
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SecureInboundFrame {
    pub channel: u8,
    pub flags: u8,
    pub payload: Vec<u8>,
    pub control: Option<ControlEnvelopeV1>,
}

impl Drop for SecureInboundFrame {
    fn drop(&mut self) {
        self.payload.zeroize();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecureConnectionError {
    InvalidRecordMaterial,
    RecordsNotActive,
    InvalidChannel,
    FrameRejected,
    ControlRejected,
    RecordRejected,
    PlaintextDowngrade,
    TooManyFrames,
}
