use crate::collaboration_intent::{
    IntentAxis, IntentCapability, IntentCapabilitySet, LocalRole, PeerCapabilityProfile,
    ProductCapabilityProfile,
};
use crate::session_generation::SessionGeneration;

pub const CAPABILITY_INTENT_PROFILE_WIRE_TYPE_V2: &str = "capability_intent_profile_v2";
pub const CAPABILITY_INTENT_PROFILE_SCHEMA_VERSION_V2: u16 = 2;
pub const CAPABILITY_INTENT_PROFILE_WIRE_MAX_BYTES_V2: usize = 768;
const FIELD_COUNT: usize = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CapabilityIntentProfileWireMessageV2 {
    generation: SessionGeneration,
    sender_role: LocalRole,
    peer_profile: PeerCapabilityProfile,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityIntentProfileWireErrorV2 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
    InvariantViolation,
}

impl CapabilityIntentProfileWireMessageV2 {
    /// Construct an advertisement only from the product-authorized local profile.
    pub fn try_from_product_profile(
        generation: SessionGeneration,
        sender_role: LocalRole,
        product_profile: ProductCapabilityProfile,
    ) -> Result<Self, CapabilityIntentProfileWireErrorV2> {
        Self::try_from_capabilities(generation, sender_role, product_profile.capabilities())
    }

    fn try_from_capabilities(
        generation: SessionGeneration,
        sender_role: LocalRole,
        capabilities: IntentCapabilitySet,
    ) -> Result<Self, CapabilityIntentProfileWireErrorV2> {
        if generation == SessionGeneration::INVALID
            || !capabilities.contains(IntentCapability::LocalRole(sender_role))
        {
            return Err(CapabilityIntentProfileWireErrorV2::InvariantViolation);
        }
        let peer_profile = PeerCapabilityProfile::new(capabilities)
            .map_err(|_| CapabilityIntentProfileWireErrorV2::InvariantViolation)?;
        Ok(Self {
            generation,
            sender_role,
            peer_profile,
        })
    }

    pub const fn generation(self) -> SessionGeneration {
        self.generation
    }

    pub const fn schema_version(self) -> u16 {
        CAPABILITY_INTENT_PROFILE_SCHEMA_VERSION_V2
    }

    pub const fn sender_role(self) -> LocalRole {
        self.sender_role
    }

    /// The received advertisement is an immutable peer-profile fact, never a product grant.
    pub const fn peer_profile(self) -> PeerCapabilityProfile {
        self.peer_profile
    }
}

pub fn encode_capability_intent_profile_wire_v2(
    value: CapabilityIntentProfileWireMessageV2,
) -> Result<String, CapabilityIntentProfileWireErrorV2> {
    let capabilities = value.peer_profile.capabilities();
    CapabilityIntentProfileWireMessageV2::try_from_capabilities(
        value.generation,
        value.sender_role,
        capabilities,
    )?;
    Ok(format!(
        "{{\"type\":\"{}\",\"schemaVersion\":{},\"generation\":\"{}\",\"senderRole\":\"{}\",\"localRoleBits\":\"{}\",\"sourceTopologyBits\":\"{}\",\"sinkPresentationBits\":\"{}\",\"inputPolicyBits\":\"{}\",\"transportPreferenceBits\":\"{}\",\"topologyBits\":\"{}\"}}",
        CAPABILITY_INTENT_PROFILE_WIRE_TYPE_V2,
        CAPABILITY_INTENT_PROFILE_SCHEMA_VERSION_V2,
        value.generation.get(),
        role_wire(value.sender_role),
        capabilities.bits_for_axis(IntentAxis::LocalRole),
        capabilities.bits_for_axis(IntentAxis::SourceTopology),
        capabilities.bits_for_axis(IntentAxis::SinkPresentation),
        capabilities.bits_for_axis(IntentAxis::InputPolicy),
        capabilities.bits_for_axis(IntentAxis::TransportPreference),
        capabilities.bits_for_axis(IntentAxis::Topology),
    ))
}

