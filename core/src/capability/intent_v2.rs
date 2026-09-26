use crate::collaboration_intent::{
    resolve_intent, IntentCapability, IntentResolutionError, LocalRole, PeerCapabilityProfile,
    ProductCapabilityProfile, ResolvedIntent, SessionIntentDraft, SourceTopology,
    TransportPreference,
};
use crate::session_generation::SessionGeneration;

use super::{NegotiationSide, RejectReason, MAX_NEGOTIATION_EFFECTS};

mod profile_wire;
mod protocol;
mod wire;
pub use profile_wire::*;
pub use protocol::ScCapabilityNegotiationV2;
pub use wire::*;

pub const NEGOTIATION_VERSION_2: u16 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentConfigError {
    InvalidGeneration,
    RoleCollision,
    PeerRoleMismatch {
        expected: LocalRole,
        received: LocalRole,
    },
    PeerCapabilityMissing(IntentCapability),
    Resolution(IntentResolutionError),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentNegotiationConfig {
    generation: SessionGeneration,
    side: NegotiationSide,
    desired_peer_role: LocalRole,
    product: ProductCapabilityProfile,
    peer: PeerCapabilityProfile,
    resolved_intent: ResolvedIntent,
}

impl IntentNegotiationConfig {
    pub fn new(
        generation: SessionGeneration,
        side: NegotiationSide,
        desired_peer_role: LocalRole,
        product: ProductCapabilityProfile,
        peer: PeerCapabilityProfile,
        draft: SessionIntentDraft,
    ) -> Result<Self, IntentConfigError> {
        if generation == SessionGeneration::INVALID {
            return Err(IntentConfigError::InvalidGeneration);
        }
        if draft.local_role() == desired_peer_role {
            return Err(IntentConfigError::RoleCollision);
        }
        let expected_peer_role = match draft.local_role() {
            LocalRole::Source => Some(LocalRole::Sink),
            LocalRole::Sink => Some(LocalRole::Source),
            LocalRole::Relay => None,
        };
        if let Some(expected) = expected_peer_role {
            if desired_peer_role != expected {
                return Err(IntentConfigError::PeerRoleMismatch {
                    expected,
                    received: desired_peer_role,
                });
            }
        }
        let peer_role = IntentCapability::LocalRole(desired_peer_role);
        if !peer.supports(peer_role) {
            return Err(IntentConfigError::PeerCapabilityMissing(peer_role));
        }
        let resolved_intent =
            resolve_intent(product, peer, draft).map_err(IntentConfigError::Resolution)?;
        Ok(Self {
            generation,
            side,
            desired_peer_role,
            product,
            peer,
            resolved_intent,
        })
    }

    pub const fn generation(self) -> SessionGeneration {
        self.generation
    }

    pub const fn side(self) -> NegotiationSide {
        self.side
    }

    pub const fn desired_peer_role(self) -> LocalRole {
        self.desired_peer_role
    }

    pub const fn product_profile(self) -> ProductCapabilityProfile {
        self.product
    }

    pub const fn peer_profile(self) -> PeerCapabilityProfile {
        self.peer
    }

    pub const fn resolved_intent(self) -> ResolvedIntent {
        self.resolved_intent
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentCapabilityOffer {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: LocalRole,
    pub desired_peer_role: LocalRole,
    pub projection: SourceTopology,
    pub transport: TransportPreference,
    pub resolved_intent: ResolvedIntent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentCapabilitySelection {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: LocalRole,
    pub selector_role: LocalRole,
    pub projection: SourceTopology,
    pub transport: TransportPreference,
    pub resolved_intent: ResolvedIntent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentCapabilityCommit {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: LocalRole,
    pub selector_role: LocalRole,
    pub projection: SourceTopology,
    pub transport: TransportPreference,
    pub resolved_intent: ResolvedIntent,
}

impl IntentCapabilityCommit {
    pub const fn from_selection(selection: IntentCapabilitySelection) -> Self {
        Self {
            generation: selection.generation,
            negotiation_version: selection.negotiation_version,
            offerer_role: selection.offerer_role,
            selector_role: selection.selector_role,
            projection: selection.projection,
            transport: selection.transport,
            resolved_intent: selection.resolved_intent,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentSessionBinding {
    pub local_intent: ResolvedIntent,
    pub peer_role: LocalRole,
    pub negotiated: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentFatalReason {
    UnsupportedVersion {
        expected: u16,
        received: u16,
    },
    RoleMismatch {
        expected: LocalRole,
        received: LocalRole,
    },
    ProjectionMismatch {
        expected: SourceTopology,
        received: SourceTopology,
    },
    TransportMismatch {
        expected: TransportPreference,
        received: TransportPreference,
    },
    IntentMismatch,
    CommitMismatch,
    LegacyIntentMismatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentNegotiationEvent {
    PeerHello {
        generation: SessionGeneration,
        negotiation_version: Option<u16>,
    },
    Offer(IntentCapabilityOffer),
    Selection(IntentCapabilitySelection),
    Commit(IntentCapabilityCommit),
}

impl IntentNegotiationEvent {
    pub(super) const fn generation(self) -> SessionGeneration {
        match self {
            Self::PeerHello { generation, .. } => generation,
            Self::Offer(value) => value.generation,
            Self::Selection(value) => value.generation,
            Self::Commit(value) => value.generation,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentNegotiationEffect {
    SendOffer(IntentCapabilityOffer),
    SendSelection(IntentCapabilitySelection),
    SendCommit(IntentCapabilityCommit),
    Committed(IntentSessionBinding),
    Connected(IntentSessionBinding),
    Rejected(RejectReason),
    Fatal(IntentFatalReason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntentNegotiationEffects {
    pub(super) items: [Option<IntentNegotiationEffect>; MAX_NEGOTIATION_EFFECTS],
    pub(super) len: u8,
}

impl IntentNegotiationEffects {
    pub(super) const fn empty() -> Self {
        Self {
            items: [None; MAX_NEGOTIATION_EFFECTS],
            len: 0,
        }
    }

    pub const fn len(self) -> usize {
        self.len as usize
    }

    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    pub fn iter(&self) -> impl Iterator<Item = &IntentNegotiationEffect> {
        self.items
            .iter()
            .take(self.len as usize)
            .filter_map(Option::as_ref)
    }
}
