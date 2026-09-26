use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::fmt;
use zeroize::Zeroize;

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum StrictJsonValue {
    Bool(bool),
    U64(u64),
    F64(f64),
    String(String),
    Array(Vec<Self>),
    Object(Vec<(String, Self)>),
}

impl StrictJsonValue {
    pub(crate) fn object(self) -> Option<Vec<(String, Self)>> {
        match self {
            Self::Object(value) => Some(value),
            _ => None,
        }
    }

    pub(crate) fn as_object(&self) -> Option<&[(String, Self)]> {
        match self {
            Self::Object(value) => Some(value),
            _ => None,
        }
    }
}

impl Zeroize for StrictJsonValue {
    fn zeroize(&mut self) {
        match self {
            Self::Bool(value) => *value = false,
            Self::U64(value) => *value = 0,
            Self::F64(value) => *value = 0.0,
            Self::String(value) => value.zeroize(),
            Self::Array(values) => {
                for value in values.iter_mut() {
                    value.zeroize();
                }
                values.clear();
            }
            Self::Object(values) => {
                for (key, value) in values.iter_mut() {
                    key.zeroize();
                    value.zeroize();
                }
                values.clear();
            }
        }
    }
}

struct StrictVisitor;

impl<'de> Visitor<'de> for StrictVisitor {
    type Value = StrictJsonValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a finite JSON value without duplicate object keys")
    }

    fn visit_bool<E: de::Error>(self, value: bool) -> Result<Self::Value, E> {
        Ok(StrictJsonValue::Bool(value))
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> Result<Self::Value, E> {
        Ok(StrictJsonValue::U64(value))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> Result<Self::Value, E> {
        u64::try_from(value)
            .map(StrictJsonValue::U64)
            .map_err(E::custom)
    }

    fn visit_f64<E: de::Error>(self, value: f64) -> Result<Self::Value, E> {
        if value.is_finite() {
            Ok(StrictJsonValue::F64(value))
        } else {
            Err(E::custom("non-finite number"))
        }
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<Self::Value, E> {
        Ok(StrictJsonValue::String(value.to_owned()))
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<Self::Value, E> {
        Ok(StrictJsonValue::String(value))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut input: A) -> Result<Self::Value, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = input.next_element()? {
            values.push(value);
        }
        Ok(StrictJsonValue::Array(values))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut input: A) -> Result<Self::Value, A::Error> {
        let mut values = Vec::<(String, StrictJsonValue)>::new();
        while let Some((key, value)) = input.next_entry::<String, StrictJsonValue>()? {
            if values.iter().any(|(existing, _)| existing == &key) {
                return Err(de::Error::custom(format!("duplicate field {key}")));
            }
            values.push((key, value));
        }
        Ok(StrictJsonValue::Object(values))
    }
}

impl<'de> Deserialize<'de> for StrictJsonValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(StrictVisitor)
    }
}

pub(crate) fn parse_strict_json(input: &[u8], max: usize) -> Option<StrictJsonValue> {
    if input.len() > max {
        return None;
    }
    let mut deserializer = serde_json::Deserializer::from_slice(input);
    let value = StrictJsonValue::deserialize(&mut deserializer).ok()?;
    deserializer.end().ok()?;
    Some(value)
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(crate) fn encode_base64(input: &[u8]) -> String {
    let mut output = Vec::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        output.push(BASE64[usize::from(a >> 2)]);
        output.push(BASE64[usize::from(((a & 3) << 4) | (b >> 4))]);
        output.push(if chunk.len() > 1 {
            BASE64[usize::from(((b & 15) << 2) | (c >> 6))]
        } else {
            b'='
        });
        output.push(if chunk.len() > 2 {
            BASE64[usize::from(c & 63)]
        } else {
            b'='
        });
    }
    String::from_utf8(output).expect("base64 is ASCII")
}

fn sextet(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

pub(crate) fn decode_base64<const N: usize>(text: &str) -> Option<[u8; N]> {
    if text.len() != N.div_ceil(3) * 4 {
        return None;
    }
    let mut output = [0; N];
    let mut written = 0;
    let (chunks, remainder) = text.as_bytes().as_chunks::<4>();
    if !remainder.is_empty() {
        return None;
    }
    for chunk in chunks {
        let a = sextet(chunk[0])?;
        let b = sextet(chunk[1])?;
        if written < N {
            output[written] = (a << 2) | (b >> 4);
            written += 1;
        }
        if written < N {
            let c = sextet(chunk[2])?;
            output[written] = (b << 4) | (c >> 2);
            written += 1;
            if written < N {
                let d = sextet(chunk[3])?;
                output[written] = (c << 6) | d;
                written += 1;
            }
        }
    }
    (written == N && encode_base64(&output) == text).then_some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recursive_zeroize_clears_strings_and_nested_values() {
        let mut value = parse_strict_json(
            br#"{"type":"auth","proof":"sensitive","nested":["secret",7,true]}"#,
            256,
        )
        .unwrap();
        value.zeroize();
        assert_eq!(value, StrictJsonValue::Object(Vec::new()));
    }
}
