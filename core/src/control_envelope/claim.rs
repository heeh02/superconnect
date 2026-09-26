use super::{ControlEnvelopeErrorV1, CONTROL_ENVELOPE_MAX_BYTES_V1};
use crate::control_envelope_types_generated::{
    CONTROL_LEGACY_WIRE_TYPES_V1, CONTROL_WIRE_TYPES_V1,
};
use crate::strict_json::{parse_strict_json, StrictJsonValue};
use zeroize::Zeroizing;

pub(super) fn parse_active_control_envelope_v1(
    input: &[u8],
) -> Result<(u32, Zeroizing<StrictJsonValue>), ControlEnvelopeErrorV1> {
    if input.len() > CONTROL_ENVELOPE_MAX_BYTES_V1 {
        return Err(ControlEnvelopeErrorV1::TooLarge);
    }
    let parsed = Zeroizing::new(
        parse_strict_json(input, CONTROL_ENVELOPE_MAX_BYTES_V1)
            .ok_or(ControlEnvelopeErrorV1::Malformed)?,
    );
    let object = parsed
        .as_object()
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    let message_type = object
        .iter()
        .find_map(|(key, value)| {
            (key == "type").then_some(match value {
                StrictJsonValue::String(value) if !value.is_empty() => Some(value.as_str()),
                _ => None,
            })
        })
        .flatten()
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    if CONTROL_LEGACY_WIRE_TYPES_V1.contains(&message_type) {
        return Err(ControlEnvelopeErrorV1::Legacy);
    }
    let kind = CONTROL_WIRE_TYPES_V1
        .iter()
        .find_map(|(wire, kind)| (*wire == message_type).then_some(*kind))
        .ok_or(ControlEnvelopeErrorV1::Unknown)?;
    Ok((kind, parsed))
}

/// Claim an active top-level type before validating its payload-specific fields.
pub fn claim_control_envelope_kind_v1(input: &[u8]) -> Result<u32, ControlEnvelopeErrorV1> {
    parse_active_control_envelope_v1(input).map(|(kind, _parsed)| kind)
}
