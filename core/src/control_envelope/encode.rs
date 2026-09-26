use super::{ControlCapsUpdateV1, ControlEnvelopeErrorV1};
use crate::control_envelope_types_generated::*;
use crate::session::SessionFatalReason;

pub fn encode_control_caps_update_v1(
    value: ControlCapsUpdateV1,
) -> Result<String, ControlEnvelopeErrorV1> {
    let value = value.validate()?;
    let mut codecs = Vec::with_capacity(2);
    if value.codecs & 1 != 0 {
        codecs.push("\"h264\"");
    }
    if value.codecs & 2 != 0 {
        codecs.push("\"hevc\"");
    }
    let mut output = format!(
        "{{\"type\":\"caps_update\",\"caps\":{{\"codecs\":[{}],\"screenWidth\":{},\"screenHeight\":{}",
        codecs.join(","),
        value.screen_width,
        value.screen_height,
    );
    if let Some(scale) = value.scale {
        output.push_str(&format!(",\"scale\":{scale}"));
    }
    if let Some(refresh_rate) = value.refresh_rate {
        output.push_str(&format!(",\"refreshRate\":{refresh_rate}"));
    }
    if let Some(refresh_rate_max) = value.refresh_rate_max {
        output.push_str(&format!(",\"refreshRateMax\":{refresh_rate_max}"));
    }
    if let Some(pen) = value.pen {
        output.push_str(&format!(",\"pen\":{pen}"));
    }
    if value.hdr_hlg.is_some() || value.hdr_pq.is_some() {
        output.push_str(&format!(
            ",\"hdr\":{{\"hlg\":{},\"pq\":{}}}",
            value.hdr_hlg.unwrap_or(false),
            value.hdr_pq.unwrap_or(false),
        ));
    }
    output.push_str("}}");
    Ok(output)
}

pub fn encode_control_text_wire_v1(text: &str) -> Result<String, ControlEnvelopeErrorV1> {
    if text.is_empty() || text.len() > 4096 || text.chars().any(|value| value == '\0') {
        return Err(ControlEnvelopeErrorV1::Malformed);
    }
    let encoded = serde_json::to_string(text).map_err(|_| ControlEnvelopeErrorV1::Malformed)?;
    Ok(format!("{{\"type\":\"text\",\"text\":{encoded}}}"))
}

pub fn encode_control_error_wire_v1(detail: u32) -> Result<String, ControlEnvelopeErrorV1> {
    let reason = CONTROL_ERROR_REASONS_V1
        .iter()
        .find_map(|(wire, kind)| (*kind == detail).then_some(*wire))
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    let message = if detail == SC_CONTROL_ERROR_REASON_SESSION_CAPACITY_V1 {
        "session_busy"
    } else {
        reason
    };
    let field = if detail == SC_CONTROL_ERROR_REASON_VERSION_MISMATCH_V1 {
        "code"
    } else {
        "reason"
    };
    Ok(format!(
        "{{\"type\":\"error\",\"{field}\":\"{reason}\",\"message\":\"{message}\"}}"
    ))
}

pub fn control_error_reason_for_session_fatal_v1(reason: SessionFatalReason) -> Option<u32> {
    match reason {
        SessionFatalReason::AuthenticationRequired => {
            Some(SC_CONTROL_ERROR_REASON_AUTH_REQUIRED_V1)
        }
        SessionFatalReason::AuthenticationFailed | SessionFatalReason::UnexpectedReenrollment => {
            Some(SC_CONTROL_ERROR_REASON_AUTH_FAILED_V1)
        }
        SessionFatalReason::CredentialUnavailable => {
            Some(SC_CONTROL_ERROR_REASON_CREDENTIAL_UNAVAILABLE_V1)
        }
        SessionFatalReason::CapabilityCommitFailed => {
            Some(SC_CONTROL_ERROR_REASON_CAPABILITY_FAILED_V1)
        }
        SessionFatalReason::AdmissionRejected => Some(SC_CONTROL_ERROR_REASON_SESSION_BUSY_V1),
        SessionFatalReason::HandshakeTimedOut => Some(SC_CONTROL_ERROR_REASON_AUTH_TIMEOUT_V1),
        SessionFatalReason::IdentifierSpaceExhausted | SessionFatalReason::ProtocolViolation => {
            Some(SC_CONTROL_ERROR_REASON_PROTOCOL_ERROR_V1)
        }
        SessionFatalReason::TransportFailed => None,
        SessionFatalReason::FinalAckFailed => Some(SC_CONTROL_ERROR_REASON_ACK_FAILED_V1),
        SessionFatalReason::PairingRejected => Some(SC_CONTROL_ERROR_REASON_PAIRING_REJECTED_V1),
    }
}

pub fn encode_control_session_fatal_error_wire_v1(
    reason: SessionFatalReason,
) -> Result<String, ControlEnvelopeErrorV1> {
    let detail = control_error_reason_for_session_fatal_v1(reason)
        .ok_or(ControlEnvelopeErrorV1::Malformed)?;
    encode_control_error_wire_v1(detail)
}

pub fn encode_control_video_epoch_wire_v1(epoch: u32, first_frame_sequence: u32) -> String {
    format!(
        "{{\"type\":\"video_epoch\",\"videoEpoch\":{epoch},\"firstFrameSeq\":{first_frame_sequence}}}"
    )
}

pub fn encode_control_udp_aux_wire_v1(
    kind: u32,
    operation: u64,
) -> Result<String, ControlEnvelopeErrorV1> {
    match kind {
        SC_CONTROL_KIND_UDP_PROBE_ACK_V1 if operation != 0 && operation <= u64::from(u32::MAX) => {
            Ok(format!(
                "{{\"type\":\"udp_probe_ack\",\"token\":{operation}}}"
            ))
        }
        SC_CONTROL_KIND_UDP_UNAVAILABLE_V1 if operation == 0 => {
            Ok("{\"type\":\"udp_unavailable\"}".to_owned())
        }
        _ => Err(ControlEnvelopeErrorV1::Malformed),
    }
}

pub fn encode_control_aux_anchor_accepted_wire_v1(
    generation: u64,
    source_frame_id: u32,
) -> Result<String, ControlEnvelopeErrorV1> {
    if generation == 0 || source_frame_id == 0 {
        return Err(ControlEnvelopeErrorV1::Malformed);
    }
    Ok(format!(
        "{{\"type\":\"anchor_accepted\",\"streamEpochHi\":{},\"streamEpochLo\":{},\"sourceFrameId\":{source_frame_id}}}",
        generation >> 32,
        generation as u32,
    ))
}
