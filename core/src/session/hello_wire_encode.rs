use super::{
    SessionHelloCapsV1, SessionHelloProjectionV1, SessionHelloRoleV1, SessionHelloWireErrorV1,
    SessionHelloWireKindV1, SessionHelloWireV1,
};
use crate::strict_json::encode_base64;

pub fn encode_session_hello_wire_v1(
    value: SessionHelloWireV1,
) -> Result<String, SessionHelloWireErrorV1> {
    let value = value.validate()?;
    let mut fields = Vec::<String>::new();
    let string = |value: &str| serde_json::to_string(value).map_err(|_| SessionHelloWireErrorV1);
    fields.push(format!(
        "\"type\":{}",
        string(match value.kind {
            SessionHelloWireKindV1::Hello => "hello",
            SessionHelloWireKindV1::HelloAck => "hello_ack",
        })?
    ));
    fields.push(format!("\"role\":{}", string(&value.legacy_role)?));
    fields.push(format!("\"protocolVersion\":{}", value.protocol_version));
    push_u16(&mut fields, "authVersion", value.auth_version);
    push_u16(&mut fields, "recordVersion", value.record_version);
    fields.push("\"app\":\"superconnect\"".to_owned());
    fields.push(format!("\"peerId\":{}", string(&value.peer_id)?));
    push_string(&mut fields, "platform", value.platform.as_deref(), &string)?;
    push_string(
        &mut fields,
        "deviceName",
        value.device_name.as_deref(),
        &string,
    )?;
    push_string(
        &mut fields,
        "appVersion",
        value.app_version.as_deref(),
        &string,
    )?;
    push_string(
        &mut fields,
        "pairingToken",
        value.pairing_token.as_deref(),
        &string,
    )?;
    if value.supported_roles != 0 {
        fields.push(format!(
            "\"supportedRoles\":{}",
            role_array(value.supported_roles)
        ));
    }
    push_role(&mut fields, "desiredRole", value.desired_role);
    push_role(&mut fields, "acceptedRole", value.accepted_role);
    if let Some(projection) = value.projection {
        let name = match projection {
            SessionHelloProjectionV1::Extend => "extend",
            SessionHelloProjectionV1::Mirror => "mirror",
            SessionHelloProjectionV1::Primary => "primary",
        };
        fields.push(format!("\"projectionMode\":\"{name}\""));
    }
    push_u16(
        &mut fields,
        "capabilityNegotiationVersion",
        value.capability_version,
    );
    push_u16(
        &mut fields,
        "capabilityIntentNegotiationVersion",
        value.capability_intent_version,
    );
    push_u16(&mut fields, "frameMetaVersion", value.frame_meta_version);
    push_u16(
        &mut fields,
        "mediaRecoveryVersion",
        value.media_recovery_version,
    );
    push_u16(&mut fields, "udpVideoVersion", value.udp_video_version);
    push_u16(&mut fields, "udpVideoPort", value.udp_video_port);
    if let Some(caps) = &value.caps {
        fields.push(format!("\"caps\":{}", encode_caps(caps)?));
    }
    if let Some(key) = value.enrollment_key {
        fields.push(format!("\"ephPub\":\"{}\"", encode_base64(&key)));
    }
    if let Some(challenge) = value.challenge {
        fields.push(format!("\"nonce\":\"{}\"", encode_base64(&challenge)));
    }
    if let Some(pairing) = value.needs_pairing {
        fields.push(format!("\"needsPairing\":{pairing}"));
    }
    Ok(format!("{{{}}}", fields.join(",")))
}

fn push_u16(fields: &mut Vec<String>, key: &str, value: Option<u16>) {
    if let Some(value) = value {
        fields.push(format!("\"{key}\":{value}"));
    }
}

fn push_string<F>(
    fields: &mut Vec<String>,
    key: &str,
    value: Option<&str>,
    string: &F,
) -> Result<(), SessionHelloWireErrorV1>
where
    F: Fn(&str) -> Result<String, SessionHelloWireErrorV1>,
{
    if let Some(value) = value {
        fields.push(format!("\"{key}\":{}", string(value)?));
    }
    Ok(())
}

fn push_role(fields: &mut Vec<String>, key: &str, value: Option<SessionHelloRoleV1>) {
    if let Some(value) = value {
        fields.push(format!(
            "\"{key}\":\"{}\"",
            match value {
                SessionHelloRoleV1::Source => "host",
                SessionHelloRoleV1::Receiver => "receiver",
            }
        ));
    }
}

fn role_array(value: u32) -> &'static str {
    match value {
        1 => "[\"host\"]",
        2 => "[\"receiver\"]",
        3 => "[\"host\",\"receiver\"]",
        _ => "[]",
    }
}

fn encode_caps(value: &SessionHelloCapsV1) -> Result<String, SessionHelloWireErrorV1> {
    let mut f = vec![format!(
        "\"codecs\":{}",
        match value.codecs {
            1 => "[\"h264\"]",
            2 => "[\"hevc\"]",
            3 => "[\"h264\",\"hevc\"]",
            _ => return Err(SessionHelloWireErrorV1),
        }
    )];
    push_u32(&mut f, "maxWidth", value.max_width);
    push_u32(&mut f, "maxHeight", value.max_height);
    push_u32(&mut f, "screenWidth", value.screen_width);
    push_u32(&mut f, "screenHeight", value.screen_height);
    if let Some(v) = value.scale {
        f.push(format!(
            "\"scale\":{}",
            serde_json::to_string(&v).map_err(|_| SessionHelloWireErrorV1)?
        ));
    }
    push_u32(&mut f, "refreshRate", value.refresh_rate);
    push_u32(&mut f, "refreshRateMax", value.refresh_rate_max);
    if let Some(v) = value.hidpi {
        f.push(format!("\"hidpi\":{v}"));
    }
    if let Some(v) = value.pen {
        f.push(format!("\"pen\":{v}"));
    }
    if value.hdr_hlg.is_some() || value.hdr_pq.is_some() {
        f.push(format!(
            "\"hdr\":{{\"hlg\":{},\"pq\":{}}}",
            value.hdr_hlg.unwrap_or(false),
            value.hdr_pq.unwrap_or(false)
        ));
    }
    Ok(format!("{{{}}}", f.join(",")))
}

fn push_u32(fields: &mut Vec<String>, key: &str, value: Option<u32>) {
    if let Some(value) = value {
        fields.push(format!("\"{key}\":{value}"));
    }
}
