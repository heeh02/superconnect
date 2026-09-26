use super::{
    IntentCapability, LocalRole, PeerCapabilityProfile, ProductCapabilityProfile, ResolvedIntent,
    SessionIntentDraft, Topology, TransportPreference,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentCombinationError {
    RelayRequiresRelayedTopology,
    NoCommonTransport,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentResolutionError {
    InvalidCombination(IntentCombinationError),
    ProductCapabilityMissing(IntentCapability),
    PeerCapabilityMissing(IntentCapability),
}

pub fn resolve_intent(
    product: ProductCapabilityProfile,
    peer: PeerCapabilityProfile,
    draft: SessionIntentDraft,
) -> Result<ResolvedIntent, IntentResolutionError> {
    if draft.local_role() == LocalRole::Relay && draft.topology() != Topology::Relayed {
        return Err(IntentResolutionError::InvalidCombination(
            IntentCombinationError::RelayRequiresRelayedTopology,
        ));
    }

    for capability in draft.capabilities() {
        if matches!(capability, IntentCapability::TransportPreference(_)) {
            continue;
        }
        if !product.supports(capability) {
            return Err(IntentResolutionError::ProductCapabilityMissing(capability));
        }
        let peer_capability = match capability {
            IntentCapability::LocalRole(LocalRole::Source) => {
                Some(IntentCapability::LocalRole(LocalRole::Sink))
            }
            IntentCapability::LocalRole(LocalRole::Sink) => {
                Some(IntentCapability::LocalRole(LocalRole::Source))
            }
            // A relay may serve a source, sink, or another relay. Peer profile construction already
            // guarantees at least one peer role, while topology carries the relayed-session fact.
            IntentCapability::LocalRole(LocalRole::Relay) => None,
            other => Some(other),
        };
        if let Some(peer_capability) = peer_capability {
            if !peer.supports(peer_capability) {
                return Err(IntentResolutionError::PeerCapabilityMissing(
                    peer_capability,
                ));
            }
        }
    }
    let transport = resolve_transport(product, peer, draft.transport_preference())?;
    Ok(ResolvedIntent::from_draft_with_transport(draft, transport))
}

fn resolve_transport(
    product: ProductCapabilityProfile,
    peer: PeerCapabilityProfile,
    requested: TransportPreference,
) -> Result<TransportPreference, IntentResolutionError> {
    if requested != TransportPreference::Automatic {
        let capability = IntentCapability::TransportPreference(requested);
        if !product.supports(capability) {
            return Err(IntentResolutionError::ProductCapabilityMissing(capability));
        }
        if !peer.supports(capability) {
            return Err(IntentResolutionError::PeerCapabilityMissing(capability));
        }
        return Ok(requested);
    }

    for candidate in [
        TransportPreference::LowestLatency,
        TransportPreference::Reliable,
    ] {
        let capability = IntentCapability::TransportPreference(candidate);
        if product.supports(capability) && peer.supports(capability) {
            return Ok(candidate);
        }
    }
    Err(IntentResolutionError::InvalidCombination(
        IntentCombinationError::NoCommonTransport,
    ))
}
