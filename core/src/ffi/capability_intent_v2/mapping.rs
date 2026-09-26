use std::mem::size_of;

use crate::capability::{
    IntentCapabilityCommit, IntentCapabilityOffer, IntentCapabilitySelection,
    IntentNegotiationConfig, IntentNegotiationEffect, IntentNegotiationEvent, IntentSessionBinding,
    NegotiationSide, RejectReason,
};
use crate::collaboration_intent::{
    IntentCapabilitySet, LocalRole, PeerCapabilityProfile, ProductCapabilityProfile,
    ResolvedIntent, SessionIntentDraft, Topology,
};
use crate::session_generation::SessionGeneration;

use super::schema::*;

fn decode_side(value: u8) -> Option<NegotiationSide> {
    match value {
        SC_CAPABILITY_INTENT_SIDE_OFFERER => Some(NegotiationSide::Offerer),
        SC_CAPABILITY_INTENT_SIDE_SELECTOR => Some(NegotiationSide::Selector),
        _ => None,
    }
}

pub(super) fn encode_side(value: NegotiationSide) -> u8 {
    match value {
        NegotiationSide::Offerer => SC_CAPABILITY_INTENT_SIDE_OFFERER,
        NegotiationSide::Selector => SC_CAPABILITY_INTENT_SIDE_SELECTOR,
    }
}

fn decode_role(value: u8) -> Option<LocalRole> {
    match value {
        1 => Some(LocalRole::Source),
        2 => Some(LocalRole::Sink),
        3 => Some(LocalRole::Relay),
        _ => None,
    }
}

fn decode_product(bits: u64) -> Option<ProductCapabilityProfile> {
    ProductCapabilityProfile::new(IntentCapabilitySet::try_from_bits(bits).ok()?).ok()
}

fn decode_peer(bits: u64) -> Option<PeerCapabilityProfile> {
    PeerCapabilityProfile::new(IntentCapabilitySet::try_from_bits(bits).ok()?).ok()
}

fn decode_draft(fields: [u8; 6]) -> Option<SessionIntentDraft> {
    SessionIntentDraft::parse(fields).ok()
}

fn decode_resolved(fields: [u8; 6]) -> Option<ResolvedIntent> {
    let draft = decode_draft(fields)?;
    if draft.local_role() == LocalRole::Relay && draft.topology() != Topology::Relayed {
        return None;
    }
    Some(ResolvedIntent::from_draft(draft))
}

fn event_intent(value: ScCapabilityIntentEventV2) -> Option<ResolvedIntent> {
    decode_resolved([
        value.local_role,
        value.source_topology,
        value.sink_presentation,
        value.input_policy,
        value.transport_preference,
        value.topology,
    ])
}

pub(super) fn decode_config(value: ScCapabilityIntentConfigV2) -> Option<IntentNegotiationConfig> {
    if value.generation == 0 || value.reserved != 0 {
        return None;
    }
    let draft = decode_draft([
        value.local_role,
        value.source_topology,
        value.sink_presentation,
        value.input_policy,
        value.transport_preference,
        value.topology,
    ])?;
    IntentNegotiationConfig::new(
        SessionGeneration::new(value.generation),
        decode_side(value.side)?,
        decode_role(value.desired_peer_role)?,
        decode_product(value.product_capabilities)?,
        decode_peer(value.peer_capabilities)?,
        draft,
    )
    .ok()
}

fn common_event_valid(value: &ScCapabilityIntentEventV2) -> bool {
    value.generation != 0
        && value.reserved0 == [0; 2]
        && value.reserved1 == 0
        && matches!(value.has_negotiation_version, 0 | 1)
}

