//! Platform-neutral role and capability negotiation.
//!
//! Product code supplies an already-authorized fixed-width capability set. This
//! reducer does not know products, prices, operating systems, sockets, or media
//! implementations; it only validates protocol values and emits bounded effects.

use crate::session_generation::SessionGeneration;

pub const NEGOTIATION_VERSION_1: u16 = 1;
pub const MAX_NEGOTIATION_EFFECTS: usize = 3;

const KNOWN_CAPABILITY_BITS: u64 = (1_u64 << CapabilityId::MediaHost as u8)
    | (1_u64 << CapabilityId::MediaReceiver as u8)
    | (1_u64 << CapabilityId::ProjectionExtend as u8)
    | (1_u64 << CapabilityId::ProjectionMirror as u8)
    | (1_u64 << CapabilityId::ProjectionPrimary as u8)
    | (1_u64 << CapabilityId::TransportTcp as u8);

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaRole {
    Host = 1,
    Receiver = 2,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectionIntent {
    Extend = 1,
    Mirror = 2,
    Primary = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportKind {
    Tcp = 1,
}

/// Stable bit positions used at the product/core and wire-codec boundaries.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityId {
    MediaHost = 0,
    MediaReceiver = 1,
    ProjectionExtend = 8,
    ProjectionMirror = 9,
    ProjectionPrimary = 10,
    TransportTcp = 16,
}

impl CapabilityId {
    pub const fn for_role(role: MediaRole) -> Self {
        match role {
            MediaRole::Host => Self::MediaHost,
            MediaRole::Receiver => Self::MediaReceiver,
        }
    }

    pub const fn for_projection(projection: ProjectionIntent) -> Self {
        match projection {
            ProjectionIntent::Extend => Self::ProjectionExtend,
            ProjectionIntent::Mirror => Self::ProjectionMirror,
            ProjectionIntent::Primary => Self::ProjectionPrimary,
        }
    }

    pub const fn for_transport(transport: TransportKind) -> Self {
        match transport {
            TransportKind::Tcp => Self::TransportTcp,
        }
    }

    const fn bit(self) -> u64 {
        1_u64 << self as u8
    }
}

/// Fixed-width, forward-compatible capability storage.
///
/// Unknown bits survive transport but are never selected by this version.
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CapabilitySet(u64);

impl CapabilitySet {
    pub const EMPTY: Self = Self(0);

    pub const fn from_bits(bits: u64) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u64 {
        self.0
    }

    pub const fn known_bits(self) -> u64 {
        self.0 & KNOWN_CAPABILITY_BITS
    }

    pub const fn contains(self, capability: CapabilityId) -> bool {
        self.0 & capability.bit() != 0
    }

    pub const fn with(self, capability: CapabilityId) -> Self {
        Self(self.0 | capability.bit())
    }

    pub const fn with_role(self, role: MediaRole) -> Self {
        self.with(CapabilityId::for_role(role))
    }

    pub const fn with_projection(self, projection: ProjectionIntent) -> Self {
        self.with(CapabilityId::for_projection(projection))
    }

    pub const fn with_transport(self, transport: TransportKind) -> Self {
        self.with(CapabilityId::for_transport(transport))
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// Handshake position only. It deliberately says nothing about media direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NegotiationSide {
    Offerer,
    Selector,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConfigError {
    InvalidGeneration,
    RoleCollision,
    MissingCapability { capability: CapabilityId },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NegotiationConfig {
    generation: SessionGeneration,
    side: NegotiationSide,
    local_role: MediaRole,
    desired_peer_role: MediaRole,
    projection: ProjectionIntent,
    authorized: CapabilitySet,
}

impl NegotiationConfig {
    pub fn new(
        generation: SessionGeneration,
        side: NegotiationSide,
        local_role: MediaRole,
        desired_peer_role: MediaRole,
        projection: ProjectionIntent,
        authorized: CapabilitySet,
    ) -> Result<Self, ConfigError> {
        if generation == SessionGeneration::INVALID {
            return Err(ConfigError::InvalidGeneration);
        }
        if local_role == desired_peer_role {
            return Err(ConfigError::RoleCollision);
        }
        for capability in [
            CapabilityId::for_role(local_role),
            CapabilityId::for_projection(projection),
            CapabilityId::TransportTcp,
        ] {
            if !authorized.contains(capability) {
                return Err(ConfigError::MissingCapability { capability });
            }
        }
        Ok(Self {
            generation,
            side,
            local_role,
            desired_peer_role,
            projection,
            authorized,
        })
    }

    pub const fn generation(self) -> SessionGeneration {
        self.generation
    }

    pub const fn side(self) -> NegotiationSide {
        self.side
    }

    pub const fn local_role(self) -> MediaRole {
        self.local_role
    }

    pub const fn desired_peer_role(self) -> MediaRole {
        self.desired_peer_role
    }

    pub const fn projection(self) -> ProjectionIntent {
        self.projection
    }

    pub const fn authorized(self) -> CapabilitySet {
        self.authorized
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilityOffer {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub capabilities: CapabilitySet,
    pub local_role: MediaRole,
    pub desired_peer_role: MediaRole,
    pub projection: ProjectionIntent,
    pub transport: TransportKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilitySelection {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: MediaRole,
    pub selector_role: MediaRole,
    pub projection: ProjectionIntent,
    pub transport: TransportKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilityCommit {
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: MediaRole,
    pub selector_role: MediaRole,
    pub projection: ProjectionIntent,
    pub transport: TransportKind,
}

impl CapabilityCommit {
    pub const fn from_selection(selection: CapabilitySelection) -> Self {
        Self {
            generation: selection.generation,
            negotiation_version: selection.negotiation_version,
            offerer_role: selection.offerer_role,
            selector_role: selection.selector_role,
            projection: selection.projection,
            transport: selection.transport,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionBinding {
    pub local_role: MediaRole,
    pub peer_role: MediaRole,
    pub projection: ProjectionIntent,
    pub transport: TransportKind,
    pub negotiated: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectReason {
    OutOfOrder,
    StaleGeneration {
        expected: SessionGeneration,
        received: SessionGeneration,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FatalReason {
    UnsupportedVersion {
        expected: u16,
        received: u16,
    },
    UnsupportedCapability {
        capability: CapabilityId,
    },
    RoleMismatch {
        expected: MediaRole,
        received: MediaRole,
    },
    ProjectionMismatch {
        expected: ProjectionIntent,
        received: ProjectionIntent,
    },
    CommitMismatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NegotiationEvent {
    PeerHello {
        generation: SessionGeneration,
        negotiation_version: Option<u16>,
    },
    Offer(CapabilityOffer),
    Selection(CapabilitySelection),
    Commit(CapabilityCommit),
}

impl NegotiationEvent {
    const fn generation(self) -> SessionGeneration {
        match self {
            Self::PeerHello { generation, .. } => generation,
            Self::Offer(offer) => offer.generation,
            Self::Selection(selection) => selection.generation,
            Self::Commit(commit) => commit.generation,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NegotiationEffect {
    SendOffer(CapabilityOffer),
    SendSelection(CapabilitySelection),
    SendCommit(CapabilityCommit),
    Committed(SessionBinding),
    Connected(SessionBinding),
    Rejected(RejectReason),
    Fatal(FatalReason),
}

/// Allocation-free effect list. Every reducer transition emits at most three effects.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NegotiationEffects {
    items: [Option<NegotiationEffect>; MAX_NEGOTIATION_EFFECTS],
    len: u8,
}

impl NegotiationEffects {
    pub const fn empty() -> Self {
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

    pub fn iter(&self) -> impl Iterator<Item = &NegotiationEffect> {
        self.items
            .iter()
            .take(self.len as usize)
            .filter_map(Option::as_ref)
    }
}

/// Deterministic role/capability reducer with no platform dependencies.
///
/// This is a single-owner stateful handle. It intentionally implements neither
/// `Clone` nor `Copy`, so one negotiated generation cannot fork into owners that
/// each emit terminal effects.
///
/// ```compile_fail
/// use superconnect_core::capability::{
///     CapabilitySet, MediaRole, NegotiationConfig, NegotiationSide,
///     ProjectionIntent, ScCapabilityNegotiation, TransportKind,
/// };
/// use superconnect_core::SessionGeneration;
/// let authorized = CapabilitySet::EMPTY
///     .with_role(MediaRole::Host)
///     .with_projection(ProjectionIntent::Extend)
///     .with_transport(TransportKind::Tcp);
/// let config = NegotiationConfig::new(
///     SessionGeneration::new(1),
///     NegotiationSide::Offerer,
///     MediaRole::Host,
///     MediaRole::Receiver,
///     ProjectionIntent::Extend,
///     authorized,
/// ).unwrap();
/// let reducer = ScCapabilityNegotiation::new(config);
/// let second_owner = reducer;
/// let _ = reducer.binding();
/// let _ = second_owner.binding();
/// ```
#[derive(Debug, PartialEq, Eq)]
pub struct ScCapabilityNegotiation {
    machine: machine::Machine<reducer::CapabilityProtocol>,
}

mod intent_v2;
mod machine;
mod reducer;
mod wire;
pub use intent_v2::*;
pub use wire::*;
