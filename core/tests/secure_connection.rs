use superconnect_core::capability::MediaRole;
use superconnect_core::record_v1::{
    derive_session_context, RecordDirection, RecordSealer, RecordType, MAX_RECORD_PLAINTEXT,
};
use superconnect_core::secure_connection::{
    ScSecureConnection, SecureConnectionConfig, SecureConnectionEffect, SecureConnectionError,
    SecureConnectionEvent, SecureRecordMaterial, SecureRecordPhase,
};
use superconnect_core::session::{
    ArtifactId, BoundedPeerIdentity, CredentialState, OperationId, SessionConfig, SessionEffect,
    SessionEvent, SessionFatalReason, SessionGeneration, SessionOrigin, SessionPhase, SessionSide,
    AUTH_VERSION_1,
};

const GENERATION: SessionGeneration = SessionGeneration::new(41);

fn local() -> BoundedPeerIdentity {
    BoundedPeerIdentity::new(b"source-local").unwrap()
}

fn peer() -> BoundedPeerIdentity {
    BoundedPeerIdentity::new(b"receiver-peer").unwrap()
}

fn operation(value: u64) -> OperationId {
    OperationId::new(value).unwrap()
}

fn artifact(value: u64) -> ArtifactId {
    ArtifactId::new(value).unwrap()
}

fn connection() -> ScSecureConnection {
    connection_with_origin(SessionOrigin::MutualAuthenticationRequired)
}

fn trusted_connection() -> ScSecureConnection {
    connection_with_origin(SessionOrigin::TrustedLocal)
}

fn connection_with_origin(origin: SessionOrigin) -> ScSecureConnection {
    ScSecureConnection::new(
        SecureConnectionConfig::new(
            SessionConfig::new(
                GENERATION,
                SessionSide::Initiator,
                MediaRole::Host,
                origin,
                local(),
                artifact(60),
                10,
            )
            .unwrap(),
        )
        .unwrap(),
    )
}

fn session(value: SessionEvent) -> SecureConnectionEvent {
    SecureConnectionEvent::Session(value)
}

fn apply(
    connection: &mut ScSecureConnection,
    event: SecureConnectionEvent,
) -> Vec<SecureConnectionEffect> {
    connection.apply(event).iter().cloned().collect()
}

fn open(connection: &mut ScSecureConnection) {
    let _ = apply(
        connection,
        session(SessionEvent::Start {
            generation: GENERATION,
        }),
    );
    let _ = apply(
        connection,
        session(SessionEvent::TransportOpened {
            generation: GENERATION,
            operation: operation(10),
        }),
    );
}

fn reach_record_preparation(connection: &mut ScSecureConnection) -> OperationId {
    open(connection);
    let _ = apply(
        connection,
        SecureConnectionEvent::PeerRecordVersion {
            generation: GENERATION,
            version: Some(1),
        },
    );
    let _ = apply(
        connection,
        session(SessionEvent::PeerHelloAck {
            generation: GENERATION,
            peer: peer(),
            auth_version: Some(AUTH_VERSION_1),
            challenge: Some(artifact(70)),
            enrollment: false,
            peer_enrollment_key: None,
        }),
    );
    let _ = apply(
        connection,
        session(SessionEvent::CredentialLoaded {
            generation: GENERATION,
            operation: operation(12),
            credential: CredentialState::Present(artifact(71)),
        }),
    );
    let _ = apply(
        connection,
        session(SessionEvent::AuthProofCreated {
            generation: GENERATION,
            operation: operation(13),
            proof: artifact(72),
            local_challenge: artifact(73),
        }),
    );
    let _ = apply(
        connection,
        session(SessionEvent::PeerAuthAck {
            generation: GENERATION,
            proof: artifact(74),
        }),
    );
    let effects = apply(
        connection,
        session(SessionEvent::MutualProofVerified {
            generation: GENERATION,
            operation: operation(14),
            valid: true,
        }),
    );
    assert_eq!(
        effects,
        vec![SecureConnectionEffect::PrepareRecordContext {
            generation: GENERATION,
            operation: operation(15),
        }]
    );
    operation(15)
}

