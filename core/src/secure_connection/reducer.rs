use crate::session::{
    BoundedPeerIdentity, OperationId, ScSession, SessionEffect, SessionEvent, SessionGeneration,
    SessionOrigin, SessionPhase, SessionSide,
};
use crate::wire::{FrameDecoder, DEFAULT_MAX_BUFFERED_BYTES};

use super::record_layer::RecordLayer;
use super::{
    SecureConnectionConfig, SecureConnectionEffect, SecureConnectionEffects, SecureConnectionError,
    SecureConnectionEvent, SecureRecordMaterial, SecureRecordPhase,
};

/// One reducer, frame decoder, counter set, and replay window per connection.
pub struct ScSecureConnection {
    pub(super) session: ScSession,
    pub(super) generation: SessionGeneration,
    pub(super) side: SessionSide,
    pub(super) origin: SessionOrigin,
    pub(super) local_identity: BoundedPeerIdentity,
    peer_identity: Option<BoundedPeerIdentity>,
    peer_record_version: Option<u16>,
    peer_record_version_observed: bool,
    pub(super) record_phase: SecureRecordPhase,
    pub(super) plaintext_forbidden: bool,
    record_operation: Option<OperationId>,
    pending_capability: Option<SessionEffect>,
    pub(super) records: Option<RecordLayer>,
    pub(super) decoder: FrameDecoder,
    max_plaintext: usize,
    pending_data_effects: SecureConnectionEffects,
}

impl ScSecureConnection {
    pub fn new(config: SecureConnectionConfig) -> Self {
        let record_phase = if config.session.origin() == SessionOrigin::TrustedLocal {
            SecureRecordPhase::NotRequired
        } else {
            SecureRecordPhase::Inactive
        };
        Self {
            generation: config.session.generation(),
            side: config.session.side(),
            origin: config.session.origin(),
            local_identity: config.session.local_identity(),
            session: ScSession::new(config.session),
            peer_identity: None,
            peer_record_version: None,
            peer_record_version_observed: false,
            record_phase,
            plaintext_forbidden: false,
            record_operation: None,
            pending_capability: None,
            records: None,
            decoder: FrameDecoder::new(DEFAULT_MAX_BUFFERED_BYTES),
            max_plaintext: config.max_plaintext,
            pending_data_effects: SecureConnectionEffects::empty(),
        }
    }

    pub fn apply(&mut self, event: SecureConnectionEvent) -> SecureConnectionEffects {
        let effects = match event {
            SecureConnectionEvent::PeerRecordVersion {
                generation,
                version,
            } => self.observe_record_version(generation, version),
            SecureConnectionEvent::Session(event) => self.apply_session(event),
            SecureConnectionEvent::RecordMaterialPrepared {
                generation,
                operation,
                material,
            } => self.record_material_prepared(generation, operation, material),
            SecureConnectionEvent::RecordsActivated {
                generation,
                operation,
                success,
            } => self.records_activated(generation, operation, success),
        };
        debug_assert!(self.invariants_hold());
        effects
    }

    pub const fn session_phase(&self) -> SessionPhase {
        self.session.phase()
    }
    pub const fn generation(&self) -> SessionGeneration {
        self.generation
    }
    pub const fn record_phase(&self) -> SecureRecordPhase {
        self.record_phase
    }
    pub fn records_active(&self) -> bool {
        self.record_phase == SecureRecordPhase::Active && self.records.is_some()
    }
    pub fn take_pending_effects(&mut self) -> SecureConnectionEffects {
        core::mem::replace(
            &mut self.pending_data_effects,
            SecureConnectionEffects::empty(),
        )
    }

    pub fn invariants_hold(&self) -> bool {
        let active_shape = matches!(
            self.record_phase,
            SecureRecordPhase::Activating | SecureRecordPhase::Active
        ) == self.records.is_some();
        let ready_is_secure = !self.records_required()
            || !matches!(
                self.session.phase(),
                SessionPhase::Ready | SessionPhase::Streaming
            )
            || self.record_phase == SecureRecordPhase::Active;
        self.session.invariants_hold() && active_shape && ready_is_secure
    }

    pub fn records_required(&self) -> bool {
        self.origin == SessionOrigin::MutualAuthenticationRequired
    }

    fn observe_record_version(
        &mut self,
        generation: SessionGeneration,
        version: Option<u16>,
    ) -> SecureConnectionEffects {
        if generation != self.generation {
            return SecureConnectionEffects::empty();
        }
        if self.peer_record_version_observed {
            return if self.peer_record_version == version {
                SecureConnectionEffects::empty()
            } else {
                self.fail_session()
            };
        }
        if self.peer_identity.is_some() {
            return self.fail_session();
        }
        self.peer_record_version = version;
        self.peer_record_version_observed = true;
        SecureConnectionEffects::empty()
    }

