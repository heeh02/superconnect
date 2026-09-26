//! Canonical `request_keyframe` CONTROL wire codec.

use crate::receiver_progress::wire::{FlatObjectParser, Scalar};

pub const KEYFRAME_REQUEST_WIRE_MAX_BYTES_V1: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum KeyframeRequestReasonV1 {
    Unspecified = 0,
    UdpGap = 1,
    UdpReassemblyOverflow = 2,
    UdpAuth = 3,
    DecoderBacklog = 4,
    DecoderInputFailure = 5,
    DecoderNotReady = 6,
    DecoderError = 7,
    ConfigRearm = 8,
}

impl KeyframeRequestReasonV1 {
    fn name(self) -> Option<&'static str> {
        Some(match self {
            Self::Unspecified => return None,
            Self::UdpGap => "udp_gap",
            Self::UdpReassemblyOverflow => "udp_reassembly_overflow",
            Self::UdpAuth => "udp_auth",
            Self::DecoderBacklog => "decoder_backlog",
            Self::DecoderInputFailure => "decoder_input_failure",
            Self::DecoderNotReady => "decoder_not_ready",
            Self::DecoderError => "decoder_error",
            Self::ConfigRearm => "config_rearm",
        })
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "udp_gap" => Some(Self::UdpGap),
            "udp_reassembly_overflow" => Some(Self::UdpReassemblyOverflow),
            "udp_auth" => Some(Self::UdpAuth),
            "decoder_backlog" => Some(Self::DecoderBacklog),
            "decoder_input_failure" => Some(Self::DecoderInputFailure),
            "decoder_not_ready" => Some(Self::DecoderNotReady),
            "decoder_error" => Some(Self::DecoderError),
            "config_rearm" => Some(Self::ConfigRearm),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyframeRequestWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

pub fn encode_keyframe_request_wire_v1(
    reason: KeyframeRequestReasonV1,
) -> Result<String, KeyframeRequestWireErrorV1> {
    Ok(match reason.name() {
        Some(name) => format!(r#"{{"type":"request_keyframe","reason":"{name}"}}"#),
        None => r#"{"type":"request_keyframe"}"#.to_owned(),
    })
}

pub fn decode_keyframe_request_wire_v1(
    input: &[u8],
) -> Result<KeyframeRequestReasonV1, KeyframeRequestWireErrorV1> {
    if input.len() > KEYFRAME_REQUEST_WIRE_MAX_BYTES_V1 {
        return Err(KeyframeRequestWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| KeyframeRequestWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| KeyframeRequestWireErrorV1::Syntax)?;
    let mut fields = [None; 2];
    for (key, value) in entries {
        let index = match key {
            "type" => 0,
            "reason" => 1,
            _ => return Err(KeyframeRequestWireErrorV1::UnknownField),
        };
        if fields[index].replace(value).is_some() {
            return Err(KeyframeRequestWireErrorV1::DuplicateField);
        }
    }
    let Some(Scalar::Text(message_type)) = fields[0] else {
        return Err(if fields[0].is_none() {
            KeyframeRequestWireErrorV1::MissingField
        } else {
            KeyframeRequestWireErrorV1::InvalidValue
        });
    };
    if message_type != "request_keyframe" {
        return Err(KeyframeRequestWireErrorV1::InvalidValue);
    }
    match fields[1] {
        None => Ok(KeyframeRequestReasonV1::Unspecified),
        Some(Scalar::Text(value)) => {
            KeyframeRequestReasonV1::parse(value).ok_or(KeyframeRequestWireErrorV1::InvalidValue)
        }
        _ => Err(KeyframeRequestWireErrorV1::InvalidValue),
    }
}
