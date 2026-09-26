use core::fmt::Debug;

use crate::session_generation::SessionGeneration;

use super::{NegotiationSide, RejectReason, MAX_NEGOTIATION_EFFECTS};

pub(super) trait Protocol: Copy + Debug + PartialEq + Eq {
    type Offer: Copy + Debug + PartialEq + Eq;
    type Selection: Copy + Debug + PartialEq + Eq;
    type Commit: Copy + Debug + PartialEq + Eq;
    type Binding: Copy + Debug + PartialEq + Eq;
    type Fatal: Copy + Debug + PartialEq + Eq;

    fn generation(self) -> SessionGeneration;
    fn side(self) -> NegotiationSide;
    fn version(self) -> u16;
    fn make_offer(self) -> Self::Offer;
    fn select(self, offer: Self::Offer) -> Result<Self::Selection, Self::Fatal>;
    fn commit(self, selection: Self::Selection) -> Result<Self::Commit, Self::Fatal>;
    fn commit_matches(self, commit: Self::Commit, selection: Self::Selection) -> bool;
    fn binding(self, negotiated: bool) -> Result<Self::Binding, Self::Fatal>;
    fn unsupported_version(self, received: u16) -> Self::Fatal;
    fn commit_mismatch(self) -> Self::Fatal;
    fn offer_invariant(self, offer: Self::Offer) -> bool;
    fn selection_invariant(self, selection: Self::Selection) -> bool;
    fn binding_invariant(self, binding: Self::Binding) -> bool;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Event<O, S, C> {
    PeerHello { negotiation_version: Option<u16> },
    Offer(O),
    Selection(S),
    Commit(C),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Effect<O, S, C, B, F> {
    SendOffer(O),
    SendSelection(S),
    SendCommit(C),
    Committed(B),
    Connected(B),
    Rejected(RejectReason),
    Fatal(F),
}

type EffectSlots<O, S, C, B, F> = [Option<Effect<O, S, C, B, F>>; MAX_NEGOTIATION_EFFECTS];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Effects<O, S, C, B, F> {
    items: EffectSlots<O, S, C, B, F>,
    len: u8,
}

impl<O: Copy, S: Copy, C: Copy, B: Copy, F: Copy> Effects<O, S, C, B, F> {
    const fn empty() -> Self {
        Self {
            items: [None; MAX_NEGOTIATION_EFFECTS],
            len: 0,
        }
    }

    const fn one(first: Effect<O, S, C, B, F>) -> Self {
        Self {
            items: [Some(first), None, None],
            len: 1,
        }
    }

    const fn two(first: Effect<O, S, C, B, F>, second: Effect<O, S, C, B, F>) -> Self {
        Self {
            items: [Some(first), Some(second), None],
            len: 2,
        }
    }

    const fn three(
        first: Effect<O, S, C, B, F>,
        second: Effect<O, S, C, B, F>,
        third: Effect<O, S, C, B, F>,
    ) -> Self {
        Self {
            items: [Some(first), Some(second), Some(third)],
            len: 3,
        }
    }

    pub(super) fn iter(&self) -> impl Iterator<Item = &Effect<O, S, C, B, F>> {
        self.items
            .iter()
            .take(self.len as usize)
            .filter_map(Option::as_ref)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Committed<P: Protocol> {
    binding: P::Binding,
    peer_version: Option<u16>,
    received_offer: Option<P::Offer>,
    received_selection: Option<P::Selection>,
    received_commit: Option<P::Commit>,
}

impl<P: Protocol> Committed<P> {
    fn accepts_duplicate(self, event: Event<P::Offer, P::Selection, P::Commit>) -> bool {
        match event {
            Event::PeerHello {
                negotiation_version,
            } => negotiation_version == self.peer_version,
            Event::Offer(value) => self.received_offer == Some(value),
            Event::Selection(value) => self.received_selection == Some(value),
            Event::Commit(value) => self.received_commit == Some(value),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase<P: Protocol> {
    Idle,
    AwaitingOffer {
        peer_version: u16,
    },
    AwaitingSelection {
        peer_version: u16,
        offer: P::Offer,
    },
    AwaitingCommit {
        peer_version: u16,
        offer: P::Offer,
        selection: P::Selection,
    },
    Committed(Committed<P>),
    Failed,
}

pub(super) type ProtocolEffects<P> = Effects<
    <P as Protocol>::Offer,
    <P as Protocol>::Selection,
    <P as Protocol>::Commit,
    <P as Protocol>::Binding,
    <P as Protocol>::Fatal,
>;

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Machine<P: Protocol> {
    protocol: P,
    phase: Phase<P>,
}

impl<P: Protocol> Machine<P> {
    pub(super) const fn new(protocol: P) -> Self {
        Self {
            protocol,
            phase: Phase::Idle,
        }
    }

    pub(super) const fn protocol(&self) -> P {
        self.protocol
    }

    pub(super) const fn binding(&self) -> Option<P::Binding> {
        match self.phase {
            Phase::Committed(committed) => Some(committed.binding),
            _ => None,
        }
    }

    pub(super) fn apply(
        &mut self,
        generation: SessionGeneration,
        event: Event<P::Offer, P::Selection, P::Commit>,
    ) -> ProtocolEffects<P> {
        if generation != self.protocol.generation() {
            return Effects::one(Effect::Rejected(RejectReason::StaleGeneration {
                expected: self.protocol.generation(),
                received: generation,
            }));
        }
        match self.phase {
            Phase::Idle => self.apply_idle(event),
            Phase::AwaitingOffer { peer_version } => self.apply_offer(peer_version, event),
            Phase::AwaitingSelection {
                peer_version,
                offer,
            } => self.apply_selection(peer_version, offer, event),
            Phase::AwaitingCommit {
                peer_version,
                offer,
                selection,
            } => self.apply_commit(peer_version, offer, selection, event),
            Phase::Committed(committed) if committed.accepts_duplicate(event) => Effects::empty(),
            Phase::Committed(_) => Self::out_of_order(),
            Phase::Failed => Effects::empty(),
        }
    }

    fn apply_idle(
        &mut self,
        event: Event<P::Offer, P::Selection, P::Commit>,
    ) -> ProtocolEffects<P> {
        let Event::PeerHello {
            negotiation_version,
        } = event
        else {
            return Self::out_of_order();
        };
        let Some(peer_version) = negotiation_version else {
            return self.commit_legacy();
        };
        if peer_version != self.protocol.version() {
            return self.fail(self.protocol.unsupported_version(peer_version));
        }
        match self.protocol.side() {
            NegotiationSide::Offerer => {
                let offer = self.protocol.make_offer();
                self.phase = Phase::AwaitingSelection {
                    peer_version,
                    offer,
                };
                Effects::one(Effect::SendOffer(offer))
            }
            NegotiationSide::Selector => {
                self.phase = Phase::AwaitingOffer { peer_version };
                Effects::empty()
            }
        }
    }

    fn apply_offer(
        &mut self,
        peer_version: u16,
        event: Event<P::Offer, P::Selection, P::Commit>,
    ) -> ProtocolEffects<P> {
        match event {
            Event::PeerHello {
                negotiation_version: Some(version),
            } if version == peer_version => Effects::empty(),
            Event::Offer(offer) => match self.protocol.select(offer) {
                Ok(selection) => {
                    self.phase = Phase::AwaitingCommit {
                        peer_version,
                        offer,
                        selection,
                    };
                    Effects::one(Effect::SendSelection(selection))
                }
                Err(reason) => self.fail(reason),
            },
            _ => Self::out_of_order(),
        }
    }

    fn apply_selection(
        &mut self,
        peer_version: u16,
        offer: P::Offer,
        event: Event<P::Offer, P::Selection, P::Commit>,
    ) -> ProtocolEffects<P> {
        match event {
            Event::PeerHello {
                negotiation_version: Some(version),
            } if version == peer_version => Effects::empty(),
            Event::Selection(selection) => match self.protocol.commit(selection) {
                Ok(commit) => match self.protocol.binding(true) {
                    Ok(binding) => {
                        self.phase = Phase::Committed(Committed {
                            binding,
                            peer_version: Some(peer_version),
                            received_offer: None,
                            received_selection: Some(selection),
                            received_commit: None,
                        });
                        let _ = offer;
                        Effects::three(
                            Effect::SendCommit(commit),
                            Effect::Committed(binding),
                            Effect::Connected(binding),
                        )
                    }
                    Err(reason) => self.fail(reason),
                },
                Err(reason) => self.fail(reason),
            },
            _ => Self::out_of_order(),
        }
    }

    fn apply_commit(
        &mut self,
        peer_version: u16,
        offer: P::Offer,
        selection: P::Selection,
        event: Event<P::Offer, P::Selection, P::Commit>,
    ) -> ProtocolEffects<P> {
        match event {
            Event::PeerHello {
                negotiation_version: Some(version),
            } if version == peer_version => Effects::empty(),
            Event::Offer(duplicate) if duplicate == offer => Effects::empty(),
            Event::Commit(commit) if self.protocol.commit_matches(commit, selection) => {
                match self.protocol.binding(true) {
                    Ok(binding) => {
                        self.phase = Phase::Committed(Committed {
                            binding,
                            peer_version: Some(peer_version),
                            received_offer: Some(offer),
                            received_selection: None,
                            received_commit: Some(commit),
                        });
                        Effects::two(Effect::Committed(binding), Effect::Connected(binding))
                    }
                    Err(reason) => self.fail(reason),
                }
            }
            Event::Commit(_) => self.fail(self.protocol.commit_mismatch()),
            _ => Self::out_of_order(),
        }
    }

    fn commit_legacy(&mut self) -> ProtocolEffects<P> {
        match self.protocol.binding(false) {
            Ok(binding) => {
                self.phase = Phase::Committed(Committed {
                    binding,
                    peer_version: None,
                    received_offer: None,
                    received_selection: None,
                    received_commit: None,
                });
                Effects::two(Effect::Committed(binding), Effect::Connected(binding))
            }
            Err(reason) => self.fail(reason),
        }
    }

    fn fail(&mut self, reason: P::Fatal) -> ProtocolEffects<P> {
        self.phase = Phase::Failed;
        Effects::one(Effect::Fatal(reason))
    }

    const fn out_of_order() -> ProtocolEffects<P> {
        Effects::one(Effect::Rejected(RejectReason::OutOfOrder))
    }

    pub(super) fn invariants_hold(&self) -> bool {
        match self.phase {
            Phase::Idle | Phase::Failed => true,
            Phase::AwaitingOffer { peer_version } => {
                self.protocol.side() == NegotiationSide::Selector
                    && peer_version == self.protocol.version()
            }
            Phase::AwaitingSelection {
                peer_version,
                offer,
            } => {
                self.protocol.side() == NegotiationSide::Offerer
                    && peer_version == self.protocol.version()
                    && self.protocol.offer_invariant(offer)
            }
            Phase::AwaitingCommit {
                peer_version,
                offer,
                selection,
            } => {
                self.protocol.side() == NegotiationSide::Selector
                    && peer_version == self.protocol.version()
                    && self.protocol.offer_invariant(offer)
                    && self.protocol.selection_invariant(selection)
            }
            Phase::Committed(committed) => self.protocol.binding_invariant(committed.binding),
        }
    }
}
