pub mod admission;
pub mod auth_v1;
mod auth_wire;
pub mod capability;
pub mod collaboration_intent;
pub mod control_envelope;
mod control_envelope_types_generated;
mod ffi;
mod input_ownership;
mod json_wire;
pub mod media_recovery;
pub mod receiver_progress;
pub mod record_v1;
pub mod secure_connection;
pub mod session;
pub mod session_generation;
mod strict_json;
pub mod wire;

pub use auth_wire::{
    decode_auth_wire_v1, encode_auth_wire_v1, AuthWireErrorV1, AuthWireMessageV1,
    AUTH_WIRE_MAX_BYTES_V1,
};
pub use control_envelope::{
    claim_control_envelope_kind_v1, control_error_reason_for_session_fatal_v1,
    decode_control_caps_update_v1, decode_control_envelope_v1, decode_control_text_wire_v1,
    encode_control_aux_anchor_accepted_wire_v1, encode_control_caps_update_v1,
    encode_control_error_wire_v1, encode_control_session_fatal_error_wire_v1,
    encode_control_text_wire_v1, encode_control_udp_aux_wire_v1,
    encode_control_video_epoch_wire_v1, ControlCapsUpdateV1, ControlEnvelopeErrorV1,
    ControlEnvelopeV1, CONTROL_ENVELOPE_MAX_BYTES_V1,
};
pub use control_envelope_types_generated::*;
pub use ffi::*;
pub use input_ownership::{
    decode_input_reset_wire_v1, encode_input_reset_wire_v1, InputResetWireErrorV1,
    INPUT_RESET_REASON_MAX_BYTES_V1, INPUT_RESET_WIRE_MAX_BYTES_V1,
};
pub use session::{
    decode_session_control_wire_v1, encode_session_control_wire_v1, SessionControlWireErrorV1,
    SessionControlWireKindV1, SessionControlWireV1, SESSION_CONTROL_WIRE_MAX_BYTES_V1,
};
pub use session_generation::SessionGeneration;
pub use wire::{
    decode_video_meta, encode_frame, encode_frame_header, encode_video_meta, input_decode,
    input_encode, input_is_replaceable, input_sequenced_decode, input_sequenced_encode,
    FrameDecoder, FrameError, FrameMeta, ScInputEvent, VideoFrameMeta, VideoMetaDecode,
    VideoMetaEncodeError, FRAME_HEADER_SIZE, INPUT_RECORD_SIZE, INPUT_SEQUENCED_RECORD_SIZE,
    MAX_FRAME_PAYLOAD, VIDEO_META_V1_SIZE, VIDEO_META_V2_SIZE,
};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn hex(value: &str) -> Vec<u8> {
        assert_eq!(value.len() % 2, 0);
        let (pairs, remainder) = value.as_bytes().as_chunks::<2>();
        assert!(remainder.is_empty());
        pairs
            .iter()
            .map(|pair| {
                let text = std::str::from_utf8(pair).unwrap();
                u8::from_str_radix(text, 16).unwrap()
            })
            .collect()
    }

    fn golden_event() -> ScInputEvent {
        ScInputEvent {
            event_type: 2,
            tool: 2,
            buttons: 3,
            flags: 5,
            timestamp_ms: 1_234_567_890_123,
            x: 0.5,
            y: 0.25,
            pressure: 0.75,
            tilt_x: 10.0,
            tilt_y: -20.0,
            scroll_x: 3.5,
            scroll_y: -7.25,
            key_code: 0x1234,
            pointer_id: 0x5678,
        }
    }

    #[test]
    fn input_golden_vector_and_round_trip() {
        let expected = [
            0x02, 0x02, 0x03, 0x05, 0xcb, 0x04, 0xfb, 0x71, 0x1f, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x3f, 0x00, 0x00, 0x80, 0x3e, 0x00, 0x00, 0x40, 0x3f, 0x00, 0x00, 0x20, 0x41,
            0x00, 0x00, 0xa0, 0xc1, 0x00, 0x00, 0x60, 0x40, 0x00, 0x00, 0xe8, 0xc0, 0x34, 0x12,
            0x78, 0x56,
        ];
        let event = golden_event();
        assert_eq!(input_encode(&event), expected);
        assert_eq!(input_decode(&expected), Some(event));
    }

    #[test]
    fn frame_golden_and_bounds() {
        let mut output = [0_u8; 8];
        assert_eq!(encode_frame(0, 0, b"hi", &mut output), Ok(8));
        assert_eq!(output, [0, 0, 2, 0, 0, 0, b'h', b'i']);
        assert_eq!(
            encode_frame(0, 0, b"hi", &mut output[..7]),
            Err(FrameError::BufferTooSmall)
        );
    }

    #[test]
    fn repository_protocol_vectors_are_byte_exact() {
        let document: Value = serde_json::from_str(include_str!("../../proto/vectors.json"))
            .expect("proto/vectors.json must remain valid JSON");
        for vector in document["vectors"].as_array().unwrap() {
            let channel = vector["channel"].as_u64().unwrap() as u8;
            let flags = vector["flags"].as_u64().unwrap() as u8;
            let payload = hex(vector["payloadHex"].as_str().unwrap());
            let expected = hex(vector["frameHex"].as_str().unwrap());
            let mut encoded = vec![0_u8; FRAME_HEADER_SIZE + payload.len()];
            assert_eq!(
                encode_frame(channel, flags, &payload, &mut encoded),
                Ok(expected.len()),
                "{} encode length",
                vector["name"]
            );
            assert_eq!(encoded, expected, "{} encode bytes", vector["name"]);
        }

        for vector in document["inputVectors"].as_array().unwrap() {
            let event = ScInputEvent {
                event_type: vector["type"].as_u64().unwrap() as u8,
                tool: vector["tool"].as_u64().unwrap() as u8,
                buttons: vector["buttons"].as_u64().unwrap() as u8,
                flags: vector["flags"].as_u64().unwrap() as u8,
                timestamp_ms: vector["timestampMs"].as_u64().unwrap(),
                x: vector["x"].as_f64().unwrap() as f32,
                y: vector["y"].as_f64().unwrap() as f32,
                pressure: vector["pressure"].as_f64().unwrap() as f32,
                tilt_x: vector["tiltX"].as_f64().unwrap() as f32,
                tilt_y: vector["tiltY"].as_f64().unwrap() as f32,
                scroll_x: vector["scrollX"].as_f64().unwrap() as f32,
                scroll_y: vector["scrollY"].as_f64().unwrap() as f32,
                key_code: vector["keyCode"].as_u64().unwrap() as u16,
                pointer_id: vector["pointerId"].as_u64().unwrap() as u16,
            };
            let expected = hex(vector["recordHex"].as_str().unwrap());
            assert_eq!(
                input_encode(&event).as_slice(),
                expected,
                "{} INPUT encode bytes",
                vector["name"]
            );
            assert_eq!(
                input_decode(&expected),
                Some(event),
                "{} INPUT decode fields",
                vector["name"]
            );
        }
    }
}
