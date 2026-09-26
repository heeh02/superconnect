//! Canonical `input_reset` CONTROL wire codec.

use crate::receiver_progress::wire::{FlatObjectParser, Scalar};

pub const INPUT_RESET_REASON_MAX_BYTES_V1: usize = 64;
pub const INPUT_RESET_WIRE_MAX_BYTES_V1: usize = 160;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputResetWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

fn valid_reason(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= INPUT_RESET_REASON_MAX_BYTES_V1
        && bytes[0].is_ascii_lowercase()
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'_')
}

pub fn encode_input_reset_wire_v1(reason: &str) -> Result<String, InputResetWireErrorV1> {
    if !valid_reason(reason) {
        return Err(InputResetWireErrorV1::InvalidValue);
    }
    Ok(format!(r#"{{"type":"input_reset","reason":"{reason}"}}"#))
}

pub fn decode_input_reset_wire_v1(input: &[u8]) -> Result<&str, InputResetWireErrorV1> {
    if input.len() > INPUT_RESET_WIRE_MAX_BYTES_V1 {
        return Err(InputResetWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| InputResetWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| InputResetWireErrorV1::Syntax)?;
    let mut fields = [None; 2];
    for (key, value) in entries {
        let index = match key {
            "type" => 0,
            "reason" => 1,
            _ => return Err(InputResetWireErrorV1::UnknownField),
        };
        if fields[index].replace(value).is_some() {
            return Err(InputResetWireErrorV1::DuplicateField);
        }
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        None => Err(InputResetWireErrorV1::MissingField),
        _ => Err(InputResetWireErrorV1::InvalidValue),
    };
    if text_field(0)? != "input_reset" {
        return Err(InputResetWireErrorV1::InvalidValue);
    }
    let reason = text_field(1)?;
    if !valid_reason(reason) {
        return Err(InputResetWireErrorV1::InvalidValue);
    }
    Ok(reason)
}