fn material() -> SecureRecordMaterial {
    SecureRecordMaterial::new([0x11; 32], [0x22; 32], [0x33; 32]).unwrap()
}

fn activate(value: &mut ScSecureConnection) -> OperationId {
    let record_operation = reach_record_preparation(value);
    let _ = apply(
        value,
        SecureConnectionEvent::RecordMaterialPrepared {
            generation: GENERATION,
            operation: record_operation,
            material: Some(material()),
        },
    );
    let _ = apply(
        value,
        SecureConnectionEvent::RecordsActivated {
            generation: GENERATION,
            operation: record_operation,
            success: true,
        },
    );
    record_operation
}

fn make_ready(value: &mut ScSecureConnection) {
    let operation = activate(value);
    let effects = apply(
        value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation,
            success: true,
        }),
    );
    assert!(effects.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyReady)
    )));
    assert_eq!(value.session_phase(), SessionPhase::Ready);
}

fn peer_frame(
    direction: RecordDirection,
    generation_delta: u64,
    channel: u8,
    payload: &[u8],
) -> Vec<u8> {
    let context = derive_session_context(
        local().as_bytes(),
        peer().as_bytes(),
        &[0x22; 32],
        &[0x33; 32],
    )
    .unwrap();
    let mut sealer = RecordSealer::new(
        &[0x11; 32],
        &context.bytes,
        direction,
        context.generation + generation_delta,
        MAX_RECORD_PLAINTEXT,
    )
    .unwrap();
    let record_type = match channel {
        0 => RecordType::Control,
        1 => RecordType::Video,
        2 => RecordType::Input,
        _ => panic!("test channel"),
    };
    let (_, record) = sealer.seal(record_type, 0, payload).unwrap();
    let mut frame = vec![0; record.len() + 6];
    superconnect_core::encode_frame(channel, 0, &record, &mut frame).unwrap();
    frame
}

#[test]
fn trusted_local_data_plane_requires_ready_and_terminal_error_only() {
    let mut value = trusted_connection();
    open(&mut value);
    let capability = apply(
        &mut value,
        session(SessionEvent::PeerHelloAck {
            generation: GENERATION,
            peer: peer(),
            auth_version: None,
            challenge: None,
            enrollment: false,
            peer_enrollment_key: None,
        }),
    );
    assert_eq!(value.session_phase(), SessionPhase::CapabilityCommit);
    assert!(capability.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::CommitCapabilities { .. })
    )));

    assert_eq!(
        value.sealed_frame_length(1, b"video".len()),
        Err(SecureConnectionError::RecordsNotActive)
    );
    assert_eq!(
        value.seal_outbound(1, 0, b"video"),
        Err(SecureConnectionError::RecordsNotActive)
    );
    assert_eq!(
        value.seal_outbound(2, 0, b"input"),
        Err(SecureConnectionError::RecordsNotActive)
    );

    let mut inbound = vec![0; b"video".len() + 6];
    superconnect_core::encode_frame(1, 0, b"video", &mut inbound).unwrap();
    assert_eq!(
        value.push_inbound(&inbound),
        Err(SecureConnectionError::RecordsNotActive)
    );
    assert_eq!(value.session_phase(), SessionPhase::Fatal);

    let terminal_error = br#"{"type":"error","reason":"auth_failed"}"#;
    assert!(value.seal_outbound(0, 0, terminal_error).is_ok());
    assert_eq!(
        value.seal_outbound(0, 0, br#"{"type":"ping","seq":1,"t0":1}"#),
        Err(SecureConnectionError::RecordsNotActive)
    );
    assert_eq!(
        value.seal_outbound(1, 0, b"video"),
        Err(SecureConnectionError::RecordsNotActive)
    );
    assert_eq!(
        value.seal_outbound(2, 0, b"input"),
        Err(SecureConnectionError::RecordsNotActive)
    );
}

