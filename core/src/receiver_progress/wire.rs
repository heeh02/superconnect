//! Canonical `receiver_progress` CONTROL wire codec.

use super::SessionGeneration;

pub const RECEIVER_PROGRESS_WIRE_TYPE_V1: &str = "receiver_progress";
pub const RECEIVER_PROGRESS_WIRE_SCHEMA_VERSION_V1: u32 = 1;
pub const RECEIVER_PROGRESS_WIRE_MAX_BYTES_V1: usize = 1024;
pub const RECEIVER_PROGRESS_WIRE_STAGE_COUNT_V1: usize = 4;
const FIELD_COUNT: usize = 13;
const MAX_EXACT_JSON_INTEGER: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReceiverProgressWireV1 {
    pub session_generation: u32,
    pub decoder_generation: u64,
    pub stage_counts: [u64; RECEIVER_PROGRESS_WIRE_STAGE_COUNT_V1],
    pub latest_source_frame_ids: [u32; RECEIVER_PROGRESS_WIRE_STAGE_COUNT_V1],
    pub awaiting_keyframe: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceiverProgressWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

impl ReceiverProgressWireV1 {
    pub fn validate(self) -> Result<Self, ReceiverProgressWireErrorV1> {
        if self.session_generation == 0
            || self.decoder_generation == 0
            || self.decoder_generation > MAX_EXACT_JSON_INTEGER
            || self
                .stage_counts
                .iter()
                .any(|value| *value > MAX_EXACT_JSON_INTEGER)
        {
            return Err(ReceiverProgressWireErrorV1::InvalidValue);
        }
        Ok(self)
    }

    pub fn session(self) -> SessionGeneration {
        SessionGeneration::new(u64::from(self.session_generation))
    }
}

pub fn encode_receiver_progress_wire_v1(
    value: ReceiverProgressWireV1,
) -> Result<String, ReceiverProgressWireErrorV1> {
    let value = value.validate()?;
    Ok(format!(
        "{{\"type\":\"{}\",\"schemaVersion\":1,\"sessionGeneration\":{},\"decoderGeneration\":{},\"receiverComplete\":{},\"decoderSubmitted\":{},\"decoderOutput\":{},\"renderCalled\":{},\"lastReceiverCompleteFrameId\":{},\"lastDecoderSubmittedFrameId\":{},\"lastDecoderOutputFrameId\":{},\"lastRenderCalledFrameId\":{},\"awaitingKeyframe\":{}}}",
        RECEIVER_PROGRESS_WIRE_TYPE_V1,
        value.session_generation,
        value.decoder_generation,
        value.stage_counts[0],
        value.stage_counts[1],
        value.stage_counts[2],
        value.stage_counts[3],
        value.latest_source_frame_ids[0],
        value.latest_source_frame_ids[1],
        value.latest_source_frame_ids[2],
        value.latest_source_frame_ids[3],
        value.awaiting_keyframe,
    ))
}

pub fn decode_receiver_progress_wire_v1(
    input: &[u8],
) -> Result<ReceiverProgressWireV1, ReceiverProgressWireErrorV1> {
    if input.len() > RECEIVER_PROGRESS_WIRE_MAX_BYTES_V1 {
        return Err(ReceiverProgressWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| ReceiverProgressWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text).parse()?;
    let mut fields = [None; FIELD_COUNT];
    for (key, value) in entries {
        let index = field_index(key).ok_or(ReceiverProgressWireErrorV1::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(ReceiverProgressWireErrorV1::DuplicateField);
        }
    }
    if fields.iter().any(Option::is_none) {
        return Err(ReceiverProgressWireErrorV1::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        _ => Err(ReceiverProgressWireErrorV1::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(Scalar::Number(value)) => canonical_u64(value),
        _ => Err(ReceiverProgressWireErrorV1::InvalidValue),
    };
    let bool_field = |index| match fields[index] {
        Some(Scalar::Boolean(value)) => Ok(value),
        _ => Err(ReceiverProgressWireErrorV1::InvalidValue),
    };
    if text_field(0)? != RECEIVER_PROGRESS_WIRE_TYPE_V1
        || number_field(1)? != u64::from(RECEIVER_PROGRESS_WIRE_SCHEMA_VERSION_V1)
    {
        return Err(ReceiverProgressWireErrorV1::InvalidValue);
    }
    let session_generation = u32::try_from(number_field(2)?)
        .ok()
        .filter(|value| *value != 0)
        .ok_or(ReceiverProgressWireErrorV1::InvalidValue)?;
    let decoder_generation = number_field(3)?;
    let stage_counts = [
        number_field(4)?,
        number_field(5)?,
        number_field(6)?,
        number_field(7)?,
    ];
    let latest_source_frame_ids = [
        u32::try_from(number_field(8)?).map_err(|_| ReceiverProgressWireErrorV1::InvalidValue)?,
        u32::try_from(number_field(9)?).map_err(|_| ReceiverProgressWireErrorV1::InvalidValue)?,
        u32::try_from(number_field(10)?).map_err(|_| ReceiverProgressWireErrorV1::InvalidValue)?,
        u32::try_from(number_field(11)?).map_err(|_| ReceiverProgressWireErrorV1::InvalidValue)?,
    ];
    ReceiverProgressWireV1 {
        session_generation,
        decoder_generation,
        stage_counts,
        latest_source_frame_ids,
        awaiting_keyframe: bool_field(12)?,
    }
    .validate()
}

pub(crate) fn canonical_u64(value: &str) -> Result<u64, ReceiverProgressWireErrorV1> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(ReceiverProgressWireErrorV1::InvalidValue);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|value| *value <= MAX_EXACT_JSON_INTEGER)
        .ok_or(ReceiverProgressWireErrorV1::InvalidValue)
}

fn field_index(value: &str) -> Option<usize> {
    [
        "type",
        "schemaVersion",
        "sessionGeneration",
        "decoderGeneration",
        "receiverComplete",
        "decoderSubmitted",
        "decoderOutput",
        "renderCalled",
        "lastReceiverCompleteFrameId",
        "lastDecoderSubmittedFrameId",
        "lastDecoderOutputFrameId",
        "lastRenderCalledFrameId",
        "awaitingKeyframe",
    ]
    .iter()
    .position(|field| *field == value)
}

#[derive(Clone, Copy)]
pub(crate) enum Scalar<'a> {
    Text(&'a str),
    Number(&'a str),
    Boolean(bool),
}

pub(crate) struct FlatObjectParser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> FlatObjectParser<'a> {
    pub(crate) fn new(text: &'a str) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            offset: 0,
        }
    }

    pub(crate) fn parse(
        mut self,
    ) -> Result<Vec<(&'a str, Scalar<'a>)>, ReceiverProgressWireErrorV1> {
        if self.bytes.iter().any(|byte| !byte.is_ascii()) {
            return Err(ReceiverProgressWireErrorV1::Syntax);
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
                let value = match self.peek() {
                    Some(b'"') => Scalar::Text(self.string()?),
                    Some(b't') if self.literal(b"true") => Scalar::Boolean(true),
                    Some(b'f') if self.literal(b"false") => Scalar::Boolean(false),
                    _ => Scalar::Number(self.number()?),
                };
                result.push((key, value));
                self.space();
                match self.peek() {
                    Some(b',') => self.offset += 1,
                    Some(b'}') => {
                        self.offset += 1;
                        break;
                    }
                    _ => return Err(ReceiverProgressWireErrorV1::Syntax),
                }
            }
        }
        self.space();
        if self.offset != self.bytes.len() {
            return Err(ReceiverProgressWireErrorV1::Syntax);
        }
        Ok(result)
    }

    fn string(&mut self) -> Result<&'a str, ReceiverProgressWireErrorV1> {
        self.take(b'"')?;
        let start = self.offset;
        while let Some(value) = self.peek() {
            if value == b'"' {
                let result = &self.text[start..self.offset];
                self.offset += 1;
                return Ok(result);
            }
            if value == b'\\' || value < 0x20 || !value.is_ascii() {
                return Err(ReceiverProgressWireErrorV1::Syntax);
            }
            self.offset += 1;
        }
        Err(ReceiverProgressWireErrorV1::Syntax)
    }

    fn number(&mut self) -> Result<&'a str, ReceiverProgressWireErrorV1> {
        let start = self.offset;
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.offset += 1;
        }
        if start == self.offset {
            return Err(ReceiverProgressWireErrorV1::Syntax);
        }
        Ok(&self.text[start..self.offset])
    }

    fn literal(&mut self, value: &[u8]) -> bool {
        if !self.bytes[self.offset..].starts_with(value) {
            return false;
        }
        self.offset += value.len();
        true
    }

    fn take(&mut self, expected: u8) -> Result<(), ReceiverProgressWireErrorV1> {
        if self.peek() != Some(expected) {
            return Err(ReceiverProgressWireErrorV1::Syntax);
        }
        self.offset += 1;
        Ok(())
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.offset).copied()
    }

    fn space(&mut self) {
        while self.peek().is_some_and(|byte| byte.is_ascii_whitespace()) {
            self.offset += 1;
        }
    }
}
