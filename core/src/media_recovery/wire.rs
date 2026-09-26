//! Canonical reliable-anchor CONTROL wire codec.

use crate::receiver_progress::wire::{canonical_u64, FlatObjectParser, Scalar};

pub const MEDIA_RECOVERY_WIRE_SCHEMA_VERSION_V1: u32 = 1;
pub const MEDIA_RECOVERY_WIRE_MAX_BYTES_V1: usize = 512;
const FIELD_COUNT: usize = 7;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum MediaRecoveryWireTypeV1 {
    Anchor = 1,
    Accepted = 2,
    Output = 3,
}

impl MediaRecoveryWireTypeV1 {
    fn name(self) -> &'static str {
        match self {
            Self::Anchor => "recovery_anchor",
            Self::Accepted => "anchor_accepted",
            Self::Output => "anchor_output",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "recovery_anchor" => Some(Self::Anchor),
            "anchor_accepted" => Some(Self::Accepted),
            "anchor_output" => Some(Self::Output),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaRecoveryWireV1 {
    pub message_type: MediaRecoveryWireTypeV1,
    pub generation: u64,
    pub recovery_id: u64,
    pub source_frame_id: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaRecoveryWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

impl MediaRecoveryWireV1 {
    pub fn validate(self) -> Result<Self, MediaRecoveryWireErrorV1> {
        if self.generation == 0
            || self.recovery_id == 0
            || self.source_frame_id == 0
            || self.source_frame_id > u64::from(u32::MAX)
        {
            return Err(MediaRecoveryWireErrorV1::InvalidValue);
        }
        Ok(self)
    }
}

pub fn encode_media_recovery_wire_v1(
    value: MediaRecoveryWireV1,
) -> Result<String, MediaRecoveryWireErrorV1> {
    let value = value.validate()?;
    Ok(format!(
        "{{\"type\":\"{}\",\"schemaVersion\":1,\"streamGenerationHi\":{},\"streamGenerationLo\":{},\"recoveryIdHi\":{},\"recoveryIdLo\":{},\"sourceFrameId\":{}}}",
        value.message_type.name(),
        value.generation >> 32,
        value.generation as u32,
        value.recovery_id >> 32,
        value.recovery_id as u32,
        value.source_frame_id,
    ))
}

pub fn decode_media_recovery_wire_v1(
    input: &[u8],
) -> Result<MediaRecoveryWireV1, MediaRecoveryWireErrorV1> {
    if input.len() > MEDIA_RECOVERY_WIRE_MAX_BYTES_V1 {
        return Err(MediaRecoveryWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| MediaRecoveryWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| MediaRecoveryWireErrorV1::Syntax)?;
    let mut fields = [None; FIELD_COUNT];
    for (key, value) in entries {
        let index = field_index(key).ok_or(MediaRecoveryWireErrorV1::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(MediaRecoveryWireErrorV1::DuplicateField);
        }
    }
    if fields.iter().any(Option::is_none) {
        return Err(MediaRecoveryWireErrorV1::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        _ => Err(MediaRecoveryWireErrorV1::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(Scalar::Number(value)) => {
            canonical_u64(value).map_err(|_| MediaRecoveryWireErrorV1::InvalidValue)
        }
        _ => Err(MediaRecoveryWireErrorV1::InvalidValue),
    };
    let message_type = MediaRecoveryWireTypeV1::parse(text_field(0)?)
        .ok_or(MediaRecoveryWireErrorV1::InvalidValue)?;
    if number_field(1)? != u64::from(MEDIA_RECOVERY_WIRE_SCHEMA_VERSION_V1) {
        return Err(MediaRecoveryWireErrorV1::InvalidValue);
    }
    let u32_field = |index| {
        u32::try_from(number_field(index)?).map_err(|_| MediaRecoveryWireErrorV1::InvalidValue)
    };
    MediaRecoveryWireV1 {
        message_type,
        generation: u64::from(u32_field(2)?) << 32 | u64::from(u32_field(3)?),
        recovery_id: u64::from(u32_field(4)?) << 32 | u64::from(u32_field(5)?),
        source_frame_id: u64::from(u32_field(6)?),
    }
    .validate()
}

fn field_index(value: &str) -> Option<usize> {
    [
        "type",
        "schemaVersion",
        "streamGenerationHi",
        "streamGenerationLo",
        "recoveryIdHi",
        "recoveryIdLo",
        "sourceFrameId",
    ]
    .iter()
    .position(|field| *field == value)
}