#[test]
fn untrusted_peer_cannot_enter_auth_without_record_v1() {
    let mut value = connection();
    open(&mut value);
    let effects = apply(
        &mut value,
        session(SessionEvent::PeerHelloAck {
            generation: GENERATION,
            peer: peer(),
            auth_version: Some(AUTH_VERSION_1),
            challenge: Some(artifact(70)),
            enrollment: false,
            peer_enrollment_key: None,
        }),
    );
    assert!(effects.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::CloseTransport)
    )));
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
}

#[test]
fn untrusted_pre_record_plaintext_rejects_non_handshake_control() {
    let mut value = connection();
    open(&mut value);
    let _ = apply(
        &mut value,
        SecureConnectionEvent::PeerRecordVersion {
            generation: GENERATION,
            version: Some(1),
        },
    );
    let _ = apply(
        &mut value,
        session(SessionEvent::PeerHelloAck {
            generation: GENERATION,
            peer: peer(),
            auth_version: Some(AUTH_VERSION_1),
            challenge: Some(artifact(70)),
            enrollment: false,
            peer_enrollment_key: None,
        }),
    );

    let plaintext = concat!(
        "{\"type\":\"capability\",\"capabilityEnvelope\":{\"kind\":\"offer\",",
        "\"generation\":\"41\",\"version\":1,\"capabilities\":\"66049\",",
        "\"offererRole\":\"host\",\"selectorRole\":\"receiver\",",
        "\"projection\":\"mirror\",\"transport\":\"tcp\"}}"
    )
    .as_bytes();
    assert_eq!(
        value.seal_outbound(0, 0, plaintext),
        Err(SecureConnectionError::RecordsNotActive)
    );
    let mut frame = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut frame).unwrap();
    assert_eq!(
        value.push_inbound(&frame),
        Err(SecureConnectionError::PlaintextDowngrade)
    );
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
}

#[test]
fn untrusted_pre_record_plaintext_allows_only_canonical_handshake_control() {
    let mut value = connection();
    open(&mut value);
    let _ = apply(
        &mut value,
        SecureConnectionEvent::PeerRecordVersion {
            generation: GENERATION,
            version: Some(1),
        },
    );
    assert!(value
        .seal_outbound(0, 0, br#"{"type":"error","reason":"auth_failed"}"#)
        .is_ok());
    let plaintext = br#"{"type":"hello_ack","peerId":"sink-1","caps":{"codecs":["h264"],"screenWidth":1920,"screenHeight":1080,"scale":2,"refreshRate":60,"pen":true}}"#;
    let mut frame = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut frame).unwrap();
    let inbound = value.push_inbound(&frame).unwrap();
    assert_eq!(inbound.len(), 1);
    assert_eq!(inbound[0].control.as_ref().unwrap().kind, 2);
}

#[test]
fn terminal_pre_record_session_never_reopens_plaintext_control() {
    let mut value = connection();
    open(&mut value);
    let _ = apply(
        &mut value,
        session(SessionEvent::TransportFailed {
            generation: GENERATION,
        }),
    );
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);

    let plaintext = br#"{"type":"error","reason":"auth_failed"}"#;
    assert!(value.sealed_frame_length(0, plaintext.len()).is_ok());
    assert!(value.seal_outbound(0, 0, plaintext).is_ok());
    assert_eq!(
        value.seal_outbound(0, 0, br#"{"type":"hello","peerId":"source-1","caps":{"codecs":["h264"],"maxWidth":1920,"maxHeight":1080,"hidpi":false}}"#),
        Err(SecureConnectionError::RecordsNotActive)
    );
    let mut frame = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut frame).unwrap();
    assert_eq!(
        value.push_inbound(&frame),
        Err(SecureConnectionError::PlaintextDowngrade)
    );
}

