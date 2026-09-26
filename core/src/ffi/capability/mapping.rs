use std::mem::size_of;

use crate::capability::{
    CapabilityCommit, CapabilityOffer, CapabilitySelection, CapabilitySet, FatalReason, MediaRole,
    NegotiationConfig, NegotiationEffect, NegotiationEvent, NegotiationSide, ProjectionIntent,
    RejectReason, SessionBinding, TransportKind,
};
use crate::session_generation::SessionGeneration;

use super::super::SC_API_VERSION_V1;
use super::schema::*;

fn decode_side(value: u8) -> Option<NegotiationSide> {
    match value {
        SC_CAPABILITY_SIDE_OFFERER => Some(NegotiationSide::Offerer),
        SC_CAPABILITY_SIDE_SELECTOR => Some(NegotiationSide::Selector),
        _ => None,
    }
}

pub(super) fn encode_side(value: NegotiationSide) -> u8 {
    match value {
        NegotiationSide::Offerer => SC_CAPABILITY_SIDE_OFFERER,
        NegotiationSide::Selector => SC_CAPABILITY_SIDE_SELECTOR,
    }
}

fn decode_role(value: u8) -> Option<MediaRole> {
    match value {
        SC_CAPABILITY_ROLE_HOST => Some(MediaRole::Host),
        SC_CAPABILITY_ROLE_RECEIVER => Some(MediaRole::Receiver),
        _ => None,
    }
}

fn decode_projection(value: u8) -> Option<ProjectionIntent> {
    match value {
        SC_CAPABILITY_PROJECTION_EXTEND => Some(ProjectionIntent::Extend),
        SC_CAPABILITY_PROJECTION_MIRROR => Some(ProjectionIntent::Mirror),
        SC_CAPABILITY_PROJECTION_PRIMARY => Some(ProjectionIntent::Primary),
        _ => None,
    }
}

fn decode_transport(value: u8) -> Option<TransportKind> {
    match value {
        SC_CAPABILITY_TRANSPORT_TCP => Some(TransportKind::Tcp),
        _ => None,
    }
}

fn validate_capability_bits(bits: u64) -> Option<CapabilitySet> {
    if bits & !KNOWN_CAPABILITY_BITS == 0 {
        Some(CapabilitySet::from_bits(bits))
    } else {
        None
    }
}

pub(super) fn decode_config(value: ScCapabilityConfigV1) -> Option<NegotiationConfig> {
    if value.generation == 0
        || value.reserved0 != [0; 3]
        || value.reserved1 != 0
        || decode_transport(value.transport).is_none()
    {
        return None;
    }
    NegotiationConfig::new(
        SessionGeneration::new(value.generation),
        decode_side(value.side)?,
        decode_role(value.local_role)?,
        decode_role(value.desired_peer_role)?,
        decode_projection(value.projection)?,
        validate_capability_bits(value.authorized_capabilities)?,
    )
    .ok()
}

fn event_common_is_valid(value: &ScCapabilityEventV1) -> bool {
    value.generation != 0
        && value.reserved == [0; 8]
        && value.capabilities & !KNOWN_CAPABILITY_BITS == 0
        && matches!(value.has_negotiation_version, 0 | 1)
}

pub(super) fn decode_event(value: ScCapabilityEventV1) -> Option<NegotiationEvent> {
    if !event_common_is_valid(&value) {
        return None;
    }
    let generation = SessionGeneration::new(value.generation);
    match value.event_type {
        SC_CAPABILITY_EVENT_PEER_HELLO => {
            if value.capabilities != 0
                || value.offerer_role != 0
                || value.selector_role != 0
                || value.projection != 0
                || value.transport != 0
                || (value.has_negotiation_version == 0 && value.negotiation_version != 0)
            {
                return None;
            }
            Some(NegotiationEvent::PeerHello {
                generation,
                negotiation_version: (value.has_negotiation_version == 1)
                    .then_some(value.negotiation_version),
            })
        }
        SC_CAPABILITY_EVENT_OFFER => {
            if value.has_negotiation_version != 1 {
                return None;
            }
            Some(NegotiationEvent::Offer(CapabilityOffer {
                generation,
                negotiation_version: value.negotiation_version,
                capabilities: validate_capability_bits(value.capabilities)?,
                local_role: decode_role(value.offerer_role)?,
                desired_peer_role: decode_role(value.selector_role)?,
                projection: decode_projection(value.projection)?,
                transport: decode_transport(value.transport)?,
            }))
        }
        SC_CAPABILITY_EVENT_SELECTION => {
            if value.has_negotiation_version != 1 || value.capabilities != 0 {
                return None;
            }
            Some(NegotiationEvent::Selection(CapabilitySelection {
                generation,
                negotiation_version: value.negotiation_version,
                offerer_role: decode_role(value.offerer_role)?,
                selector_role: decode_role(value.selector_role)?,
                projection: decode_projection(value.projection)?,
                transport: decode_transport(value.transport)?,
            }))
        }
        SC_CAPABILITY_EVENT_COMMIT => {
            if value.has_negotiation_version != 1 || value.capabilities != 0 {
                return None;
            }
            Some(NegotiationEvent::Commit(CapabilityCommit {
                generation,
                negotiation_version: value.negotiation_version,
                offerer_role: decode_role(value.offerer_role)?,
                selector_role: decode_role(value.selector_role)?,
                projection: decode_projection(value.projection)?,
                transport: decode_transport(value.transport)?,
            }))
        }
        _ => None,
    }
}

