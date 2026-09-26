//! Single portable authority for CONTROL JSON message classification.

use crate::auth_wire::{decode_auth_wire_v1, AuthWireMessageV1};
use crate::capability::{
    decode_capability_intent_profile_wire_v2, decode_capability_intent_wire_v2,
    decode_capability_wire_v1,
};
use crate::control_envelope_types_generated::*;
use crate::control_envelope_types_generated::{
    SC_CONTROL_ENVELOPE_FIELD_DETAIL_V1 as CONTROL_ENVELOPE_FIELD_DETAIL_V1,
    SC_CONTROL_ENVELOPE_FIELD_GENERATION_V1 as CONTROL_ENVELOPE_FIELD_GENERATION_V1,
    SC_CONTROL_ENVELOPE_FIELD_OPERATION_V1 as CONTROL_ENVELOPE_FIELD_OPERATION_V1,
    SC_CONTROL_ENVELOPE_FIELD_VALUE0_V1 as CONTROL_ENVELOPE_FIELD_VALUE0_V1,
};
use crate::input_ownership::decode_input_reset_wire_v1;
use crate::media_recovery::{
    decode_keyframe_request_wire_v1, decode_media_recovery_wire_v1, decode_video_config_wire_v1,
    MediaRecoveryWireTypeV1,
};
use crate::receiver_progress::decode_receiver_progress_wire_v1;
use crate::session::{
    decode_session_control_wire_v1, decode_session_hello_wire_v1, SessionControlWireKindV1,
    SessionHelloWireKindV1,
};
use crate::strict_json::{parse_strict_json, StrictJsonValue};