#[test]
fn capability_commit_waits_for_prepared_and_activated_records() {
    let mut value = connection();
    let operation = reach_record_preparation(&mut value);
    assert_eq!(value.record_phase(), SecureRecordPhase::Preparing);
    assert_eq!(
        value.seal_outbound(0, 0, b"capability"),
        Err(SecureConnectionError::RecordsNotActive)
    );

    assert_eq!(
        apply(
            &mut value,
            SecureConnectionEvent::RecordMaterialPrepared {
                generation: GENERATION,
                operation,
                material: Some(material()),
            },
        ),
        vec![SecureConnectionEffect::ActivateRecords {
            generation: GENERATION,
            operation,
        }]
    );
    assert_eq!(value.record_phase(), SecureRecordPhase::Activating);

    assert_eq!(
        apply(
            &mut value,
            SecureConnectionEvent::RecordsActivated {
                generation: GENERATION,
                operation,
                success: true,
            },
        ),
        vec![SecureConnectionEffect::Session(
            SessionEffect::CommitCapabilities {
                operation,
                peer: peer(),
                media_role: MediaRole::Host,
            }
        )]
    );
    assert_eq!(value.record_phase(), SecureRecordPhase::Active);
    let encrypted = value.seal_outbound(0, 0, b"capability").unwrap();
    assert!(!encrypted
        .windows(b"capability".len())
        .any(|part| part == b"capability"));

    let ready = apply(
        &mut value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation,
            success: true,
        }),
    );
    assert!(ready.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyReady)
    )));
    assert_eq!(value.session_phase(), SessionPhase::Ready);
    assert!(value.invariants_hold());
}

#[test]
fn stale_record_completions_are_inert() {
    let mut value = connection();
    let record_operation = reach_record_preparation(&mut value);
    assert!(apply(
        &mut value,
        SecureConnectionEvent::RecordMaterialPrepared {
            generation: SessionGeneration::new(42),
            operation: record_operation,
            material: Some(material()),
        },
    )
    .is_empty());
    assert!(apply(
        &mut value,
        SecureConnectionEvent::RecordMaterialPrepared {
            generation: GENERATION,
            operation: operation(999),
            material: Some(material()),
        },
    )
    .is_empty());
    assert_eq!(value.record_phase(), SecureRecordPhase::Preparing);
}

#[test]
fn record_prepare_failure_is_terminal_and_disposes_pending_owner() {
    let mut value = connection();
    let operation = reach_record_preparation(&mut value);
    let effects = apply(
        &mut value,
        SecureConnectionEvent::RecordMaterialPrepared {
            generation: GENERATION,
            operation,
            material: None,
        },
    );
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, SecureConnectionEffect::DisposeRecords { .. })));
    assert!(effects.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyFatal(_))
    )));
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
}

#[test]
fn record_activation_failure_is_terminal_and_disposes_constructed_records() {
    let mut value = connection();
    let operation = reach_record_preparation(&mut value);
    let _ = apply(
        &mut value,
        SecureConnectionEvent::RecordMaterialPrepared {
            generation: GENERATION,
            operation,
            material: Some(material()),
        },
    );
    assert_eq!(value.record_phase(), SecureRecordPhase::Activating);
    let effects = apply(
        &mut value,
        SecureConnectionEvent::RecordsActivated {
            generation: GENERATION,
            operation,
            success: false,
        },
    );
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, SecureConnectionEffect::DisposeRecords { .. })));
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
    assert!(!value.records_active());
}

#[test]
fn capability_completion_before_record_activation_fails_closed() {
    let mut value = connection();
    let operation = reach_record_preparation(&mut value);
    let effects = apply(
        &mut value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation,
            success: true,
        }),
    );
    assert!(effects.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyFatal(_))
    )));
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
}

