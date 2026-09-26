use crate::collaboration_intent::{
    LocalRole, ResolvedIntent, SessionIntentDraft, SourceTopology, Topology, TransportPreference,
};
use crate::json_wire::{FlatObjectParser, Scalar};
use crate::session_generation::SessionGeneration;

use super::{
    IntentCapabilityCommit, IntentCapabilityOffer, IntentCapabilitySelection,
    IntentNegotiationEvent, NEGOTIATION_VERSION_2,
};

pub const CAPABILITY_INTENT_WIRE_TYPE_V2: &str = "capability_intent_v2";
pub const CAPABILITY_INTENT_WIRE_MAX_BYTES_V2: usize = 1024;
const FIELD_COUNT: usize = 14;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityIntentWireKindV2 {
    Offer = 1,
    Selection = 2,
    Commit = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilityIntentWireMessageV2 {
    pub kind: CapabilityIntentWireKindV2,
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub offerer_role: LocalRole,
    pub selector_role: LocalRole,
    pub projection: SourceTopology,
    pub transport: TransportPreference,
    pub resolved_intent: ResolvedIntent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityIntentWireErrorV2 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
    InvariantViolation,
    UnsupportedEvent,
}

impl CapabilityIntentWireMessageV2 {
    pub fn try_from_event(
        event: IntentNegotiationEvent,
    ) -> Result<Self, CapabilityIntentWireErrorV2> {
        let value = match event {
            IntentNegotiationEvent::Offer(value) => Self {
                kind: CapabilityIntentWireKindV2::Offer,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                offerer_role: value.offerer_role,
                selector_role: value.desired_peer_role,
                projection: value.projection,
                transport: value.transport,
                resolved_intent: value.resolved_intent,
            },
            IntentNegotiationEvent::Selection(value) => Self {
                kind: CapabilityIntentWireKindV2::Selection,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                offerer_role: value.offerer_role,
                selector_role: value.selector_role,
                projection: value.projection,
                transport: value.transport,
                resolved_intent: value.resolved_intent,
            },
            IntentNegotiationEvent::Commit(value) => Self {
                kind: CapabilityIntentWireKindV2::Commit,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                offerer_role: value.offerer_role,
                selector_role: value.selector_role,
                projection: value.projection,
                transport: value.transport,
                resolved_intent: value.resolved_intent,
            },
            IntentNegotiationEvent::PeerHello { .. } => {
                return Err(CapabilityIntentWireErrorV2::UnsupportedEvent)
            }
        };
        validate(value)?;
        Ok(value)
    }

    pub fn try_into_event(self) -> Result<IntentNegotiationEvent, CapabilityIntentWireErrorV2> {
        validate(self)?;
        Ok(match self.kind {
            CapabilityIntentWireKindV2::Offer => {
                IntentNegotiationEvent::Offer(IntentCapabilityOffer {
                    generation: self.generation,
                    negotiation_version: self.negotiation_version,
                    offerer_role: self.offerer_role,
                    desired_peer_role: self.selector_role,
                    projection: self.projection,
                    transport: self.transport,
                    resolved_intent: self.resolved_intent,
                })
            }
            CapabilityIntentWireKindV2::Selection => {
                IntentNegotiationEvent::Selection(IntentCapabilitySelection {
                    generation: self.generation,
                    negotiation_version: self.negotiation_version,
                    offerer_role: self.offerer_role,
                    selector_role: self.selector_role,
                    projection: self.projection,
                    transport: self.transport,
                    resolved_intent: self.resolved_intent,
                })
            }
            CapabilityIntentWireKindV2::Commit => {
                IntentNegotiationEvent::Commit(IntentCapabilityCommit {
                    generation: self.generation,
                    negotiation_version: self.negotiation_version,
                    offerer_role: self.offerer_role,
                    selector_role: self.selector_role,
                    projection: self.projection,
                    transport: self.transport,
                    resolved_intent: self.resolved_intent,
                })
            }
        })
    }
}

pub fn encode_capability_intent_wire_v2(
    value: CapabilityIntentWireMessageV2,
) -> Result<String, CapabilityIntentWireErrorV2> {
    validate(value)?;
    let intent = value.resolved_intent;
    Ok(format!(
        "{{\"type\":\"{}\",\"kind\":\"{}\",\"generation\":\"{}\",\"negotiationVersion\":{},\"offererRole\":\"{}\",\"selectorRole\":\"{}\",\"projection\":\"{}\",\"transport\":\"{}\",\"localRole\":\"{}\",\"sourceTopology\":\"{}\",\"sinkPresentation\":\"{}\",\"inputPolicy\":\"{}\",\"transportPreference\":\"{}\",\"topology\":\"{}\"}}",
        CAPABILITY_INTENT_WIRE_TYPE_V2,
        kind_wire(value.kind),
        value.generation.get(),
        value.negotiation_version,
        role_wire(value.offerer_role),
        role_wire(value.selector_role),
        source_wire(value.projection),
        transport_wire(value.transport),
        role_wire(intent.local_role()),
        source_wire(intent.source_topology()),
        sink_wire(intent.sink_presentation()),
        input_wire(intent.input_policy()),
        transport_wire(intent.transport_preference()),
        topology_wire(intent.topology()),
    ))
}

pub fn decode_capability_intent_wire_v2(
    input: &[u8],
) -> Result<CapabilityIntentWireMessageV2, CapabilityIntentWireErrorV2> {
    if input.len() > CAPABILITY_INTENT_WIRE_MAX_BYTES_V2 {
        return Err(CapabilityIntentWireErrorV2::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| CapabilityIntentWireErrorV2::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| CapabilityIntentWireErrorV2::Syntax)?;
    let mut fields = [None; FIELD_COUNT];
    for (key, value) in entries {
        let index = field_index(key).ok_or(CapabilityIntentWireErrorV2::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(CapabilityIntentWireErrorV2::DuplicateField);
        }
    }
    if fields.iter().any(Option::is_none) {
        return Err(CapabilityIntentWireErrorV2::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(Scalar::Number(value)) => Ok(value),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    };
    if text_field(0)? != CAPABILITY_INTENT_WIRE_TYPE_V2 || number_field(3)? != "2" {
        return Err(CapabilityIntentWireErrorV2::InvalidValue);
    }
    let generation_text = text_field(2)?;
    if generation_text.starts_with('0')
        || !generation_text.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(CapabilityIntentWireErrorV2::InvalidValue);
    }
    let generation = generation_text
        .parse::<u64>()
        .ok()
        .filter(|value| *value != 0)
        .ok_or(CapabilityIntentWireErrorV2::InvalidValue)?;
    let draft = SessionIntentDraft::new(
        parse_role(text_field(8)?)?,
        parse_source(text_field(9)?)?,
        parse_sink(text_field(10)?)?,
        parse_input(text_field(11)?)?,
        parse_transport(text_field(12)?)?,
        parse_topology(text_field(13)?)?,
    );
    let value = CapabilityIntentWireMessageV2 {
        kind: parse_kind(text_field(1)?)?,
        generation: SessionGeneration::new(generation),
        negotiation_version: NEGOTIATION_VERSION_2,
        offerer_role: parse_role(text_field(4)?)?,
        selector_role: parse_role(text_field(5)?)?,
        projection: parse_source(text_field(6)?)?,
        transport: parse_transport(text_field(7)?)?,
        resolved_intent: ResolvedIntent::from_draft(draft),
    };
    validate(value)?;
    Ok(value)
}

fn validate(value: CapabilityIntentWireMessageV2) -> Result<(), CapabilityIntentWireErrorV2> {
    let intent = value.resolved_intent;
    let expected_role = match value.kind {
        CapabilityIntentWireKindV2::Offer => value.offerer_role,
        CapabilityIntentWireKindV2::Selection | CapabilityIntentWireKindV2::Commit => {
            value.selector_role
        }
    };
    if value.generation == SessionGeneration::INVALID
        || value.negotiation_version != NEGOTIATION_VERSION_2
        || value.offerer_role == value.selector_role
        || intent.local_role() != expected_role
        || value.projection != intent.source_topology()
        || value.transport != intent.transport_preference()
        || (intent.local_role() == LocalRole::Relay && intent.topology() != Topology::Relayed)
    {
        return Err(CapabilityIntentWireErrorV2::InvariantViolation);
    }
    Ok(())
}

fn field_index(value: &str) -> Option<usize> {
    [
        "type",
        "kind",
        "generation",
        "negotiationVersion",
        "offererRole",
        "selectorRole",
        "projection",
        "transport",
        "localRole",
        "sourceTopology",
        "sinkPresentation",
        "inputPolicy",
        "transportPreference",
        "topology",
    ]
    .iter()
    .position(|field| *field == value)
}

fn parse_kind(value: &str) -> Result<CapabilityIntentWireKindV2, CapabilityIntentWireErrorV2> {
    match value {
        "offer" => Ok(CapabilityIntentWireKindV2::Offer),
        "selection" => Ok(CapabilityIntentWireKindV2::Selection),
        "commit" => Ok(CapabilityIntentWireKindV2::Commit),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_role(value: &str) -> Result<LocalRole, CapabilityIntentWireErrorV2> {
    match value {
        "source" => Ok(LocalRole::Source),
        "sink" => Ok(LocalRole::Sink),
        "relay" => Ok(LocalRole::Relay),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_source(value: &str) -> Result<SourceTopology, CapabilityIntentWireErrorV2> {
    match value {
        "extend" => Ok(SourceTopology::Extend),
        "mirror" => Ok(SourceTopology::Mirror),
        "primary" => Ok(SourceTopology::Primary),
        "application" => Ok(SourceTopology::Application),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_sink(
    value: &str,
) -> Result<crate::collaboration_intent::SinkPresentation, CapabilityIntentWireErrorV2> {
    use crate::collaboration_intent::SinkPresentation::*;
    match value {
        "windowed" => Ok(Windowed),
        "fullscreen" => Ok(Fullscreen),
        "picture_in_picture" => Ok(PictureInPicture),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_input(
    value: &str,
) -> Result<crate::collaboration_intent::InputPolicy, CapabilityIntentWireErrorV2> {
    use crate::collaboration_intent::InputPolicy::*;
    match value {
        "view_only" => Ok(ViewOnly),
        "remote_control" => Ok(RemoteControl),
        "request_control" => Ok(RequestControl),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_transport(value: &str) -> Result<TransportPreference, CapabilityIntentWireErrorV2> {
    match value {
        "reliable" => Ok(TransportPreference::Reliable),
        "lowest_latency" => Ok(TransportPreference::LowestLatency),
        "automatic" => Ok(TransportPreference::Automatic),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn parse_topology(value: &str) -> Result<Topology, CapabilityIntentWireErrorV2> {
    match value {
        "direct" => Ok(Topology::Direct),
        "local_multi_peer" => Ok(Topology::LocalMultiPeer),
        "relayed" => Ok(Topology::Relayed),
        _ => Err(CapabilityIntentWireErrorV2::InvalidValue),
    }
}

fn kind_wire(value: CapabilityIntentWireKindV2) -> &'static str {
    match value {
        CapabilityIntentWireKindV2::Offer => "offer",
        CapabilityIntentWireKindV2::Selection => "selection",
        CapabilityIntentWireKindV2::Commit => "commit",
    }
}
fn role_wire(value: LocalRole) -> &'static str {
    match value {
        LocalRole::Source => "source",
        LocalRole::Sink => "sink",
        LocalRole::Relay => "relay",
    }
}
fn source_wire(value: SourceTopology) -> &'static str {
    match value {
        SourceTopology::Extend => "extend",
        SourceTopology::Mirror => "mirror",
        SourceTopology::Primary => "primary",
        SourceTopology::Application => "application",
    }
}
fn sink_wire(value: crate::collaboration_intent::SinkPresentation) -> &'static str {
    use crate::collaboration_intent::SinkPresentation::*;
    match value {
        Windowed => "windowed",
        Fullscreen => "fullscreen",
        PictureInPicture => "picture_in_picture",
    }
}
fn input_wire(value: crate::collaboration_intent::InputPolicy) -> &'static str {
    use crate::collaboration_intent::InputPolicy::*;
    match value {
        ViewOnly => "view_only",
        RemoteControl => "remote_control",
        RequestControl => "request_control",
    }
}
fn transport_wire(value: TransportPreference) -> &'static str {
    match value {
        TransportPreference::Reliable => "reliable",
        TransportPreference::LowestLatency => "lowest_latency",
        TransportPreference::Automatic => "automatic",
    }
}
fn topology_wire(value: Topology) -> &'static str {
    match value {
        Topology::Direct => "direct",
        Topology::LocalMultiPeer => "local_multi_peer",
        Topology::Relayed => "relayed",
    }
}