mod claim;
mod encode;
mod payload;
pub use claim::claim_control_envelope_kind_v1;
pub use encode::*;
pub use payload::ControlCapsUpdateV1;
pub const CONTROL_ENVELOPE_MAX_BYTES_V1: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ControlEnvelopeV1 {
    pub kind: u32,
    pub presence: u32,
    pub generation: u64,
    pub operation: u64,
    pub value0: u64,
    pub value1: u64,
    pub detail: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlEnvelopeErrorV1 {
    TooLarge,
    Malformed,
    Unknown,
    Legacy,
}

impl ControlEnvelopeV1 {
    fn new(kind: u32) -> Self {
        Self {
            kind,
            ..Self::default()
        }
    }

    fn generation(mut self, value: u64) -> Self {
        self.presence |= CONTROL_ENVELOPE_FIELD_GENERATION_V1;
        self.generation = value;
        self
    }

    fn operation(mut self, value: u64) -> Self {
        self.presence |= CONTROL_ENVELOPE_FIELD_OPERATION_V1;
        self.operation = value;
        self
    }

    fn value0(mut self, value: u64) -> Self {
        self.presence |= CONTROL_ENVELOPE_FIELD_VALUE0_V1;
        self.value0 = value;
        self
    }

    fn detail(mut self, value: u32) -> Self {
        self.presence |= CONTROL_ENVELOPE_FIELD_DETAIL_V1;
        self.detail = value;
        self
    }
}

pub fn decode_control_envelope_v1(
    input: &[u8],
) -> Result<ControlEnvelopeV1, ControlEnvelopeErrorV1> {
    let (kind, parsed) = claim::parse_active_control_envelope_v1(input)?;
    let object = parsed
        .as_object()
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    validate_known(kind, input, object).ok_or(ControlEnvelopeErrorV1::Malformed)
}

fn validate_known(
    kind: u32,
    input: &[u8],
    object: &[(String, StrictJsonValue)],
) -> Option<ControlEnvelopeV1> {
    let value = ControlEnvelopeV1::new(kind);
    match kind {
        SC_CONTROL_KIND_HELLO_V1 | SC_CONTROL_KIND_HELLO_ACK_V1 => {
            let hello = decode_session_hello_wire_v1(input).ok()?;
            let expected = if kind == SC_CONTROL_KIND_HELLO_V1 {
                SessionHelloWireKindV1::Hello
            } else {
                SessionHelloWireKindV1::HelloAck
            };
            (hello.kind == expected).then_some(value)
        }
        SC_CONTROL_KIND_AUTH_V1 | SC_CONTROL_KIND_AUTH_ACK_V1 | SC_CONTROL_KIND_PAIR_SECRET_V1 => {
            let auth = decode_auth_wire_v1(input).ok()?;
            let matches = matches!(
                (kind, auth),
                (SC_CONTROL_KIND_AUTH_V1, AuthWireMessageV1::Auth { .. })
                    | (
                        SC_CONTROL_KIND_AUTH_ACK_V1,
                        AuthWireMessageV1::AuthAck { .. }
                    )
                    | (
                        SC_CONTROL_KIND_PAIR_SECRET_V1,
                        AuthWireMessageV1::PairSecret { .. }
                    )
            );
            matches.then_some(value)
        }
        SC_CONTROL_KIND_CAPABILITY_V1 => {
            let message = decode_capability_wire_v1(input).ok()?;
            Some(value.generation(message.generation.get()))
        }
        SC_CONTROL_KIND_CAPABILITY_INTENT_PROFILE_V2_V1 => {
            let message = decode_capability_intent_profile_wire_v2(input).ok()?;
            Some(value.generation(message.generation().get()))
        }
        SC_CONTROL_KIND_CAPABILITY_INTENT_V2_V1 => {
            let message = decode_capability_intent_wire_v2(input).ok()?;
            Some(value.generation(message.generation.get()))
        }
        SC_CONTROL_KIND_PING_V1 | SC_CONTROL_KIND_PONG_V1 | SC_CONTROL_KIND_BYE_V1 => {
            let control = decode_session_control_wire_v1(input).ok()?;
            let expected = match kind {
                SC_CONTROL_KIND_PING_V1 => SessionControlWireKindV1::Ping,
                SC_CONTROL_KIND_PONG_V1 => SessionControlWireKindV1::Pong,
                _ => SessionControlWireKindV1::Bye,
            };
            (control.kind == expected).then_some(value)
        }
        SC_CONTROL_KIND_VIDEO_CONFIG_V1 => {
            decode_video_config_wire_v1(input).ok()?;
            Some(value)
        }
        SC_CONTROL_KIND_CAPS_UPDATE_V1 => {
            decode_control_caps_update_v1_from_object(object)?;
            Some(value)
        }
        SC_CONTROL_KIND_INPUT_RESET_V1 => {
            decode_input_reset_wire_v1(input).ok()?;
            Some(value)
        }
        SC_CONTROL_KIND_VIDEO_EPOCH_V1 => {
            exact_keys(object, &["type", "videoEpoch", "firstFrameSeq"])?;
            let epoch = u32_field(object, "videoEpoch")?;
            let first = u32_field(object, "firstFrameSeq")?;
            Some(value.generation(u64::from(epoch)).value0(u64::from(first)))
        }
        SC_CONTROL_KIND_RECOVERY_ANCHOR_V1
        | SC_CONTROL_KIND_ANCHOR_ACCEPTED_V1
        | SC_CONTROL_KIND_ANCHOR_OUTPUT_V1 => {
            if let Ok(message) = decode_media_recovery_wire_v1(input) {
                let expected = match kind {
                    SC_CONTROL_KIND_RECOVERY_ANCHOR_V1 => MediaRecoveryWireTypeV1::Anchor,
                    SC_CONTROL_KIND_ANCHOR_ACCEPTED_V1 => MediaRecoveryWireTypeV1::Accepted,
                    _ => MediaRecoveryWireTypeV1::Output,
                };
                return (message.message_type == expected).then_some(
                    value
                        .generation(message.generation)
                        .operation(message.recovery_id)
                        .value0(message.source_frame_id),
                );
            }
            if kind != SC_CONTROL_KIND_ANCHOR_ACCEPTED_V1 {
                return None;
            }
            exact_keys(
                object,
                &["type", "streamEpochHi", "streamEpochLo", "sourceFrameId"],
            )?;
            let high = u32_field(object, "streamEpochHi")?;
            let low = u32_field(object, "streamEpochLo")?;
            let source = nonzero_u32_field(object, "sourceFrameId")?;
            let generation = u64::from(high) << 32 | u64::from(low);
            (generation != 0).then_some(value.generation(generation).value0(u64::from(source)))
        }
        SC_CONTROL_KIND_REQUEST_KEYFRAME_V1 => {
            let reason = decode_keyframe_request_wire_v1(input).ok()?;
            Some(value.detail(reason as u32))
        }
        SC_CONTROL_KIND_RECEIVER_PROGRESS_V1 => {
            let message = decode_receiver_progress_wire_v1(input).ok()?;
            Some(
                value
                    .generation(u64::from(message.session_generation))
                    .value0(message.decoder_generation),
            )
        }
        SC_CONTROL_KIND_ERROR_V1 => validate_error(object).map(|detail| value.detail(detail)),
        SC_CONTROL_KIND_TEXT_V1 => {
            exact_keys(object, &["type", "text"])?;
            let text = string_field(object, "text")?;
            (!text.is_empty() && text.len() <= 4096 && !text.chars().any(|value| value == '\0'))
                .then_some(value.value0(text.len() as u64))
        }
        SC_CONTROL_KIND_UDP_PROBE_ACK_V1 => {
            exact_keys(object, &["type", "token"])?;
            Some(value.operation(u64::from(nonzero_u32_field(object, "token")?)))
        }
        SC_CONTROL_KIND_UDP_UNAVAILABLE_V1 => {
            exact_keys(object, &["type"])?;
            Some(value)
        }
        _ => None,
    }
}

pub fn decode_control_caps_update_v1(
    input: &[u8],
) -> Result<ControlCapsUpdateV1, ControlEnvelopeErrorV1> {
    if input.len() > CONTROL_ENVELOPE_MAX_BYTES_V1 {
        return Err(ControlEnvelopeErrorV1::TooLarge);
    }
    let object = parse_strict_json(input, CONTROL_ENVELOPE_MAX_BYTES_V1)
        .and_then(StrictJsonValue::object)
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    decode_control_caps_update_v1_from_object(&object).ok_or(ControlEnvelopeErrorV1::Malformed)
}

pub fn decode_control_text_wire_v1(input: &[u8]) -> Result<String, ControlEnvelopeErrorV1> {
    let object = parse_strict_json(input, CONTROL_ENVELOPE_MAX_BYTES_V1)
        .and_then(StrictJsonValue::object)
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    exact_keys(&object, &["type", "text"]).ok_or(ControlEnvelopeErrorV1::Malformed)?;
    if string_field(&object, "type") != Some("text") {
        return Err(ControlEnvelopeErrorV1::Malformed);
    }
    let text = string_field(&object, "text").ok_or(ControlEnvelopeErrorV1::Malformed)?;
    if text.is_empty() || text.len() > 4096 || text.chars().any(|value| value == '\0') {
        return Err(ControlEnvelopeErrorV1::Malformed);
    }
    Ok(text.to_owned())
}

fn validate_error(object: &[(String, StrictJsonValue)]) -> Option<u32> {
    if object.len() < 2
        || !keys_are_subset(object, &["type", "code", "message", "reason"])
        || string_field(object, "type") != Some("error")
    {
        return None;
    }
    let reason = optional_string_field(object, "reason")?;
    let code = optional_string_field(object, "code")?;
    let message = optional_string_field(object, "message")?;
    if [reason, code, message]
        .into_iter()
        .flatten()
        .any(|value| value.is_empty() || value.len() > 128)
    {
        return None;
    }
    if reason.is_some() && code.is_some()
        || code.is_some_and(|value| value != "version_mismatch")
        || reason.is_some_and(|value| value == "version_mismatch")
    {
        return None;
    }
    let selected = reason.or(code).or(message)?;
    let detail = CONTROL_ERROR_REASONS_V1
        .iter()
        .find_map(|(wire, kind)| (*wire == selected).then_some(*kind))
        .unwrap_or(SC_CONTROL_ERROR_REASON_UNKNOWN_V1);
    if detail != SC_CONTROL_ERROR_REASON_UNKNOWN_V1 && (reason.is_some() || code.is_some()) {
        let canonical_message = if detail == SC_CONTROL_ERROR_REASON_SESSION_CAPACITY_V1 {
            "session_busy"
        } else {
            selected
        };
        if message.is_some_and(|value| value != canonical_message) {
            return None;
        }
    }
    Some(detail)
}

fn decode_control_caps_update_v1_from_object(
    object: &[(String, StrictJsonValue)],
) -> Option<ControlCapsUpdateV1> {
    exact_keys(object, &["type", "caps"])?;
    if string_field(object, "type") != Some("caps_update") {
        return None;
    }
    let Some(StrictJsonValue::Object(caps)) = field(object, "caps") else {
        return None;
    };
    let allowed = [
        "codecs",
        "hdr",
        "pen",
        "refreshRate",
        "refreshRateMax",
        "scale",
        "screenHeight",
        "screenWidth",
    ];
    if !keys_are_subset(caps, &allowed) {
        return None;
    }
    let Some(StrictJsonValue::Array(codecs)) = field(caps, "codecs") else {
        return None;
    };
    if codecs.is_empty()
        || codecs.len() > 2
        || codecs.iter().any(|codec| {
            !matches!(codec, StrictJsonValue::String(value) if value == "h264" || value == "hevc")
        })
    {
        return None;
    }
    let mut codec_bits = 0;
    for codec in codecs {
        if let StrictJsonValue::String(value) = codec {
            let bit = if value == "h264" { 1 } else { 2 };
            if codec_bits & bit != 0 {
                return None;
            }
            codec_bits |= bit;
        }
    }
    let screen_width = u32_field(caps, "screenWidth")?;
    let screen_height = u32_field(caps, "screenHeight")?;
    for name in ["screenWidth", "screenHeight"] {
        let value = u64_field(caps, name)?;
        if !(16..=8192).contains(&value) {
            return None;
        }
    }
    for name in ["refreshRate", "refreshRateMax"] {
        if let Some(value) = optional_u64_field(caps, name) {
            if value == 0 || value > 240 {
                return None;
            }
        } else if field(caps, name).is_some() {
            return None;
        }
    }
    let scale = if let Some(scale) = field(caps, "scale") {
        let value = match scale {
            StrictJsonValue::U64(value) => *value as f64,
            StrictJsonValue::F64(value) => *value,
            _ => return None,
        };
        if !value.is_finite() || !(0.5..=8.0).contains(&value) {
            return None;
        }
        Some(value)
    } else {
        None
    };
    if field(caps, "pen").is_some_and(|value| !matches!(value, StrictJsonValue::Bool(_))) {
        return None;
    }
    let pen = bool_field(caps, "pen");
    let mut hdr_hlg = None;
    let mut hdr_pq = None;
    if let Some(hdr) = field(caps, "hdr") {
        let StrictJsonValue::Object(values) = hdr else {
            return None;
        };
        if values.is_empty()
            || !keys_are_subset(values, &["hlg", "pq"])
            || values
                .iter()
                .any(|(_, value)| !matches!(value, StrictJsonValue::Bool(_)))
        {
            return None;
        }
        hdr_hlg = bool_field(values, "hlg");
        hdr_pq = bool_field(values, "pq");
    }
    ControlCapsUpdateV1 {
        codecs: codec_bits,
        screen_width,
        screen_height,
        scale,
        refresh_rate: u32_field(caps, "refreshRate"),
        refresh_rate_max: u32_field(caps, "refreshRateMax"),
        pen,
        hdr_hlg,
        hdr_pq,
    }
    .validate()
    .ok()
}

fn exact_keys(object: &[(String, StrictJsonValue)], expected: &[&str]) -> Option<()> {
    (object.len() == expected.len()
        && object
            .iter()
            .all(|(key, _)| expected.iter().any(|expected| key == expected)))
    .then_some(())
}

fn keys_are_subset(object: &[(String, StrictJsonValue)], allowed: &[&str]) -> bool {
    object
        .iter()
        .all(|(key, _)| allowed.iter().any(|allowed| key == allowed))
}

fn field<'a>(object: &'a [(String, StrictJsonValue)], name: &str) -> Option<&'a StrictJsonValue> {
    object
        .iter()
        .find_map(|(key, value)| (key == name).then_some(value))
}