fn effect_base(generation: SessionGeneration, effect_type: u8) -> ScCapabilityEffectV1 {
    ScCapabilityEffectV1 {
        struct_size: size_of::<ScCapabilityEffectV1>() as u32,
        api_version: SC_API_VERSION_V1,
        generation: generation.get(),
        effect_type,
        ..ScCapabilityEffectV1::default()
    }
}

#[derive(Clone, Copy)]
struct MessageEffect {
    generation: SessionGeneration,
    negotiation_version: u16,
    capabilities: CapabilitySet,
    offerer_role: MediaRole,
    selector_role: MediaRole,
    projection: ProjectionIntent,
    transport: TransportKind,
}

fn encode_message(effect_type: u8, message: MessageEffect) -> ScCapabilityEffectV1 {
    ScCapabilityEffectV1 {
        negotiation_version: message.negotiation_version,
        capabilities: message.capabilities.bits(),
        offerer_role: message.offerer_role as u8,
        selector_role: message.selector_role as u8,
        projection: message.projection as u8,
        transport: message.transport as u8,
        ..effect_base(message.generation, effect_type)
    }
}

fn encode_binding(
    generation: SessionGeneration,
    effect_type: u8,
    binding: SessionBinding,
) -> ScCapabilityEffectV1 {
    ScCapabilityEffectV1 {
        local_role: binding.local_role as u8,
        peer_role: binding.peer_role as u8,
        projection: binding.projection as u8,
        transport: binding.transport as u8,
        negotiated: u8::from(binding.negotiated),
        ..effect_base(generation, effect_type)
    }
}

pub(super) fn encode_effect(
    generation: SessionGeneration,
    effect: NegotiationEffect,
) -> ScCapabilityEffectV1 {
    match effect {
        NegotiationEffect::SendOffer(offer) => encode_message(
            SC_CAPABILITY_EFFECT_SEND_OFFER,
            MessageEffect {
                generation: offer.generation,
                negotiation_version: offer.negotiation_version,
                capabilities: offer.capabilities,
                offerer_role: offer.local_role,
                selector_role: offer.desired_peer_role,
                projection: offer.projection,
                transport: offer.transport,
            },
        ),
        NegotiationEffect::SendSelection(selection) => encode_message(
            SC_CAPABILITY_EFFECT_SEND_SELECTION,
            MessageEffect {
                generation: selection.generation,
                negotiation_version: selection.negotiation_version,
                capabilities: CapabilitySet::EMPTY,
                offerer_role: selection.offerer_role,
                selector_role: selection.selector_role,
                projection: selection.projection,
                transport: selection.transport,
            },
        ),
        NegotiationEffect::SendCommit(commit) => encode_message(
            SC_CAPABILITY_EFFECT_SEND_COMMIT,
            MessageEffect {
                generation: commit.generation,
                negotiation_version: commit.negotiation_version,
                capabilities: CapabilitySet::EMPTY,
                offerer_role: commit.offerer_role,
                selector_role: commit.selector_role,
                projection: commit.projection,
                transport: commit.transport,
            },
        ),
        NegotiationEffect::Committed(binding) => {
            encode_binding(generation, SC_CAPABILITY_EFFECT_COMMITTED, binding)
        }
        NegotiationEffect::Connected(binding) => {
            encode_binding(generation, SC_CAPABILITY_EFFECT_CONNECTED, binding)
        }
        NegotiationEffect::Rejected(reason) => match reason {
            RejectReason::OutOfOrder => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_OUT_OF_ORDER,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_REJECTED)
            },
            RejectReason::StaleGeneration { expected, received } => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_STALE_GENERATION,
                expected_generation: expected.get(),
                received_generation: received.get(),
                ..effect_base(generation, SC_CAPABILITY_EFFECT_REJECTED)
            },
        },
        NegotiationEffect::Fatal(reason) => match reason {
            FatalReason::UnsupportedVersion { expected, received } => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_UNSUPPORTED_VERSION,
                expected_version: expected,
                received_version: received,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_FATAL)
            },
            FatalReason::UnsupportedCapability { capability } => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_UNSUPPORTED_CAPABILITY,
                capability: capability as u8,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_FATAL)
            },
            FatalReason::RoleMismatch { expected, received } => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_ROLE_MISMATCH,
                expected_role: expected as u8,
                received_role: received as u8,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_FATAL)
            },
            FatalReason::ProjectionMismatch { expected, received } => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_PROJECTION_MISMATCH,
                expected_projection: expected as u8,
                received_projection: received as u8,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_FATAL)
            },
            FatalReason::CommitMismatch => ScCapabilityEffectV1 {
                reason: SC_CAPABILITY_REASON_COMMIT_MISMATCH,
                ..effect_base(generation, SC_CAPABILITY_EFFECT_FATAL)
            },
        },
    }
}