#[test]
fn same_generation_wrong_capability_completion_is_inert_through_record_activation() {
    let mut value = connection();
    let record_operation = reach_record_preparation(&mut value);

    assert!(apply(
        &mut value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation: operation(999),
            success: true,
        }),
    )
    .is_empty());
    assert_eq!(value.record_phase(), SecureRecordPhase::Preparing);

    assert_eq!(
        apply(
            &mut value,
            SecureConnectionEvent::RecordMaterialPrepared {
                generation: GENERATION,
                operation: record_operation,
                material: Some(material()),
            },
        ),
        vec![SecureConnectionEffect::ActivateRecords {
            generation: GENERATION,
            operation: record_operation,
        }]
    );
    assert_eq!(value.record_phase(), SecureRecordPhase::Activating);

    assert!(apply(
        &mut value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation: operation(998),
            success: true,
        }),
    )
    .is_empty());
    assert_eq!(value.record_phase(), SecureRecordPhase::Activating);

    assert_eq!(
        apply(
            &mut value,
            SecureConnectionEvent::RecordsActivated {
                generation: GENERATION,
                operation: record_operation,
                success: true,
            },
        ),
        vec![SecureConnectionEffect::Session(
            SessionEffect::CommitCapabilities {
                operation: record_operation,
                peer: peer(),
                media_role: MediaRole::Host,
            },
        )]
    );
    assert!(apply(
        &mut value,
        session(SessionEvent::CapabilitiesCommitted {
            generation: GENERATION,
            operation: record_operation,
            success: true,
        }),
    )
    .iter()
    .any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyReady)
    )));
    assert_eq!(value.session_phase(), SessionPhase::Ready);
    assert!(value.records_active());
}

#[test]
fn post_activation_plaintext_frame_is_rejected_and_disposes_records() {
    let mut value = connection();
    let _ = activate(&mut value);
    let plaintext = br#"{"type":"capability","generation":41,"capabilities":1}"#;
    let mut frame = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut frame).unwrap();
    assert_eq!(
        value.push_inbound(&frame),
        Err(SecureConnectionError::PlaintextDowngrade)
    );
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
    let terminal: Vec<_> = value.take_pending_effects().iter().cloned().collect();
    assert!(terminal
        .iter()
        .any(|effect| matches!(effect, SecureConnectionEffect::DisposeRecords { .. })));
    assert!(terminal.iter().any(|effect| matches!(
        effect,
        SecureConnectionEffect::Session(SessionEffect::NotifyFatal(
            SessionFatalReason::ProtocolViolation
        ))
    )));
}

#[test]
fn post_activation_plaintext_video_and_input_are_each_fatal() {
    for (channel, payload) in [(1, b"video".as_slice()), (2, b"input".as_slice())] {
        let mut value = connection();
        let _ = activate(&mut value);
        let mut frame = vec![0; payload.len() + 6];
        superconnect_core::encode_frame(channel, 0, payload, &mut frame).unwrap();
        assert_eq!(
            value.push_inbound(&frame),
            Err(SecureConnectionError::PlaintextDowngrade),
            "channel {channel} accepted authenticated plaintext"
        );
        assert_eq!(value.session_phase(), SessionPhase::Fatal);
        assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
    }
}

#[test]
fn terminal_cleanup_never_reopens_plaintext_control_after_record_activation() {
    let mut value = connection();
    activate(&mut value);
    let effects = apply(
        &mut value,
        session(SessionEvent::TransportFailed {
            generation: GENERATION,
        }),
    );
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, SecureConnectionEffect::DisposeRecords { .. })));
    assert_eq!(value.record_phase(), SecureRecordPhase::Disposed);
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
    assert_eq!(
        value.seal_outbound(0, 0, br#"{"type":"error","reason":"auth_failed"}"#),
        Err(SecureConnectionError::RecordsNotActive)
    );
}

#[test]
fn authenticated_control_is_opened_and_classified_once() {
    let mut value = connection();
    let _ = activate(&mut value);
    let frame = peer_frame(
        RecordDirection::ResponderToInitiator,
        0,
        0,
        br#"{"type":"ping","seq":7,"t0":123456}"#,
    );
    let opened = value.push_inbound(&frame).unwrap();
    assert_eq!(opened.len(), 1);
    assert_eq!(opened[0].channel, 0);
    assert!(opened[0].control.is_some());
}

