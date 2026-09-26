use crate::collaboration_intent::{
    IntentCapability, IntentCapabilitySet, IntentCombinationError, IntentResolutionError,
    PeerCapabilityProfile, ProductCapabilityProfile, ResolvedIntent, SessionIntentDraft,
};

use super::super::SC_API_VERSION_V1;
use super::schema::*;

pub(super) fn decode_product_profile(
    value: ScCollaborationIntentProfileV1,
) -> Option<ProductCapabilityProfile> {
    if value.reserved != 0 || value.capabilities & !KNOWN_INTENT_BITS != 0 {
        return None;
    }
    ProductCapabilityProfile::new(IntentCapabilitySet::try_from_bits(value.capabilities).ok()?).ok()
}

pub(super) fn decode_peer_profile(
    value: ScCollaborationIntentProfileV1,
) -> Option<PeerCapabilityProfile> {
    if value.reserved != 0 || value.capabilities & !KNOWN_INTENT_BITS != 0 {
        return None;
    }
    PeerCapabilityProfile::new(IntentCapabilitySet::try_from_bits(value.capabilities).ok()?).ok()
}

pub(super) fn decode_draft(value: ScCollaborationIntentDraftV1) -> Option<SessionIntentDraft> {
    if value.reserved0 != [0; 2] || value.reserved1 != 0 {
        return None;
    }
    SessionIntentDraft::parse([
        value.local_role,
        value.source_topology,
        value.sink_presentation,
        value.input_policy,
        value.transport_preference,
        value.topology,
    ])
    .ok()
}

pub(super) fn encode_resolved(
    value: Option<ResolvedIntent>,
    struct_size: u32,
) -> ScCollaborationIntentResolvedV1 {
    let mut encoded = ScCollaborationIntentResolvedV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        ..ScCollaborationIntentResolvedV1::default()
    };
    if let Some(value) = value {
        encoded.local_role = value.local_role() as u8;
        encoded.source_topology = value.source_topology() as u8;
        encoded.sink_presentation = value.sink_presentation() as u8;
        encoded.input_policy = value.input_policy() as u8;
        encoded.transport_preference = value.transport_preference() as u8;
        encoded.topology = value.topology() as u8;
    }
    encoded
}

pub(super) fn encode_resolution_error(
    error: Option<IntentResolutionError>,
    draft: SessionIntentDraft,
    struct_size: u32,
) -> ScCollaborationIntentErrorV1 {
    let mut encoded = ScCollaborationIntentErrorV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        ..ScCollaborationIntentErrorV1::default()
    };
    let Some(error) = error else {
        return encoded;
    };
    match error {
        IntentResolutionError::InvalidCombination(reason) => {
            encoded.error_type = SC_COLLABORATION_INTENT_ERROR_INVALID_COMBINATION;
            encoded.side = SC_COLLABORATION_INTENT_SIDE_NONE;
            match reason {
                IntentCombinationError::RelayRequiresRelayedTopology => {
                    encoded.axis = SC_COLLABORATION_INTENT_AXIS_TOPOLOGY;
                    encoded.value = draft.topology() as u8;
                }
                IntentCombinationError::NoCommonTransport => {
                    encoded.axis = SC_COLLABORATION_INTENT_AXIS_TRANSPORT_PREFERENCE;
                    encoded.value = draft.transport_preference() as u8;
                }
            }
        }
        IntentResolutionError::ProductCapabilityMissing(capability) => {
            encode_missing(
                &mut encoded,
                SC_COLLABORATION_INTENT_SIDE_PRODUCT,
                capability,
            );
        }
        IntentResolutionError::PeerCapabilityMissing(capability) => {
            encode_missing(&mut encoded, SC_COLLABORATION_INTENT_SIDE_PEER, capability);
        }
    }
    encoded
}

fn encode_missing(
    output: &mut ScCollaborationIntentErrorV1,
    side: u8,
    capability: IntentCapability,
) {
    output.error_type = SC_COLLABORATION_INTENT_ERROR_MISSING_CAPABILITY;
    output.side = side;
    output.axis = capability.axis() as u8;
    output.value = capability_value(capability);
}

fn capability_value(capability: IntentCapability) -> u8 {
    match capability {
        IntentCapability::LocalRole(value) => value as u8,
        IntentCapability::SourceTopology(value) => value as u8,
        IntentCapability::SinkPresentation(value) => value as u8,
        IntentCapability::InputPolicy(value) => value as u8,
        IntentCapability::TransportPreference(value) => value as u8,
        IntentCapability::Topology(value) => value as u8,
    }
}
