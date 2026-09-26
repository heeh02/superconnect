//! Canonical `bye`, `ping`, and `pong` CONTROL wire codec.

use crate::receiver_progress::wire::{FlatObjectParser, Scalar};

pub const SESSION_CONTROL_WIRE_MAX_BYTES_V1: usize = 160;
const MAX_EXACT_JSON_INTEGER: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionControlWireKindV1 {
    Bye,
    Ping,
    Pong,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionControlWireV1 {
    pub kind: SessionControlWireKindV1,
    pub sequence: u64,
    pub t0: Option<u64>,
    pub t1: Option<u64>,
    pub t2: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionControlWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

impl SessionControlWireV1 {
    pub const fn bye() -> Self {
        Self {
            kind: SessionControlWireKindV1::Bye,
            sequence: 0,
            t0: None,
            t1: None,
            t2: None,
        }
    }

    pub const fn ping(sequence: u64, t0: Option<u64>) -> Self {
        Self {
            kind: SessionControlWireKindV1::Ping,
            sequence,
            t0,
            t1: None,
            t2: None,
        }
    }

    pub const fn pong(sequence: u64, t0: Option<u64>, t1: Option<u64>, t2: Option<u64>) -> Self {
        Self {
            kind: SessionControlWireKindV1::Pong,
            sequence,
            t0,
            t1,
            t2,
        }
    }

    pub fn validate(self) -> Result<Self, SessionControlWireErrorV1> {
        let valid_number = |value: Option<u64>| {
            value.is_none_or(|number| number != 0 && number <= MAX_EXACT_JSON_INTEGER)
        };
        if !valid_number(self.t0) || !valid_number(self.t1) || !valid_number(self.t2) {
            return Err(SessionControlWireErrorV1::InvalidValue);
        }
        match self.kind {
            SessionControlWireKindV1::Bye
                if self.sequence == 0
                    && self.t0.is_none()
                    && self.t1.is_none()
                    && self.t2.is_none() =>
            {
                Ok(self)
            }
            SessionControlWireKindV1::Ping
                if self.sequence != 0
                    && self.sequence <= MAX_EXACT_JSON_INTEGER
                    && self.t1.is_none()
                    && self.t2.is_none() =>
            {
                Ok(self)
            }
            SessionControlWireKindV1::Pong
                if self.sequence != 0
                    && self.sequence <= MAX_EXACT_JSON_INTEGER
                    && self.t1.is_none_or(|_| self.t0.is_some())
                    && self.t2.is_none_or(|_| self.t1.is_some()) =>
            {
                Ok(self)
            }
            _ => Err(SessionControlWireErrorV1::InvalidValue),
        }
    }
}

pub fn encode_session_control_wire_v1(
    value: SessionControlWireV1,
) -> Result<String, SessionControlWireErrorV1> {
    let value = value.validate()?;
    let mut output = match value.kind {
        SessionControlWireKindV1::Bye => return Ok(r#"{"type":"bye"}"#.to_owned()),
        SessionControlWireKindV1::Ping => {
            format!(r#"{{"type":"ping","seq":{}}}"#, value.sequence)
        }
        SessionControlWireKindV1::Pong => {
            format!(r#"{{"type":"pong","seq":{}}}"#, value.sequence)
        }
    };
    output.pop();
    if let Some(t0) = value.t0 {
        output.push_str(&format!(",\"t0\":{t0}"));
    }
    if let Some(t1) = value.t1 {
        output.push_str(&format!(",\"t1\":{t1}"));
    }
    if let Some(t2) = value.t2 {
        output.push_str(&format!(",\"t2\":{t2}"));
    }
    output.push('}');
    Ok(output)
}

pub fn decode_session_control_wire_v1(
    input: &[u8],
) -> Result<SessionControlWireV1, SessionControlWireErrorV1> {
    if input.len() > SESSION_CONTROL_WIRE_MAX_BYTES_V1 {
        return Err(SessionControlWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| SessionControlWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| SessionControlWireErrorV1::Syntax)?;
    let mut fields = [None; 5];
    for (key, value) in entries {
        let index = match key {
            "type" => 0,
            "seq" => 1,
            "t0" => 2,
            "t1" => 3,
            "t2" => 4,
            _ => return Err(SessionControlWireErrorV1::UnknownField),
        };
        if fields[index].replace(value).is_some() {
            return Err(SessionControlWireErrorV1::DuplicateField);
        }
    }
    let kind = match fields[0] {
        Some(Scalar::Text("bye")) => SessionControlWireKindV1::Bye,
        Some(Scalar::Text("ping")) => SessionControlWireKindV1::Ping,
        Some(Scalar::Text("pong")) => SessionControlWireKindV1::Pong,
        None => return Err(SessionControlWireErrorV1::MissingField),
        _ => return Err(SessionControlWireErrorV1::InvalidValue),
    };
    let number = |index| match fields[index] {
        Some(Scalar::Number(value)) => canonical_positive(value).map(Some),
        None => Ok(None),
        _ => Err(SessionControlWireErrorV1::InvalidValue),
    };
    let sequence = number(1)?.unwrap_or(0);
    SessionControlWireV1 {
        kind,
        sequence,
        t0: number(2)?,
        t1: number(3)?,
        t2: number(4)?,
    }
    .validate()
}

fn canonical_positive(value: &str) -> Result<u64, SessionControlWireErrorV1> {
    if value.is_empty()
        || value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(SessionControlWireErrorV1::InvalidValue);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|number| *number <= MAX_EXACT_JSON_INTEGER)
        .ok_or(SessionControlWireErrorV1::InvalidValue)
}