#[test]
fn ready_connection_opens_scr1_control_and_video_before_consumers() {
    let mut value = connection();
    make_ready(&mut value);

    let control_payload = br#"{"type":"ping","seq":17,"t0":123456}"#;
    let control = peer_frame(RecordDirection::ResponderToInitiator, 0, 0, control_payload);
    assert_eq!(&control[6..10], b"SCR1");
    let opened_control = value.push_inbound(&control).unwrap();
    assert_eq!(opened_control.len(), 1);
    assert_eq!(opened_control[0].channel, 0);
    assert_eq!(opened_control[0].payload, control_payload);
    assert!(opened_control[0].control.is_some());

    let video_payload = b"annex-b-idr";
    let video = peer_frame(RecordDirection::ResponderToInitiator, 0, 1, video_payload);
    assert_eq!(&video[6..10], b"SCR1");
    let opened_video = value.push_inbound(&video).unwrap();
    assert_eq!(opened_video.len(), 1);
    assert_eq!(opened_video[0].channel, 1);
    assert_eq!(opened_video[0].payload, video_payload);
    assert!(opened_video[0].control.is_none());
}

#[test]
fn coalesced_transition_frame_waits_until_platform_advances_record_state() {
    let mut value = connection();
    let plaintext = br#"{"type":"hello_ack","peerId":"sink-1","caps":{"codecs":["h264"],"screenWidth":1920,"screenHeight":1080,"scale":2,"refreshRate":60,"pen":true}}"#;
    let mut first = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut first).unwrap();
    let encrypted = peer_frame(
        RecordDirection::ResponderToInitiator,
        0,
        0,
        br#"{"type":"ping","seq":2}"#,
    );
    let mut coalesced = first;
    coalesced.extend_from_slice(&encrypted);

    let before_activation = value.push_inbound(&coalesced).unwrap();
    assert_eq!(before_activation.len(), 1);
    assert_eq!(before_activation[0].payload, plaintext);

    activate(&mut value);
    let after_activation = value.push_inbound(&[]).unwrap();
    assert_eq!(after_activation.len(), 1);
    assert_eq!(after_activation[0].payload, br#"{"type":"ping","seq":2}"#);
}

#[test]
fn replay_wrong_direction_and_wrong_generation_fail_closed() {
    let mut replay = connection();
    let _ = activate(&mut replay);
    let valid = peer_frame(
        RecordDirection::ResponderToInitiator,
        0,
        0,
        br#"{"type":"ping","seq":7}"#,
    );
    assert!(replay.push_inbound(&valid).is_ok());
    assert_eq!(
        replay.push_inbound(&valid),
        Err(SecureConnectionError::RecordRejected)
    );
    assert_eq!(replay.session_phase(), SessionPhase::Fatal);

    let mut wrong_direction = connection();
    let _ = activate(&mut wrong_direction);
    let frame = peer_frame(
        RecordDirection::InitiatorToResponder,
        0,
        0,
        br#"{"type":"ping","seq":8}"#,
    );
    assert_eq!(
        wrong_direction.push_inbound(&frame),
        Err(SecureConnectionError::RecordRejected)
    );

    let mut wrong_generation = connection();
    let _ = activate(&mut wrong_generation);
    let frame = peer_frame(
        RecordDirection::ResponderToInitiator,
        1,
        0,
        br#"{"type":"ping","seq":9}"#,
    );
    assert_eq!(
        wrong_generation.push_inbound(&frame),
        Err(SecureConnectionError::RecordRejected)
    );
}

#[test]
fn encrypted_media_is_rejected_until_session_ready() {
    let mut value = connection();
    let _ = activate(&mut value);
    let frame = peer_frame(RecordDirection::ResponderToInitiator, 0, 1, b"idr");
    assert_eq!(
        value.push_inbound(&frame),
        Err(SecureConnectionError::RecordRejected)
    );
    assert_eq!(value.session_phase(), SessionPhase::Fatal);
}
