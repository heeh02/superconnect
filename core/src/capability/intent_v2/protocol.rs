use crate::collaboration_intent::{
    InputPolicy, LocalRole, ResolvedIntent, SinkPresentation, SourceTopology, Topology,
    TransportPreference,
};
use crate::session_generation::SessionGeneration;

use super::*;
use crate::capability::machine::{
    Effect as MachineEffect, Event as MachineEvent, Machine, Protocol,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct IntentProtocol(IntentNegotiationConfig);

impl IntentProtocol {
    fn expected_peer_intent(self, received: ResolvedIntent) -> bool {
        let local = self.0.resolved_intent;
        received.local_role() == self.0.desired_peer_role
            && received.source_topology() == local.source_topology()
            && received.sink_presentation() == local.sink_presentation()
            && received.input_policy() == local.input_policy()
            && received.transport_preference() == local.transport_preference()
            && received.topology() == local.topology()
    }

    fn validate_message(
        self,
        role: LocalRole,
        projection: SourceTopology,
        transport: TransportPreference,
        intent: ResolvedIntent,
    ) -> Result<(), IntentFatalReason> {
        if role != intent.local_role() {
            return Err(IntentFatalReason::RoleMismatch {
                expected: intent.local_role(),
                received: role,
            });
        }
        if projection != intent.source_topology() {
            return Err(IntentFatalReason::ProjectionMismatch {
                expected: intent.source_topology(),
                received: projection,
            });
        }
        if transport != intent.transport_preference() {
            return Err(IntentFatalReason::TransportMismatch {
                expected: intent.transport_preference(),
                received: transport,
            });
        }
        Ok(())
    }

    fn local_matches_legacy(self) -> bool {
        let expected_role = match self.0.side {
            NegotiationSide::Offerer => LocalRole::Source,
            NegotiationSide::Selector => LocalRole::Sink,
        };
        let intent = self.0.resolved_intent;
        intent.local_role() == expected_role
            && self.0.desired_peer_role
                == match expected_role {
                    LocalRole::Source => LocalRole::Sink,
                    LocalRole::Sink => LocalRole::Source,
                    LocalRole::Relay => return false,
                }
            && intent.source_topology() == SourceTopology::Extend
            && intent.sink_presentation() == SinkPresentation::Windowed
            && intent.input_policy() == InputPolicy::RemoteControl
            && intent.transport_preference() == TransportPreference::Reliable
            && intent.topology() == Topology::Direct
    }
}

impl Protocol for IntentProtocol {
    type Offer = IntentCapabilityOffer;
    type Selection = IntentCapabilitySelection;
    type Commit = IntentCapabilityCommit;
    type Binding = IntentSessionBinding;
    type Fatal = IntentFatalReason;

    fn generation(self) -> SessionGeneration {
        self.0.generation
    }

    fn side(self) -> NegotiationSide {
        self.0.side
    }

    fn version(self) -> u16 {
        NEGOTIATION_VERSION_2
    }

    fn make_offer(self) -> IntentCapabilityOffer {
        let intent = self.0.resolved_intent;
        IntentCapabilityOffer {
            generation: self.0.generation,
            negotiation_version: NEGOTIATION_VERSION_2,
            offerer_role: intent.local_role(),
            desired_peer_role: self.0.desired_peer_role,
            projection: intent.source_topology(),
            transport: intent.transport_preference(),
            resolved_intent: intent,
        }
    }

    fn select(
        self,
        offer: IntentCapabilityOffer,
    ) -> Result<IntentCapabilitySelection, IntentFatalReason> {
        if offer.negotiation_version != NEGOTIATION_VERSION_2 {
            return Err(self.unsupported_version(offer.negotiation_version));
        }
        self.validate_message(
            offer.offerer_role,
            offer.projection,
            offer.transport,
            offer.resolved_intent,
        )?;
        if offer.offerer_role != self.0.desired_peer_role {
            return Err(IntentFatalReason::RoleMismatch {
                expected: self.0.desired_peer_role,
                received: offer.offerer_role,
            });
        }
        if offer.desired_peer_role != self.0.resolved_intent.local_role() {
            return Err(IntentFatalReason::RoleMismatch {
                expected: self.0.resolved_intent.local_role(),
                received: offer.desired_peer_role,
            });
        }
        if !self.expected_peer_intent(offer.resolved_intent) {
            return Err(IntentFatalReason::IntentMismatch);
        }
        let intent = self.0.resolved_intent;
        Ok(IntentCapabilitySelection {
            generation: self.0.generation,
            negotiation_version: NEGOTIATION_VERSION_2,
            offerer_role: offer.offerer_role,
            selector_role: intent.local_role(),
            projection: intent.source_topology(),
            transport: intent.transport_preference(),
            resolved_intent: intent,
        })
    }

    fn commit(
        self,
        selection: IntentCapabilitySelection,
    ) -> Result<IntentCapabilityCommit, IntentFatalReason> {
        if selection.negotiation_version != NEGOTIATION_VERSION_2 {
            return Err(self.unsupported_version(selection.negotiation_version));
        }
        self.validate_message(
            selection.selector_role,
            selection.projection,
            selection.transport,
            selection.resolved_intent,
        )?;
        if selection.offerer_role != self.0.resolved_intent.local_role() {
            return Err(IntentFatalReason::RoleMismatch {
                expected: self.0.resolved_intent.local_role(),
                received: selection.offerer_role,
            });
        }
        if selection.selector_role != self.0.desired_peer_role {
            return Err(IntentFatalReason::RoleMismatch {
                expected: self.0.desired_peer_role,
                received: selection.selector_role,
            });
        }
        if !self.expected_peer_intent(selection.resolved_intent) {
            return Err(IntentFatalReason::IntentMismatch);
        }
        Ok(IntentCapabilityCommit::from_selection(selection))
    }

    fn commit_matches(
        self,
        commit: IntentCapabilityCommit,
        selection: IntentCapabilitySelection,
    ) -> bool {
        commit == IntentCapabilityCommit::from_selection(selection)
    }

    fn binding(self, negotiated: bool) -> Result<IntentSessionBinding, IntentFatalReason> {
        if !negotiated && !self.local_matches_legacy() {
            return Err(IntentFatalReason::LegacyIntentMismatch);
        }
        Ok(IntentSessionBinding {
            local_intent: self.0.resolved_intent,
            peer_role: self.0.desired_peer_role,
            negotiated,
        })
    }

    fn unsupported_version(self, received: u16) -> IntentFatalReason {
        IntentFatalReason::UnsupportedVersion {
            expected: NEGOTIATION_VERSION_2,
            received,
        }
    }

    fn commit_mismatch(self) -> IntentFatalReason {
        IntentFatalReason::CommitMismatch
    }

    fn offer_invariant(self, offer: IntentCapabilityOffer) -> bool {
        offer.generation == self.0.generation
            && offer.negotiation_version == NEGOTIATION_VERSION_2
            && self
                .validate_message(
                    offer.offerer_role,
                    offer.projection,
                    offer.transport,
                    offer.resolved_intent,
                )
                .is_ok()
            && match self.0.side {
                NegotiationSide::Offerer => offer.resolved_intent == self.0.resolved_intent,
                NegotiationSide::Selector => self.expected_peer_intent(offer.resolved_intent),
            }
    }

    fn selection_invariant(self, selection: IntentCapabilitySelection) -> bool {
        selection.generation == self.0.generation
            && selection.negotiation_version == NEGOTIATION_VERSION_2
            && selection.resolved_intent == self.0.resolved_intent
            && self
                .validate_message(
                    selection.selector_role,
                    selection.projection,
                    selection.transport,
                    selection.resolved_intent,
                )
                .is_ok()
    }

    fn binding_invariant(self, binding: IntentSessionBinding) -> bool {
        binding.local_intent == self.0.resolved_intent
            && binding.peer_role == self.0.desired_peer_role
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct ScCapabilityNegotiationV2 {
    machine: Machine<IntentProtocol>,
}

impl ScCapabilityNegotiationV2 {
    pub const fn new(config: IntentNegotiationConfig) -> Self {
        Self {
            machine: Machine::new(IntentProtocol(config)),
        }
    }

    pub fn apply(&mut self, event: IntentNegotiationEvent) -> IntentNegotiationEffects {
        let generation = event.generation();
        let event = match event {
            IntentNegotiationEvent::PeerHello {
                negotiation_version,
                ..
            } => MachineEvent::PeerHello {
                negotiation_version,
            },
            IntentNegotiationEvent::Offer(value) => MachineEvent::Offer(value),
            IntentNegotiationEvent::Selection(value) => MachineEvent::Selection(value),
            IntentNegotiationEvent::Commit(value) => MachineEvent::Commit(value),
        };
        let mut result = IntentNegotiationEffects::empty();
        for (index, effect) in self
            .machine
            .apply(generation, event)
            .iter()
            .copied()
            .enumerate()
        {
            result.items[index] = Some(match effect {
                MachineEffect::SendOffer(value) => IntentNegotiationEffect::SendOffer(value),
                MachineEffect::SendSelection(value) => {
                    IntentNegotiationEffect::SendSelection(value)
                }
                MachineEffect::SendCommit(value) => IntentNegotiationEffect::SendCommit(value),
                MachineEffect::Committed(value) => IntentNegotiationEffect::Committed(value),
                MachineEffect::Connected(value) => IntentNegotiationEffect::Connected(value),
                MachineEffect::Rejected(value) => IntentNegotiationEffect::Rejected(value),
                MachineEffect::Fatal(value) => IntentNegotiationEffect::Fatal(value),
            });
            result.len += 1;
        }
        result
    }

    pub const fn binding(&self) -> Option<IntentSessionBinding> {
        self.machine.binding()
    }

    pub const fn config(&self) -> IntentNegotiationConfig {
        self.machine.protocol().0
    }

    pub fn invariants_hold(&self) -> bool {
        self.machine.invariants_hold()
    }
}