pub(super) fn decode_event(value: ScCapabilityIntentEventV2) -> Option<IntentNegotiationEvent> {
    if !common_event_valid(&value) {
        return None;
    }
    let generation = SessionGeneration::new(value.generation);
    if value.event_type == SC_CAPABILITY_INTENT_EVENT_PEER_HELLO {
        if value.offerer_role != 0
            || value.selector_role != 0
            || value.projection != 0
            || value.transport != 0
            || value.local_role != 0
            || value.source_topology != 0
            || value.sink_presentation != 0
            || value.input_policy != 0
            || value.transport_preference != 0
            || value.topology != 0
            || (value.has_negotiation_version == 0 && value.negotiation_version != 0)
        {
            return None;
        }
        return Some(IntentNegotiationEvent::PeerHello {
            generation,
            negotiation_version: (value.has_negotiation_version == 1)
                .then_some(value.negotiation_version),
        });
    }
    if value.has_negotiation_version != 1 {
        return None;
    }
    let intent = event_intent(value)?;
    match value.event_type {
        SC_CAPABILITY_INTENT_EVENT_OFFER => {
            Some(IntentNegotiationEvent::Offer(IntentCapabilityOffer {
                generation,
                negotiation_version: value.negotiation_version,
                offerer_role: decode_role(value.offerer_role)?,
                desired_peer_role: decode_role(value.selector_role)?,
                projection: decode_draft_projection(value.projection)?,
                transport: decode_draft_transport(value.transport)?,
                resolved_intent: intent,
            }))
        }
        SC_CAPABILITY_INTENT_EVENT_SELECTION => Some(IntentNegotiationEvent::Selection(
            IntentCapabilitySelection {
                generation,
                negotiation_version: value.negotiation_version,
                offerer_role: decode_role(value.offerer_role)?,
                selector_role: decode_role(value.selector_role)?,
                projection: decode_draft_projection(value.projection)?,
                transport: decode_draft_transport(value.transport)?,
                resolved_intent: intent,
            },
        )),
        SC_CAPABILITY_INTENT_EVENT_COMMIT => {
            Some(IntentNegotiationEvent::Commit(IntentCapabilityCommit {
                generation,
                negotiation_version: value.negotiation_version,
                offerer_role: decode_role(value.offerer_role)?,
                selector_role: decode_role(value.selector_role)?,
                projection: decode_draft_projection(value.projection)?,
                transport: decode_draft_transport(value.transport)?,
                resolved_intent: intent,
            }))
        }
        _ => None,
    }
}

fn decode_draft_projection(value: u8) -> Option<crate::collaboration_intent::SourceTopology> {
    decode_draft([1, value, 1, 1, 1, 1]).map(|draft| draft.source_topology())
}

fn decode_draft_transport(value: u8) -> Option<crate::collaboration_intent::TransportPreference> {
    decode_draft([1, 1, 1, 1, value, 1]).map(|draft| draft.transport_preference())
}

fn effect_base(generation: SessionGeneration, effect_type: u8) -> ScCapabilityIntentEffectV2 {
    ScCapabilityIntentEffectV2 {
        struct_size: size_of::<ScCapabilityIntentEffectV2>() as u32,
        api_version: SC_CAPABILITY_INTENT_API_VERSION_V2,
        generation: generation.get(),
        effect_type,
        ..ScCapabilityIntentEffectV2::default()
    }
}

fn encode_intent(output: &mut ScCapabilityIntentEffectV2, intent: ResolvedIntent) {
    output.resolved_local_role = intent.local_role() as u8;
    output.resolved_source_topology = intent.source_topology() as u8;
    output.resolved_sink_presentation = intent.sink_presentation() as u8;
    output.resolved_input_policy = intent.input_policy() as u8;
    output.resolved_transport_preference = intent.transport_preference() as u8;
    output.resolved_topology = intent.topology() as u8;
}

fn encode_message(
    generation: SessionGeneration,
    effect_type: u8,
    version: u16,
    offerer: LocalRole,
    selector: LocalRole,
    intent: ResolvedIntent,
) -> ScCapabilityIntentEffectV2 {
    let mut output = effect_base(generation, effect_type);
    output.negotiation_version = version;
    output.offerer_role = offerer as u8;
    output.selector_role = selector as u8;
    output.projection = intent.source_topology() as u8;
    output.transport = intent.transport_preference() as u8;
    encode_intent(&mut output, intent);
    output
}

fn encode_binding(
    generation: SessionGeneration,
    effect_type: u8,
    binding: IntentSessionBinding,
) -> ScCapabilityIntentEffectV2 {
    let mut output = effect_base(generation, effect_type);
    output.local_role = binding.local_intent.local_role() as u8;
    output.peer_role = binding.peer_role as u8;
    output.projection = binding.local_intent.source_topology() as u8;
    output.transport = binding.local_intent.transport_preference() as u8;
    output.negotiated = u8::from(binding.negotiated);
    encode_intent(&mut output, binding.local_intent);
    output
}

