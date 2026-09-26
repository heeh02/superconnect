//! Canonical `hello` / `hello_ack` CONTROL wire codec.

use crate::strict_json::{decode_base64, parse_strict_json, StrictJsonValue};

#[path = "hello_wire_encode.rs"]
mod hello_wire_encode;
pub use hello_wire_encode::encode_session_hello_wire_v1;

pub const SESSION_HELLO_WIRE_MAX_BYTES_V1: usize = 4096;
pub const SESSION_HELLO_CODEC_H264_V1: u32 = 1 << 0;
pub const SESSION_HELLO_CODEC_HEVC_V1: u32 = 1 << 1;
const ALL_CODECS: u32 = SESSION_HELLO_CODEC_H264_V1 | SESSION_HELLO_CODEC_HEVC_V1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionHelloWireKindV1 {
    Hello,
    HelloAck,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionHelloRoleV1 {
    Source,
    Receiver,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionHelloProjectionV1 {
    Extend,
    Mirror,
    Primary,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionHelloCapsV1 {
    pub codecs: u32,
    pub max_width: Option<u32>,
    pub max_height: Option<u32>,
    pub screen_width: Option<u32>,
    pub screen_height: Option<u32>,
    pub scale: Option<f64>,
    pub refresh_rate: Option<u32>,
    pub refresh_rate_max: Option<u32>,
    pub hidpi: Option<bool>,
    pub pen: Option<bool>,
    pub hdr_hlg: Option<bool>,
    pub hdr_pq: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionHelloWireV1 {
    pub kind: SessionHelloWireKindV1,
    pub legacy_role: String,
    pub protocol_version: u16,
    pub auth_version: Option<u16>,
    pub record_version: Option<u16>,
    pub capability_version: Option<u16>,
    pub capability_intent_version: Option<u16>,
    pub frame_meta_version: Option<u16>,
    pub media_recovery_version: Option<u16>,
    pub udp_video_version: Option<u16>,
    pub udp_video_port: Option<u16>,
    pub peer_id: String,
    pub platform: Option<String>,
    pub device_name: Option<String>,
    pub app_version: Option<String>,
    pub pairing_token: Option<String>,
    pub supported_roles: u32,
    pub desired_role: Option<SessionHelloRoleV1>,
    pub accepted_role: Option<SessionHelloRoleV1>,
    pub projection: Option<SessionHelloProjectionV1>,
    pub caps: Option<SessionHelloCapsV1>,
    pub enrollment_key: Option<[u8; 65]>,
    pub challenge: Option<[u8; 32]>,
    pub needs_pairing: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionHelloWireErrorV1;

impl SessionHelloCapsV1 {
    fn validate(&self, kind: SessionHelloWireKindV1) -> bool {
        if self.codecs == 0 || self.codecs & !ALL_CODECS != 0 {
            return false;
        }
        let dimension = |value: Option<u32>| value.is_none_or(|v| (16..=8192).contains(&v));
        if !dimension(self.max_width)
            || !dimension(self.max_height)
            || !dimension(self.screen_width)
            || !dimension(self.screen_height)
        {
            return false;
        }
        if self
            .scale
            .is_some_and(|v| !v.is_finite() || !(0.5..=8.0).contains(&v))
            || self.refresh_rate.is_some_and(|v| v == 0 || v > 240)
            || self.refresh_rate_max.is_some_and(|v| v == 0 || v > 240)
        {
            return false;
        }
        match kind {
            SessionHelloWireKindV1::Hello => {
                self.screen_width.is_none()
                    && self.screen_height.is_none()
                    && self.scale.is_none()
                    && self.refresh_rate.is_none()
                    && self.refresh_rate_max.is_none()
                    && self.pen.is_none()
                    && self.hdr_hlg.is_none()
                    && self.hdr_pq.is_none()
            }
            SessionHelloWireKindV1::HelloAck => {
                self.max_width.is_none() && self.max_height.is_none() && self.hidpi.is_none()
            }
        }
    }
}

impl SessionHelloWireV1 {
    pub fn validate(self) -> Result<Self, SessionHelloWireErrorV1> {
        let text = |value: &str, max| {
            !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
        };
        if !(1..=2).contains(&self.protocol_version)
            || !text(&self.legacy_role, 16)
            || !text(&self.peer_id, 128)
            || self.platform.as_deref().is_some_and(|v| !text(v, 32))
            || self.device_name.as_deref().is_some_and(|v| !text(v, 128))
            || self.app_version.as_deref().is_some_and(|v| !text(v, 64))
            || self.pairing_token.as_deref().is_some_and(|v| !text(v, 128))
            || self.auth_version.is_some_and(|v| v != 1)
            || self.record_version.is_some_and(|v| v != 1)
            || self.capability_version.is_some_and(|v| v != 1)
            || self
                .capability_intent_version
                .is_some_and(|v| !(1..=2).contains(&v))
            || self.frame_meta_version.is_some_and(|v| v == 0 || v > 2)
            || self.media_recovery_version.is_some_and(|v| v != 1)
            || self.udp_video_port.is_some_and(|v| v == 0)
            || self.supported_roles & !3 != 0
            || self.caps.as_ref().is_some_and(|v| !v.validate(self.kind))
        {
            return Err(SessionHelloWireErrorV1);
        }
        let source = 1_u32;
        let receiver = 2_u32;
        match self.kind {
            SessionHelloWireKindV1::Hello => {
                if self.accepted_role.is_some()
                    || self.challenge.is_some()
                    || self.needs_pairing.is_some()
                    || self.udp_video_port.is_some()
                    || self.desired_role == Some(SessionHelloRoleV1::Receiver)
                    || self.supported_roles & receiver != 0
                    || (self.protocol_version == 2
                        && self.auth_version == Some(1)
                        && self.enrollment_key.is_none())
                {
                    return Err(SessionHelloWireErrorV1);
                }
            }
            SessionHelloWireKindV1::HelloAck => {
                if self.desired_role.is_some()
                    || self.projection.is_some()
                    || self.accepted_role == Some(SessionHelloRoleV1::Source)
                    || self.supported_roles & source != 0
                    || self.challenge.is_none() != self.needs_pairing.is_none()
                    || (self.needs_pairing == Some(true)) != self.enrollment_key.is_some()
                    || self.challenge.is_none() && self.enrollment_key.is_some()
                    || self.udp_video_port.is_some() && self.udp_video_version.unwrap_or(0) == 0
                {
                    return Err(SessionHelloWireErrorV1);
                }
            }
        }
        Ok(self)
    }
}

pub fn decode_session_hello_wire_v1(
    input: &[u8],
) -> Result<SessionHelloWireV1, SessionHelloWireErrorV1> {
    let object = parse_strict_json(input, SESSION_HELLO_WIRE_MAX_BYTES_V1)
        .and_then(StrictJsonValue::object)
        .ok_or(SessionHelloWireErrorV1)?;
    let mut object = Object::new(object);
    let kind = match object.string("type")?.as_str() {
        "hello" => SessionHelloWireKindV1::Hello,
        "hello_ack" => SessionHelloWireKindV1::HelloAck,
        _ => return Err(SessionHelloWireErrorV1),
    };
    let legacy_role = object
        .optional_string("role")?
        .unwrap_or_else(|| "legacy".to_owned());
    let protocol_version = object.optional_u16("protocolVersion")?.unwrap_or(1);
    let auth_version = object.optional_u16("authVersion")?;
    let record_version = object.optional_u16("recordVersion")?;
    if object
        .optional_string("app")?
        .is_some_and(|v| v != "superconnect")
    {
        return Err(SessionHelloWireErrorV1);
    }
    let peer_id = object.string("peerId")?;
    let platform = object.optional_string("platform")?;
    let device_name = object.optional_string("deviceName")?;
    let app_version = object.optional_string("appVersion")?;
    let pairing_token = object.optional_string("pairingToken")?;
    let supported_roles = object
        .optional("supportedRoles")
        .map(parse_roles)
        .transpose()?
        .unwrap_or(0);
    let desired_role = object
        .optional_string("desiredRole")?
        .map(|v| parse_role(&v))
        .transpose()?;
    let accepted_role = object
        .optional_string("acceptedRole")?
        .map(|v| parse_role(&v))
        .transpose()?;
    let projection = object
        .optional_string("projectionMode")?
        .map(|v| match v.as_str() {
            "extend" => Ok(SessionHelloProjectionV1::Extend),
            "mirror" => Ok(SessionHelloProjectionV1::Mirror),
            "primary" => Ok(SessionHelloProjectionV1::Primary),
            _ => Err(SessionHelloWireErrorV1),
        })
        .transpose()?;
    let capability_version = object.optional_u16("capabilityNegotiationVersion")?;
    let capability_intent_version = object.optional_u16("capabilityIntentNegotiationVersion")?;
    let frame_meta_version = object.optional_u16("frameMetaVersion")?;
    let media_recovery_version = object
        .optional_u16("mediaRecoveryVersion")?
        .filter(|v| *v != 0);
    let udp_video_version = object.optional_u16("udpVideoVersion")?.filter(|v| *v != 0);
    let udp_video_port = object.optional_u16("udpVideoPort")?.filter(|v| *v != 0);
    let caps = object.optional("caps").map(parse_caps).transpose()?;
    let enrollment_key = object
        .optional_string("ephPub")?
        .map(|v| decode_base64(&v).ok_or(SessionHelloWireErrorV1))
        .transpose()?;
    let challenge = object
        .optional_string("nonce")?
        .map(|v| decode_base64(&v).ok_or(SessionHelloWireErrorV1))
        .transpose()?;
    let needs_pairing = object.optional_bool("needsPairing")?;
    if !object.empty() {
        return Err(SessionHelloWireErrorV1);
    }
    SessionHelloWireV1 {
        kind,
        legacy_role,
        protocol_version,
        auth_version,
        record_version,
        capability_version,
        capability_intent_version,
        frame_meta_version,
        media_recovery_version,
        udp_video_version,
        udp_video_port,
        peer_id,
        platform,
        device_name,
        app_version,
        pairing_token,
        supported_roles,
        desired_role,
        accepted_role,
        projection,
        caps,
        enrollment_key,
        challenge,
        needs_pairing,
    }
    .validate()
}

struct Object(Vec<(String, StrictJsonValue)>);
impl Object {
    fn new(value: Vec<(String, StrictJsonValue)>) -> Self {
        Self(value)
    }
    fn optional(&mut self, key: &str) -> Option<StrictJsonValue> {
        self.0
            .iter()
            .position(|(k, _)| k == key)
            .map(|i| self.0.remove(i).1)
    }
    fn string(&mut self, key: &str) -> Result<String, SessionHelloWireErrorV1> {
        self.optional_string(key)?.ok_or(SessionHelloWireErrorV1)
    }
    fn optional_string(&mut self, key: &str) -> Result<Option<String>, SessionHelloWireErrorV1> {
        match self.optional(key) {
            Some(StrictJsonValue::String(v)) => Ok(Some(v)),
            None => Ok(None),
            _ => Err(SessionHelloWireErrorV1),
        }
    }
    fn optional_u16(&mut self, key: &str) -> Result<Option<u16>, SessionHelloWireErrorV1> {
        match self.optional(key) {
            Some(StrictJsonValue::U64(v)) => u16::try_from(v)
                .map(Some)
                .map_err(|_| SessionHelloWireErrorV1),
            None => Ok(None),
            _ => Err(SessionHelloWireErrorV1),
        }
    }
    fn optional_bool(&mut self, key: &str) -> Result<Option<bool>, SessionHelloWireErrorV1> {
        match self.optional(key) {
            Some(StrictJsonValue::Bool(v)) => Ok(Some(v)),
            None => Ok(None),
            _ => Err(SessionHelloWireErrorV1),
        }
    }
    fn empty(&self) -> bool {
        self.0.is_empty()
    }
}

fn parse_role(value: &str) -> Result<SessionHelloRoleV1, SessionHelloWireErrorV1> {
    match value {
        "host" | "source" => Ok(SessionHelloRoleV1::Source),
        "receiver" | "sink" => Ok(SessionHelloRoleV1::Receiver),
        _ => Err(SessionHelloWireErrorV1),
    }
}
fn parse_roles(value: StrictJsonValue) -> Result<u32, SessionHelloWireErrorV1> {
    let StrictJsonValue::Array(values) = value else {
        return Err(SessionHelloWireErrorV1);
    };
    let mut result = 0;
    for value in values {
        let StrictJsonValue::String(value) = value else {
            return Err(SessionHelloWireErrorV1);
        };
        let bit = match parse_role(&value)? {
            SessionHelloRoleV1::Source => 1,
            SessionHelloRoleV1::Receiver => 2,
        };
        if result & bit != 0 {
            return Err(SessionHelloWireErrorV1);
        }
        result |= bit;
    }
    Ok(result)
}
fn parse_caps(value: StrictJsonValue) -> Result<SessionHelloCapsV1, SessionHelloWireErrorV1> {
    let StrictJsonValue::Object(value) = value else {
        return Err(SessionHelloWireErrorV1);
    };
    let mut o = Object::new(value);
    let codecs = o
        .optional("codecs")
        .map(parse_codecs)
        .transpose()?
        .ok_or(SessionHelloWireErrorV1)?;
    let max_width = u32_field(&mut o, "maxWidth")?;
    let max_height = u32_field(&mut o, "maxHeight")?;
    let screen_width = u32_field(&mut o, "screenWidth")?;
    let screen_height = u32_field(&mut o, "screenHeight")?;
    let scale = number_field(&mut o, "scale")?;
    let refresh_rate = u32_field(&mut o, "refreshRate")?;
    let refresh_rate_max = u32_field(&mut o, "refreshRateMax")?;
    let hidpi = o.optional_bool("hidpi")?;
    let pen = o.optional_bool("pen")?;
    let (hdr_hlg, hdr_pq) = match o.optional("hdr") {
        Some(StrictJsonValue::Object(v)) => {
            let mut h = Object::new(v);
            let result = (h.optional_bool("hlg")?, h.optional_bool("pq")?);
            if !h.empty() {
                return Err(SessionHelloWireErrorV1);
            }
            result
        }
        None => (None, None),
        _ => return Err(SessionHelloWireErrorV1),
    };
    if !o.empty() {
        return Err(SessionHelloWireErrorV1);
    }
    Ok(SessionHelloCapsV1 {
        codecs,
        max_width,
        max_height,
        screen_width,
        screen_height,
        scale,
        refresh_rate,
        refresh_rate_max,
        hidpi,
        pen,
        hdr_hlg,
        hdr_pq,
    })
}
fn parse_codecs(value: StrictJsonValue) -> Result<u32, SessionHelloWireErrorV1> {
    let StrictJsonValue::Array(values) = value else {
        return Err(SessionHelloWireErrorV1);
    };
    let mut result = 0;
    for value in values {
        let StrictJsonValue::String(value) = value else {
            return Err(SessionHelloWireErrorV1);
        };
        let bit = match value.as_str() {
            "h264" => SESSION_HELLO_CODEC_H264_V1,
            "hevc" => SESSION_HELLO_CODEC_HEVC_V1,
            _ => return Err(SessionHelloWireErrorV1),
        };
        if result & bit != 0 {
            return Err(SessionHelloWireErrorV1);
        }
        result |= bit;
    }
    Ok(result)
}
fn u32_field(object: &mut Object, key: &str) -> Result<Option<u32>, SessionHelloWireErrorV1> {
    match object.optional(key) {
        Some(StrictJsonValue::U64(v)) => u32::try_from(v)
            .map(Some)
            .map_err(|_| SessionHelloWireErrorV1),
        None => Ok(None),
        _ => Err(SessionHelloWireErrorV1),
    }
}
fn number_field(object: &mut Object, key: &str) -> Result<Option<f64>, SessionHelloWireErrorV1> {
    match object.optional(key) {
        Some(StrictJsonValue::U64(v)) => Ok(Some(v as f64)),
        Some(StrictJsonValue::F64(v)) => Ok(Some(v)),
        None => Ok(None),
        _ => Err(SessionHelloWireErrorV1),
    }
}
