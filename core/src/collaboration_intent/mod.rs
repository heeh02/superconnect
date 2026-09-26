//! Platform- and product-neutral collaboration intent resolution.
//!
//! Composition roots provide already-authorized local and peer profiles. This module parses six
//! fixed-width axes, validates the requested combination against both profiles, and returns an
//! immutable resolved fact. It performs no negotiation, I/O, entitlement lookup, or presentation.

mod profile;
mod resolver;
mod types;

pub use profile::{
    IntentCapabilityBitsError, IntentCapabilitySet, LegacyCapabilityBridgeError,
    PeerCapabilityProfile, ProductCapabilityProfile, ProfileError,
};
pub use resolver::{resolve_intent, IntentCombinationError, IntentResolutionError};
pub use types::{
    InputPolicy, IntentAxis, IntentCapability, IntentParseError, LegacyIntentBridgeError,
    LocalRole, ResolvedIntent, SessionIntentDraft, SinkPresentation, SourceTopology, Topology,
    TransportPreference, SESSION_INTENT_FIELD_COUNT,
};