pub(super) fn encode_effect(
    generation: SessionGeneration,
    effect: IntentNegotiationEffect,
) -> ScCapabilityIntentEffectV2 {
    match effect {
        IntentNegotiationEffect::SendOffer(value) => encode_message(
            value.generation,
            SC_CAPABILITY_INTENT_EFFECT_SEND_OFFER,
            value.negotiation_version,
            value.offerer_role,
            value.desired_peer_role,
            value.resolved_intent,
        ),
        IntentNegotiationEffect::SendSelection(value) => encode_message(
            value.generation,
            SC_CAPABILITY_INTENT_EFFECT_SEND_SELECTION,
            value.negotiation_version,
            value.offerer_role,
            value.selector_role,
            value.resolved_intent,
        ),
        IntentNegotiationEffect::SendCommit(value) => encode_message(
            value.generation,
            SC_CAPABILITY_INTENT_EFFECT_SEND_COMMIT,
            value.negotiation_version,
            value.offerer_role,
            value.selector_role,
            value.resolved_intent,
        ),
        IntentNegotiationEffect::Committed(value) => {
            encode_binding(generation, SC_CAPABILITY_INTENT_EFFECT_COMMITTED, value)
        }
        IntentNegotiationEffect::Connected(value) => {
            encode_binding(generation, SC_CAPABILITY_INTENT_EFFECT_CONNECTED, value)
        }
        IntentNegotiationEffect::Rejected(reason) => encode_rejected(generation, reason),
        IntentNegotiationEffect::Fatal(reason) => encode_fatal(generation, reason),
    }
}

fn encode_rejected(
    generation: SessionGeneration,
    reason: RejectReason,
) -> ScCapabilityIntentEffectV2 {
    match reason {
        RejectReason::OutOfOrder => ScCapabilityIntentEffectV2 {
            reason: SC_CAPABILITY_INTENT_REASON_OUT_OF_ORDER,
            ..effect_base(generation, SC_CAPABILITY_INTENT_EFFECT_REJECTED)
        },
        RejectReason::StaleGeneration { expected, received } => ScCapabilityIntentEffectV2 {
            reason: SC_CAPABILITY_INTENT_REASON_STALE_GENERATION,
            expected_generation: expected.get(),
            received_generation: received.get(),
            ..effect_base(generation, SC_CAPABILITY_INTENT_EFFECT_REJECTED)
        },
    }
}

fn encode_fatal(
    generation: SessionGeneration,
    reason: crate::capability::IntentFatalReason,
) -> ScCapabilityIntentEffectV2 {
    use crate::capability::IntentFatalReason;
    let mut output = effect_base(generation, SC_CAPABILITY_INTENT_EFFECT_FATAL);
    match reason {
        IntentFatalReason::UnsupportedVersion { expected, received } => {
            output.reason = SC_CAPABILITY_INTENT_REASON_UNSUPPORTED_VERSION;
            output.expected_version = expected;
            output.received_version = received;
        }
        IntentFatalReason::RoleMismatch { expected, received } => {
            output.reason = SC_CAPABILITY_INTENT_REASON_ROLE_MISMATCH;
            output.expected_role = expected as u8;
            output.received_role = received as u8;
        }
        IntentFatalReason::ProjectionMismatch { expected, received } => {
            output.reason = SC_CAPABILITY_INTENT_REASON_PROJECTION_MISMATCH;
            output.expected_projection = expected as u8;
            output.received_projection = received as u8;
        }
        IntentFatalReason::TransportMismatch { expected, received } => {
            output.reason = SC_CAPABILITY_INTENT_REASON_TRANSPORT_MISMATCH;
            output.expected_transport = expected as u8;
            output.received_transport = received as u8;
        }
        IntentFatalReason::IntentMismatch => {
            output.reason = SC_CAPABILITY_INTENT_REASON_INTENT_MISMATCH;
        }
        IntentFatalReason::CommitMismatch => {
            output.reason = SC_CAPABILITY_INTENT_REASON_COMMIT_MISMATCH;
        }
        IntentFatalReason::LegacyIntentMismatch => {
            output.reason = SC_CAPABILITY_INTENT_REASON_LEGACY_INTENT_MISMATCH;
        }
    }
    output
}
