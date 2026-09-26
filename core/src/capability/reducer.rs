use super::machine::{Effect as MachineEffect, Event as MachineEvent, Machine, Protocol};
use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CapabilityProtocol {
    config: NegotiationConfig,
}

impl CapabilityProtocol {
    const fn new(config: NegotiationConfig) -> Self {
        Self { config }
    }

    fn validate_version(self, received: u16) -> Result<(), FatalReason> {
        if received == NEGOTIATION_VERSION_1 {
            Ok(())
        } else {
            Err(self.unsupported_version(received))
        }
    }

    fn validate_projection(self, received: ProjectionIntent) -> Result<(), FatalReason> {
        let capability = CapabilityId::for_projection(received);
        if !self.config.authorized.contains(capability) {
            return Err(FatalReason::UnsupportedCapability { capability });
        }
        if received != self.config.projection {
            return Err(FatalReason::ProjectionMismatch {
                expected: self.config.projection,
                received,
            });
        }
        Ok(())
    }

    fn validate_transport(self, received: TransportKind) -> Result<(), FatalReason> {
        let capability = CapabilityId::for_transport(received);
        if self.config.authorized.contains(capability) {
            Ok(())
        } else {
            Err(FatalReason::UnsupportedCapability { capability })
        }
    }
}

impl Protocol for CapabilityProtocol {
    type Offer = CapabilityOffer;
    type Selection = CapabilitySelection;
    type Commit = CapabilityCommit;
    type Binding = SessionBinding;
    type Fatal = FatalReason;

    fn generation(self) -> SessionGeneration {
        self.config.generation
    }

    fn side(self) -> NegotiationSide {
        self.config.side
    }

    fn version(self) -> u16 {
        NEGOTIATION_VERSION_1
    }

    fn make_offer(self) -> CapabilityOffer {
        CapabilityOffer {
            generation: self.config.generation,
            negotiation_version: NEGOTIATION_VERSION_1,
            capabilities: self.config.authorized,
            local_role: self.config.local_role,
            desired_peer_role: self.config.desired_peer_role,
            projection: self.config.projection,
            transport: TransportKind::Tcp,
        }
    }

    fn select(self, offer: CapabilityOffer) -> Result<CapabilitySelection, FatalReason> {
        self.validate_version(offer.negotiation_version)?;
        for capability in [
            CapabilityId::for_role(offer.local_role),
            CapabilityId::for_projection(offer.projection),
            CapabilityId::for_transport(offer.transport),
        ] {
            if !offer.capabilities.contains(capability) {
                return Err(FatalReason::UnsupportedCapability { capability });
            }
        }
        if offer.local_role != self.config.desired_peer_role {
            return Err(FatalReason::RoleMismatch {
                expected: self.config.desired_peer_role,
                received: offer.local_role,
            });
        }
        if offer.desired_peer_role != self.config.local_role {
            return Err(FatalReason::RoleMismatch {
                expected: self.config.local_role,
                received: offer.desired_peer_role,
            });
        }
        self.validate_projection(offer.projection)?;
        self.validate_transport(offer.transport)?;
        Ok(CapabilitySelection {
            generation: self.config.generation,
            negotiation_version: NEGOTIATION_VERSION_1,
            offerer_role: offer.local_role,
            selector_role: self.config.local_role,
            projection: offer.projection,
            transport: offer.transport,
        })
    }

    fn commit(self, selection: CapabilitySelection) -> Result<CapabilityCommit, FatalReason> {
        self.validate_version(selection.negotiation_version)?;
        if selection.offerer_role != self.config.local_role {
            return Err(FatalReason::RoleMismatch {
                expected: self.config.local_role,
                received: selection.offerer_role,
            });
        }
        if selection.selector_role != self.config.desired_peer_role {
            return Err(FatalReason::RoleMismatch {
                expected: self.config.desired_peer_role,
                received: selection.selector_role,
            });
        }
        self.validate_projection(selection.projection)?;
        self.validate_transport(selection.transport)?;
        Ok(CapabilityCommit::from_selection(selection))
    }

    fn commit_matches(self, commit: CapabilityCommit, selection: CapabilitySelection) -> bool {
        commit == CapabilityCommit::from_selection(selection)
    }

