use crate::json_wire::{FlatObjectParser, Scalar};
use crate::session_generation::SessionGeneration;

use super::{
    CapabilityCommit, CapabilityOffer, CapabilitySelection, CapabilitySet, MediaRole,
    NegotiationEvent, ProjectionIntent, TransportKind, KNOWN_CAPABILITY_BITS,
    NEGOTIATION_VERSION_1,
};

pub const CAPABILITY_WIRE_TYPE_V1: &str = "capability";
pub const CAPABILITY_WIRE_MAX_BYTES_V1: usize = 1024;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityWireKindV1 {
    Offer = 1,
    Selection = 2,
    Commit = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilityWireMessageV1 {
    pub kind: CapabilityWireKindV1,
    pub generation: SessionGeneration,
    pub negotiation_version: u16,
    pub capabilities: CapabilitySet,
    pub offerer_role: MediaRole,
    pub selector_role: MediaRole,
    pub projection: ProjectionIntent,
    pub transport: TransportKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
    InvariantViolation,
    UnsupportedEvent,
}

impl CapabilityWireMessageV1 {
    pub fn try_from_event(event: NegotiationEvent) -> Result<Self, CapabilityWireErrorV1> {
        let value = match event {
            NegotiationEvent::Offer(value) => Self {
                kind: CapabilityWireKindV1::Offer,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                capabilities: value.capabilities,
                offerer_role: value.local_role,
                selector_role: value.desired_peer_role,
                projection: value.projection,
                transport: value.transport,
            },
            NegotiationEvent::Selection(value) => Self {
                kind: CapabilityWireKindV1::Selection,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                capabilities: CapabilitySet::EMPTY,
                offerer_role: value.offerer_role,
                selector_role: value.selector_role,
                projection: value.projection,
                transport: value.transport,
            },
            NegotiationEvent::Commit(value) => Self {
                kind: CapabilityWireKindV1::Commit,
                generation: value.generation,
                negotiation_version: value.negotiation_version,
                capabilities: CapabilitySet::EMPTY,
                offerer_role: value.offerer_role,
                selector_role: value.selector_role,
                projection: value.projection,
                transport: value.transport,
            },
            NegotiationEvent::PeerHello { .. } => {
                return Err(CapabilityWireErrorV1::UnsupportedEvent)
            }
        };
        validate(value)?;
        Ok(value)
    }

    pub fn try_into_event(self) -> Result<NegotiationEvent, CapabilityWireErrorV1> {
        validate(self)?;
        Ok(match self.kind {
            CapabilityWireKindV1::Offer => NegotiationEvent::Offer(CapabilityOffer {
                generation: self.generation,
                negotiation_version: self.negotiation_version,
                capabilities: self.capabilities,
                local_role: self.offerer_role,
                desired_peer_role: self.selector_role,
                projection: self.projection,
                transport: self.transport,
            }),
            CapabilityWireKindV1::Selection => NegotiationEvent::Selection(CapabilitySelection {
                generation: self.generation,
                negotiation_version: self.negotiation_version,
                offerer_role: self.offerer_role,
                selector_role: self.selector_role,
                projection: self.projection,
                transport: self.transport,
            }),
            CapabilityWireKindV1::Commit => NegotiationEvent::Commit(CapabilityCommit {
                generation: self.generation,
                negotiation_version: self.negotiation_version,
                offerer_role: self.offerer_role,
                selector_role: self.selector_role,
                projection: self.projection,
                transport: self.transport,
            }),
        })
    }
}

pub fn encode_capability_wire_v1(
    value: CapabilityWireMessageV1,
) -> Result<String, CapabilityWireErrorV1> {
    validate(value)?;
    Ok(format!(
        "{{\"type\":\"capability\",\"capabilityEnvelope\":{{\"kind\":\"{}\",\"generation\":\"{}\",\"version\":1,\"capabilities\":\"{}\",\"offererRole\":\"{}\",\"selectorRole\":\"{}\",\"projection\":\"{}\",\"transport\":\"tcp\"}}}}",
        kind_wire(value.kind), value.generation.get(), value.capabilities.bits(),
        role_wire(value.offerer_role), role_wire(value.selector_role),
        projection_wire(value.projection),
    ))
}

pub fn decode_capability_wire_v1(
    input: &[u8],
) -> Result<CapabilityWireMessageV1, CapabilityWireErrorV1> {
    if input.len() > CAPABILITY_WIRE_MAX_BYTES_V1 {
        return Err(CapabilityWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| CapabilityWireErrorV1::Syntax)?;
    let outer = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| CapabilityWireErrorV1::Syntax)?;
    let mut outer_fields = [None; 2];
    for (key, value) in outer {
        let index = match key {
            "type" => 0,
            "capabilityEnvelope" => 1,
            _ => return Err(CapabilityWireErrorV1::UnknownField),
        };
        if outer_fields[index].replace(value).is_some() {
            return Err(CapabilityWireErrorV1::DuplicateField);
        }
    }
    let Some(Scalar::Text(CAPABILITY_WIRE_TYPE_V1)) = outer_fields[0] else {
        return Err(CapabilityWireErrorV1::InvalidValue);
    };
    let Some(Scalar::Object(envelope)) = outer_fields[1] else {
        return Err(CapabilityWireErrorV1::MissingField);
    };
    let entries = FlatObjectParser::new(envelope)
        .parse()
        .map_err(|_| CapabilityWireErrorV1::Syntax)?;
    let mut fields = [None; 8];
    for (key, value) in entries {
        let index = field_index(key).ok_or(CapabilityWireErrorV1::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(CapabilityWireErrorV1::DuplicateField);
        }
    }
    if fields.iter().any(Option::is_none) {
        return Err(CapabilityWireErrorV1::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        _ => Err(CapabilityWireErrorV1::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(Scalar::Number(value)) => Ok(value),
        _ => Err(CapabilityWireErrorV1::InvalidValue),
    };
    if number_field(2)? != "1" || text_field(7)? != "tcp" {
        return Err(CapabilityWireErrorV1::InvalidValue);
    }
    let value = CapabilityWireMessageV1 {
        kind: parse_kind(text_field(0)?)?,
        generation: SessionGeneration::new(parse_decimal(text_field(1)?, false)?),
        negotiation_version: NEGOTIATION_VERSION_1,
        capabilities: CapabilitySet::from_bits(parse_decimal(text_field(3)?, true)?),
        offerer_role: parse_role(text_field(4)?)?,
        selector_role: parse_role(text_field(5)?)?,
        projection: parse_projection(text_field(6)?)?,
        transport: TransportKind::Tcp,
    };
    validate(value)?;
    Ok(value)
}

fn validate(value: CapabilityWireMessageV1) -> Result<(), CapabilityWireErrorV1> {
    let bits = value.capabilities.bits();
    if value.generation == SessionGeneration::INVALID
        || value.negotiation_version != NEGOTIATION_VERSION_1
        || value.offerer_role == value.selector_role
        || value.transport != TransportKind::Tcp
        || bits & !KNOWN_CAPABILITY_BITS != 0
        || (value.kind != CapabilityWireKindV1::Offer && bits != 0)
    {
        return Err(CapabilityWireErrorV1::InvariantViolation);
    }
    Ok(())
}

fn parse_decimal(value: &str, allow_zero: bool) -> Result<u64, CapabilityWireErrorV1> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(CapabilityWireErrorV1::InvalidValue);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|value| allow_zero || *value != 0)
        .ok_or(CapabilityWireErrorV1::InvalidValue)
}
fn field_index(value: &str) -> Option<usize> {
    [
        "kind",
        "generation",
        "version",
        "capabilities",
        "offererRole",
        "selectorRole",
        "projection",
        "transport",
    ]
    .iter()
    .position(|field| *field == value)
}
fn kind_wire(value: CapabilityWireKindV1) -> &'static str {
    match value {
        CapabilityWireKindV1::Offer => "offer",
        CapabilityWireKindV1::Selection => "selection",
        CapabilityWireKindV1::Commit => "commit",
    }
}
fn parse_kind(value: &str) -> Result<CapabilityWireKindV1, CapabilityWireErrorV1> {
    match value {
        "offer" => Ok(CapabilityWireKindV1::Offer),
        "selection" => Ok(CapabilityWireKindV1::Selection),
        "commit" => Ok(CapabilityWireKindV1::Commit),
        _ => Err(CapabilityWireErrorV1::InvalidValue),
    }
}
fn role_wire(value: MediaRole) -> &'static str {
    match value {
        MediaRole::Host => "host",
        MediaRole::Receiver => "receiver",
    }
}
fn parse_role(value: &str) -> Result<MediaRole, CapabilityWireErrorV1> {
    match value {
        "host" => Ok(MediaRole::Host),
        "receiver" => Ok(MediaRole::Receiver),
        _ => Err(CapabilityWireErrorV1::InvalidValue),
    }
}
fn projection_wire(value: ProjectionIntent) -> &'static str {
    match value {
        ProjectionIntent::Extend => "extend",
        ProjectionIntent::Mirror => "mirror",
        ProjectionIntent::Primary => "primary",
    }
}
fn parse_projection(value: &str) -> Result<ProjectionIntent, CapabilityWireErrorV1> {
    match value {
        "extend" => Ok(ProjectionIntent::Extend),
        "mirror" => Ok(ProjectionIntent::Mirror),
        "primary" => Ok(ProjectionIntent::Primary),
        _ => Err(CapabilityWireErrorV1::InvalidValue),
    }
}
