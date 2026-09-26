use super::*;

fn encode_text(value: Option<&str>) -> ScSessionHelloTextV1 {
    let mut output = ScSessionHelloTextV1::default();
    if let Some(value) = value {
        output.length = value.len() as u32;
        output.bytes[..value.len()].copy_from_slice(value.as_bytes());
    }
    output
}

fn role_value(value: Option<SessionHelloRoleV1>) -> u32 {
    match value {
        None => 0,
        Some(SessionHelloRoleV1::Source) => SC_SESSION_HELLO_ROLE_SOURCE_V1,
        Some(SessionHelloRoleV1::Receiver) => SC_SESSION_HELLO_ROLE_RECEIVER_V1,
    }
}

fn projection_value(value: Option<SessionHelloProjectionV1>) -> u32 {
    match value {
        None => 0,
        Some(SessionHelloProjectionV1::Extend) => SC_SESSION_HELLO_PROJECTION_EXTEND_V1,
        Some(SessionHelloProjectionV1::Mirror) => SC_SESSION_HELLO_PROJECTION_MIRROR_V1,
        Some(SessionHelloProjectionV1::Primary) => SC_SESSION_HELLO_PROJECTION_PRIMARY_V1,
    }
}

pub(super) fn encode_record(value: SessionHelloWireV1, struct_size: u32) -> ScSessionHelloWireV1 {
    let mut presence = 0;
    let mut caps_presence = 0;
    let mut caps_values = 0;
    let mut output = ScSessionHelloWireV1 {
        struct_size,
        api_version: SC_API_VERSION_V1,
        kind: match value.kind {
            SessionHelloWireKindV1::Hello => SC_SESSION_HELLO_KIND_HELLO_V1,
            SessionHelloWireKindV1::HelloAck => SC_SESSION_HELLO_KIND_HELLO_ACK_V1,
        },
        supported_roles: value.supported_roles,
        presence: 0,
        protocol_version: value.protocol_version,
        auth_version: value.auth_version.unwrap_or(0),
        record_version: value.record_version.unwrap_or(0),
        capability_version: value.capability_version.unwrap_or(0),
        capability_intent_version: value.capability_intent_version.unwrap_or(0),
        frame_meta_version: value.frame_meta_version.unwrap_or(0),
        media_recovery_version: value.media_recovery_version.unwrap_or(0),
        udp_video_version: value.udp_video_version.unwrap_or(0),
        udp_video_port: value.udp_video_port.unwrap_or(0),
        reserved0: 0,
        desired_role: role_value(value.desired_role),
        accepted_role: role_value(value.accepted_role),
        projection: projection_value(value.projection),
        codecs: 0,
        caps_presence: 0,
        caps_values: 0,
        max_width: 0,
        max_height: 0,
        screen_width: 0,
        screen_height: 0,
        refresh_rate: 0,
        refresh_rate_max: 0,
        reserved_scale: 0,
        scale: 0.0,
        legacy_role: encode_text(Some(&value.legacy_role)),
        peer_id: encode_text(Some(&value.peer_id)),
        platform: encode_text(value.platform.as_deref()),
        device_name: encode_text(value.device_name.as_deref()),
        app_version: encode_text(value.app_version.as_deref()),
        pairing_token: encode_text(value.pairing_token.as_deref()),
        enrollment_key: value.enrollment_key.unwrap_or([0; 65]),
        challenge: value.challenge.unwrap_or([0; 32]),
        needs_pairing: value.needs_pairing.unwrap_or(false) as u8,
        reserved1: [0; 6],
        reserved2: 0,
    };
    if let Some(caps) = value.caps {
        presence |= SC_SESSION_HELLO_FIELD_CAPS_V1;
        output.codecs = caps.codecs;
        let mut set_u32 = |bit, input: Option<u32>, destination: &mut u32| {
            if let Some(input) = input {
                caps_presence |= bit;
                *destination = input;
            }
        };
        set_u32(
            SC_SESSION_HELLO_CAP_MAX_WIDTH_V1,
            caps.max_width,
            &mut output.max_width,
        );
        set_u32(
            SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1,
            caps.max_height,
            &mut output.max_height,
        );
        set_u32(
            SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1,
            caps.screen_width,
            &mut output.screen_width,
        );
        set_u32(
            SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1,
            caps.screen_height,
            &mut output.screen_height,
        );
        set_u32(
            SC_SESSION_HELLO_CAP_REFRESH_RATE_V1,
            caps.refresh_rate,
            &mut output.refresh_rate,
        );
        set_u32(
            SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1,
            caps.refresh_rate_max,
            &mut output.refresh_rate_max,
        );
        if let Some(scale) = caps.scale {
            caps_presence |= SC_SESSION_HELLO_CAP_SCALE_V1;
            output.scale = scale;
        }
        let mut set_bool = |bit, value_bit, input: Option<bool>| {
            if let Some(input) = input {
                caps_presence |= bit;
                if input {
                    caps_values |= value_bit;
                }
            }
        };
        set_bool(
            SC_SESSION_HELLO_CAP_HIDPI_V1,
            SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1,
            caps.hidpi,
        );
        set_bool(
            SC_SESSION_HELLO_CAP_PEN_V1,
            SC_SESSION_HELLO_CAP_VALUE_PEN_V1,
            caps.pen,
        );
        set_bool(
            SC_SESSION_HELLO_CAP_HDR_HLG_V1,
            SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1,
            caps.hdr_hlg,
        );
        set_bool(
            SC_SESSION_HELLO_CAP_HDR_PQ_V1,
            SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1,
            caps.hdr_pq,
        );
    }
    if value.enrollment_key.is_some() {
        presence |= SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1;
    }
    if value.challenge.is_some() {
        presence |= SC_SESSION_HELLO_FIELD_CHALLENGE_V1;
    }
    if value.needs_pairing.is_some() {
        presence |= SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1;
    }
    output.presence = presence;
    output.caps_presence = caps_presence;
    output.caps_values = caps_values;
    output
}