    fn binding(self, negotiated: bool) -> Result<SessionBinding, FatalReason> {
        if negotiated {
            return Ok(SessionBinding {
                local_role: self.config.local_role,
                peer_role: self.config.desired_peer_role,
                projection: self.config.projection,
                transport: TransportKind::Tcp,
                negotiated: true,
            });
        }
        let (local_role, peer_role) = match self.config.side {
            NegotiationSide::Offerer => (MediaRole::Host, MediaRole::Receiver),
            NegotiationSide::Selector => (MediaRole::Receiver, MediaRole::Host),
        };
        for capability in [
            CapabilityId::for_role(local_role),
            CapabilityId::ProjectionExtend,
            CapabilityId::TransportTcp,
        ] {
            if !self.config.authorized.contains(capability) {
                return Err(FatalReason::UnsupportedCapability { capability });
            }
        }
        Ok(SessionBinding {
            local_role,
            peer_role,
            projection: ProjectionIntent::Extend,
            transport: TransportKind::Tcp,
            negotiated: false,
        })
    }

    fn unsupported_version(self, received: u16) -> FatalReason {
        FatalReason::UnsupportedVersion {
            expected: NEGOTIATION_VERSION_1,
            received,
        }
    }

    fn commit_mismatch(self) -> FatalReason {
        FatalReason::CommitMismatch
    }

    fn offer_invariant(self, offer: CapabilityOffer) -> bool {
        offer.generation == self.config.generation
            && offer.negotiation_version == NEGOTIATION_VERSION_1
            && offer.local_role
                == match self.config.side {
                    NegotiationSide::Offerer => self.config.local_role,
                    NegotiationSide::Selector => self.config.desired_peer_role,
                }
            && offer.desired_peer_role
                == match self.config.side {
                    NegotiationSide::Offerer => self.config.desired_peer_role,
                    NegotiationSide::Selector => self.config.local_role,
                }
    }

    fn selection_invariant(self, selection: CapabilitySelection) -> bool {
        selection.generation == self.config.generation
            && selection.negotiation_version == NEGOTIATION_VERSION_1
            && selection.offerer_role == self.config.desired_peer_role
            && selection.selector_role == self.config.local_role
    }

    fn binding_invariant(self, binding: SessionBinding) -> bool {
        binding.local_role != binding.peer_role
            && binding.transport == TransportKind::Tcp
            && self
                .config
                .authorized
                .contains(CapabilityId::for_role(binding.local_role))
            && self
                .config
                .authorized
                .contains(CapabilityId::for_projection(binding.projection))
            && self.config.authorized.contains(CapabilityId::TransportTcp)
    }
}

impl ScCapabilityNegotiation {
    pub const fn new(config: NegotiationConfig) -> Self {
        Self {
            machine: Machine::new(CapabilityProtocol::new(config)),
        }
    }

    pub fn apply(&mut self, event: NegotiationEvent) -> NegotiationEffects {
        let generation = event.generation();
        let event = match event {
            NegotiationEvent::PeerHello {
                negotiation_version,
                ..
            } => MachineEvent::PeerHello {
                negotiation_version,
            },
            NegotiationEvent::Offer(value) => MachineEvent::Offer(value),
            NegotiationEvent::Selection(value) => MachineEvent::Selection(value),
            NegotiationEvent::Commit(value) => MachineEvent::Commit(value),
        };
        let machine_effects = self.machine.apply(generation, event);
        let mut result = NegotiationEffects::empty();
        for (index, effect) in machine_effects.iter().copied().enumerate() {
            result.items[index] = Some(match effect {
                MachineEffect::SendOffer(value) => NegotiationEffect::SendOffer(value),
                MachineEffect::SendSelection(value) => NegotiationEffect::SendSelection(value),
                MachineEffect::SendCommit(value) => NegotiationEffect::SendCommit(value),
                MachineEffect::Committed(value) => NegotiationEffect::Committed(value),
                MachineEffect::Connected(value) => NegotiationEffect::Connected(value),
                MachineEffect::Rejected(value) => NegotiationEffect::Rejected(value),
                MachineEffect::Fatal(value) => NegotiationEffect::Fatal(value),
            });
            result.len += 1;
        }
        result
    }

    pub const fn binding(&self) -> Option<SessionBinding> {
        self.machine.binding()
    }

    pub fn invariants_hold(&self) -> bool {
        self.machine.invariants_hold()
    }
}
