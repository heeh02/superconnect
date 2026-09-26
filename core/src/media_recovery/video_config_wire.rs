//! Canonical `video_config` CONTROL wire codec.

use crate::receiver_progress::wire::{canonical_u64, FlatObjectParser, Scalar};

pub const VIDEO_CONFIG_WIRE_MAX_BYTES_V1: usize = 256;
const FIELD_COUNT: usize = 7;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum VideoCodecV1 {
    H264 = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum VideoHdrModeV1 {
    Off = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoConfigWireV1 {
    pub codec: VideoCodecV1,
    pub width: u32,
    pub height: u32,
    pub hdr: VideoHdrModeV1,
    pub low_latency: bool,
    /// Zero means the sender omitted a refresh-rate hint.
    pub refresh_rate: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoConfigWireErrorV1 {
    TooLarge,
    Syntax,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidValue,
}

impl VideoConfigWireV1 {
    pub fn validate(self) -> Result<Self, VideoConfigWireErrorV1> {
        if !(16..=8192).contains(&self.width)
            || !(16..=8192).contains(&self.height)
            || self.refresh_rate > 240
        {
            return Err(VideoConfigWireErrorV1::InvalidValue);
        }
        Ok(self)
    }
}

pub fn encode_video_config_wire_v1(
    value: VideoConfigWireV1,
) -> Result<String, VideoConfigWireErrorV1> {
    let value = value.validate()?;
    let mut output = format!(
        "{{\"type\":\"video_config\",\"codec\":\"h264\",\"width\":{},\"height\":{},\"hdr\":\"off\",\"lowLatency\":{}",
        value.width, value.height, value.low_latency
    );
    if value.refresh_rate != 0 {
        output.push_str(&format!(",\"refreshRate\":{}", value.refresh_rate));
    }
    output.push('}');
    Ok(output)
}

pub fn decode_video_config_wire_v1(
    input: &[u8],
) -> Result<VideoConfigWireV1, VideoConfigWireErrorV1> {
    if input.len() > VIDEO_CONFIG_WIRE_MAX_BYTES_V1 {
        return Err(VideoConfigWireErrorV1::TooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| VideoConfigWireErrorV1::Syntax)?;
    let entries = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| VideoConfigWireErrorV1::Syntax)?;
    let mut fields = [None; FIELD_COUNT];
    for (key, value) in entries {
        let index = field_index(key).ok_or(VideoConfigWireErrorV1::UnknownField)?;
        if fields[index].replace(value).is_some() {
            return Err(VideoConfigWireErrorV1::DuplicateField);
        }
    }
    if fields[..4].iter().any(Option::is_none) {
        return Err(VideoConfigWireErrorV1::MissingField);
    }
    let text_field = |index| match fields[index] {
        Some(Scalar::Text(value)) => Ok(value),
        _ => Err(VideoConfigWireErrorV1::InvalidValue),
    };
    let number_field = |index| match fields[index] {
        Some(Scalar::Number(value)) => {
            canonical_u64(value).map_err(|_| VideoConfigWireErrorV1::InvalidValue)
        }
        _ => Err(VideoConfigWireErrorV1::InvalidValue),
    };
    if text_field(0)? != "video_config" || text_field(1)? != "h264" {
        return Err(VideoConfigWireErrorV1::InvalidValue);
    }
    let hdr = match fields[4] {
        None | Some(Scalar::Text("off")) => VideoHdrModeV1::Off,
        _ => return Err(VideoConfigWireErrorV1::InvalidValue),
    };
    let low_latency = match fields[5] {
        None => false,
        Some(Scalar::Boolean(value)) => value,
        _ => return Err(VideoConfigWireErrorV1::InvalidValue),
    };
    let refresh_rate = match fields[6] {
        None => 0,
        Some(Scalar::Number(value)) => {
            u32::try_from(canonical_u64(value).map_err(|_| VideoConfigWireErrorV1::InvalidValue)?)
                .map_err(|_| VideoConfigWireErrorV1::InvalidValue)?
        }
        _ => return Err(VideoConfigWireErrorV1::InvalidValue),
    };
    VideoConfigWireV1 {
        codec: VideoCodecV1::H264,
        width: u32::try_from(number_field(2)?).map_err(|_| VideoConfigWireErrorV1::InvalidValue)?,
        height: u32::try_from(number_field(3)?)
            .map_err(|_| VideoConfigWireErrorV1::InvalidValue)?,
        hdr,
        low_latency,
        refresh_rate,
    }
    .validate()
}

fn field_index(value: &str) -> Option<usize> {
    [
        "type",
        "codec",
        "width",
        "height",
        "hdr",
        "lowLatency",
        "refreshRate",
    ]
    .iter()
    .position(|field| *field == value)
}