pub fn decode_capability_intent_profile_wire_v2(
    input: &[u8],
) -> Result<CapabilityIntentProfileWireMessageV2, CapabilityIntentProfileWireErrorV2> {
    if input.len() > CAPABILITY_INTENT_PROFILE_WIRE_MAX_BYTES_V2 {
        return Err(CapabilityIntentProfileWireErrorV2::TooLarge);
    }
    let text =
        std::str::from_utf8(input).map_err(|_| CapabilityIntentProfileWireErrorV2::Syntax)?;
    let entries = FlatProfileObjectParser::new(text).parse()?;
    let mut fields = [None; FIELD_COUNT];
    for (key, value) in entries {
        let index = field_index(key).ok_or(CapabilityIntentProfileWireErrorV2::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(CapabilityIntentProfileWireErrorV2::DuplicateField);
        }
    }
    if fields.iter().any(Option::is_none) {
        return Err(CapabilityIntentProfileWireErrorV2::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(ProfileScalar::Text(value)) => Ok(value),
        _ => Err(CapabilityIntentProfileWireErrorV2::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(ProfileScalar::Number(value)) => Ok(value),
        _ => Err(CapabilityIntentProfileWireErrorV2::InvalidValue),
    };
    if text_field(0)? != CAPABILITY_INTENT_PROFILE_WIRE_TYPE_V2
        || number_field(1)? != CAPABILITY_INTENT_PROFILE_SCHEMA_VERSION_V2.to_string()
    {
        return Err(CapabilityIntentProfileWireErrorV2::InvalidValue);
    }
    let generation = parse_canonical_nonzero_u64(text_field(2)?)?;
    let sender_role = parse_role(text_field(3)?)?;
    let axes = [
        (IntentAxis::LocalRole, text_field(4)?),
        (IntentAxis::SourceTopology, text_field(5)?),
        (IntentAxis::SinkPresentation, text_field(6)?),
        (IntentAxis::InputPolicy, text_field(7)?),
        (IntentAxis::TransportPreference, text_field(8)?),
        (IntentAxis::Topology, text_field(9)?),
    ];
    let mut capabilities = IntentCapabilitySet::EMPTY;
    for (axis, encoded) in axes {
        let bits = parse_canonical_nonzero_u64(encoded)?;
        let axis_set = IntentCapabilitySet::try_from_bits(bits)
            .map_err(|_| CapabilityIntentProfileWireErrorV2::InvalidValue)?;
        if axis_set.bits_for_axis(axis) != bits {
            return Err(CapabilityIntentProfileWireErrorV2::InvalidValue);
        }
        capabilities = capabilities.union(axis_set);
    }
    CapabilityIntentProfileWireMessageV2::try_from_capabilities(
        SessionGeneration::new(generation),
        sender_role,
        capabilities,
    )
}

fn parse_canonical_nonzero_u64(value: &str) -> Result<u64, CapabilityIntentProfileWireErrorV2> {
    if value.starts_with('0') || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(CapabilityIntentProfileWireErrorV2::InvalidValue);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|value| *value != 0)
        .ok_or(CapabilityIntentProfileWireErrorV2::InvalidValue)
}

fn parse_role(value: &str) -> Result<LocalRole, CapabilityIntentProfileWireErrorV2> {
    match value {
        "source" => Ok(LocalRole::Source),
        "sink" => Ok(LocalRole::Sink),
        "relay" => Ok(LocalRole::Relay),
        _ => Err(CapabilityIntentProfileWireErrorV2::InvalidValue),
    }
}

fn role_wire(value: LocalRole) -> &'static str {
    match value {
        LocalRole::Source => "source",
        LocalRole::Sink => "sink",
        LocalRole::Relay => "relay",
    }
}

fn field_index(value: &str) -> Option<usize> {
    [
        "type",
        "schemaVersion",
        "generation",
        "senderRole",
        "localRoleBits",
        "sourceTopologyBits",
        "sinkPresentationBits",
        "inputPolicyBits",
        "transportPreferenceBits",
        "topologyBits",
    ]
    .iter()
    .position(|field| *field == value)
}

#[derive(Clone, Copy)]
enum ProfileScalar<'a> {
    Text(&'a str),
    Number(&'a str),
}

struct FlatProfileObjectParser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> FlatProfileObjectParser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            offset: 0,
        }
    }

    fn parse(
        mut self,
    ) -> Result<Vec<(&'a str, ProfileScalar<'a>)>, CapabilityIntentProfileWireErrorV2> {
        if self.bytes.iter().any(|byte| !byte.is_ascii()) {
            return Err(CapabilityIntentProfileWireErrorV2::Syntax);
        }
        self.space();
        self.take(b'{')?;
        self.space();
        let mut result = Vec::with_capacity(FIELD_COUNT);
        if self.peek() == Some(b'}') {
            self.offset += 1;
        } else {
            loop {
                self.space();
                let key = self.string()?;
                self.space();
                self.take(b':')?;
                self.space();
                let value = if self.peek() == Some(b'\"') {
                    ProfileScalar::Text(self.string()?)
                } else {
                    ProfileScalar::Number(self.number()?)
                };
                result.push((key, value));
                self.space();
                match self.peek() {
                    Some(b',') => self.offset += 1,
                    Some(b'}') => {
                        self.offset += 1;
                        break;
                    }
                    _ => return Err(CapabilityIntentProfileWireErrorV2::Syntax),
                }
            }
        }
        self.space();
        if self.offset != self.bytes.len() {
            return Err(CapabilityIntentProfileWireErrorV2::Syntax);
        }
        Ok(result)
    }

    fn string(&mut self) -> Result<&'a str, CapabilityIntentProfileWireErrorV2> {
        self.take(b'\"')?;
        let start = self.offset;
        while let Some(byte) = self.peek() {
            if byte == b'\"' {
                let result = &self.text[start..self.offset];
                self.offset += 1;
                return Ok(result);
            }
            if byte == b'\\' || byte < 0x20 || !byte.is_ascii() {
                return Err(CapabilityIntentProfileWireErrorV2::Syntax);
            }
            self.offset += 1;
        }
        Err(CapabilityIntentProfileWireErrorV2::Syntax)
    }

    fn number(&mut self) -> Result<&'a str, CapabilityIntentProfileWireErrorV2> {
        let start = self.offset;
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.offset += 1;
        }
        if start == self.offset {
            return Err(CapabilityIntentProfileWireErrorV2::Syntax);
        }
        Ok(&self.text[start..self.offset])
    }

    fn take(&mut self, expected: u8) -> Result<(), CapabilityIntentProfileWireErrorV2> {
        if self.peek() != Some(expected) {
            return Err(CapabilityIntentProfileWireErrorV2::Syntax);
        }
        self.offset += 1;
        Ok(())
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.offset).copied()
    }

    fn space(&mut self) {
        while self
            .peek()
            .is_some_and(|byte| matches!(byte, b' ' | b'\n' | b'\r' | b'\t'))
        {
            self.offset += 1;
        }
    }
}