fn string_field<'a>(object: &'a [(String, StrictJsonValue)], name: &str) -> Option<&'a str> {
    match field(object, name)? {
        StrictJsonValue::String(value) => Some(value),
        _ => None,
    }
}

fn optional_string_field<'a>(
    object: &'a [(String, StrictJsonValue)],
    name: &str,
) -> Option<Option<&'a str>> {
    match field(object, name) {
        None => Some(None),
        Some(StrictJsonValue::String(value)) => Some(Some(value)),
        _ => None,
    }
}

fn u64_field(object: &[(String, StrictJsonValue)], name: &str) -> Option<u64> {
    match field(object, name)? {
        StrictJsonValue::U64(value) => Some(*value),
        _ => None,
    }
}

fn optional_u64_field(object: &[(String, StrictJsonValue)], name: &str) -> Option<u64> {
    u64_field(object, name)
}

fn bool_field(object: &[(String, StrictJsonValue)], name: &str) -> Option<bool> {
    match field(object, name)? {
        StrictJsonValue::Bool(value) => Some(*value),
        _ => None,
    }
}

fn u32_field(object: &[(String, StrictJsonValue)], name: &str) -> Option<u32> {
    u32::try_from(u64_field(object, name)?).ok()
}

fn nonzero_u32_field(object: &[(String, StrictJsonValue)], name: &str) -> Option<u32> {
    u32_field(object, name).filter(|value| *value != 0)
}