    fn apply_session(&mut self, event: SessionEvent) -> SecureConnectionEffects {
        if event.generation() != self.generation {
            return SecureConnectionEffects::empty();
        }
        if let SessionEvent::PeerHello { peer, .. } | SessionEvent::PeerHelloAck { peer, .. } =
            event
        {
            if self.records_required() && self.peer_record_version != Some(1) {
                return self.fail_session();
            }
            self.peer_identity = Some(peer);
        }
        if let SessionEvent::CapabilitiesCommitted { operation, .. } = event {
            if self.records_required() {
                if self
                    .record_operation
                    .is_some_and(|expected| expected != operation)
                {
                    return SecureConnectionEffects::empty();
                }
                if self.record_phase != SecureRecordPhase::Active
                    || self.record_operation != Some(operation)
                {
                    return self.capability_failed(operation);
                }
            }
        }
        let effects = self.session.apply(event);
        self.translate_session(effects)
    }

    fn translate_session(
        &mut self,
        effects: crate::session::SessionEffects,
    ) -> SecureConnectionEffects {
        let mut output = SecureConnectionEffects::empty();
        for effect in effects.iter().copied() {
            if let SessionEffect::CommitCapabilities { operation, .. } = effect {
                if self.records_required() && self.record_phase != SecureRecordPhase::Active {
                    if self.record_phase != SecureRecordPhase::Inactive
                        || self.pending_capability.is_some()
                    {
                        return self.capability_failed(operation);
                    }
                    self.record_phase = SecureRecordPhase::Preparing;
                    self.record_operation = Some(operation);
                    self.pending_capability = Some(effect);
                    output.push(SecureConnectionEffect::PrepareRecordContext {
                        generation: self.generation,
                        operation,
                    });
                    continue;
                }
            }
            if is_terminal(effect) {
                self.dispose_records(&mut output)
            }
            output.push(SecureConnectionEffect::Session(effect));
        }
        output
    }

    fn record_material_prepared(
        &mut self,
        generation: SessionGeneration,
        operation: OperationId,
        material: Option<SecureRecordMaterial>,
    ) -> SecureConnectionEffects {
        if generation != self.generation
            || self.record_phase != SecureRecordPhase::Preparing
            || self.record_operation != Some(operation)
        {
            return SecureConnectionEffects::empty();
        }
        let Some(material) = material else {
            return self.capability_failed(operation);
        };
        let Some(peer) = self.peer_identity else {
            return self.capability_failed(operation);
        };
        match RecordLayer::new(
            self.side,
            self.local_identity,
            peer,
            &material,
            self.max_plaintext,
        ) {
            Ok(layer) => {
                self.records = Some(layer);
                self.record_phase = SecureRecordPhase::Activating;
                let mut effects = SecureConnectionEffects::empty();
                effects.push(SecureConnectionEffect::ActivateRecords {
                    generation: self.generation,
                    operation,
                });
                effects
            }
            Err(_) => self.capability_failed(operation),
        }
    }

    fn records_activated(
        &mut self,
        generation: SessionGeneration,
        operation: OperationId,
        success: bool,
    ) -> SecureConnectionEffects {
        if generation != self.generation
            || self.record_phase != SecureRecordPhase::Activating
            || self.record_operation != Some(operation)
        {
            return SecureConnectionEffects::empty();
        }
        if !success {
            return self.capability_failed(operation);
        }
        self.record_phase = SecureRecordPhase::Active;
        self.plaintext_forbidden = true;
        let Some(capability) = self.pending_capability.take() else {
            return self.capability_failed(operation);
        };
        let mut effects = SecureConnectionEffects::empty();
        effects.push(SecureConnectionEffect::Session(capability));
        effects
    }

    fn capability_failed(&mut self, operation: OperationId) -> SecureConnectionEffects {
        self.pending_capability = None;
        self.record_operation = Some(operation);
        let effects = self.session.apply(SessionEvent::CapabilitiesCommitted {
            generation: self.generation,
            operation,
            success: false,
        });
        self.translate_session(effects)
    }

    fn fail_session(&mut self) -> SecureConnectionEffects {
        let effects = self.session.protocol_violation();
        self.translate_session(effects)
    }

    pub(super) fn fail_data(&mut self, error: SecureConnectionError) -> SecureConnectionError {
        let effects = self.fail_session();
        if self.pending_data_effects.is_empty() {
            self.pending_data_effects = effects;
        }
        error
    }

    fn dispose_records(&mut self, output: &mut SecureConnectionEffects) {
        if self.record_phase == SecureRecordPhase::Disposed {
            return;
        }
        self.records = None;
        self.pending_capability = None;
        self.record_operation = None;
        self.record_phase = SecureRecordPhase::Disposed;
        self.decoder.reset();
        output.push(SecureConnectionEffect::DisposeRecords {
            generation: self.generation,
        });
    }
}

fn is_terminal(effect: SessionEffect) -> bool {
    matches!(
        effect,
        SessionEffect::CloseTransport | SessionEffect::NotifyClosed | SessionEffect::NotifyFatal(_)
    )
}
