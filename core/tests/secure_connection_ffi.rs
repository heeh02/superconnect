use std::mem::{offset_of, size_of};
use std::ptr;

use superconnect_core::record_v1::{
    derive_session_context, RecordDirection, RecordSealer, RecordType,
};
use superconnect_core::secure_connection::MAX_SECURE_PLAINTEXT;
use superconnect_core::*;

const GENERATION: u64 = 41;
const LOCAL_IDENTITY: &[u8] = b"source-local";
const PEER_IDENTITY: &[u8] = b"receiver-peer";
const RECORD_OPERATION: u64 = 15;

struct Handle(*mut ScSecureConnectionV1);

impl Handle {
    fn raw(&self) -> *mut ScSecureConnectionV1 {
        self.0
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        assert_eq!(unsafe { sc_secure_connection_free_v1(self.0) }, SC_OK);
        self.0 = ptr::null_mut();
    }
}

fn identity(bytes: &[u8]) -> ScSessionPeerIdentityV1 {
    let mut output = ScSessionPeerIdentityV1 {
        length: bytes.len() as u32,
        ..ScSessionPeerIdentityV1::default()
    };
    output.bytes[..bytes.len()].copy_from_slice(bytes);
    output
}

fn config() -> ScSecureConnectionConfigV1 {
    ScSecureConnectionConfigV1 {
        struct_size: size_of::<ScSecureConnectionConfigV1>() as u32,
        api_version: SC_API_VERSION_V1,
        session: ScSessionConfigV1 {
            struct_size: size_of::<ScSessionConfigV1>() as u32,
            api_version: SC_API_VERSION_V1,
            generation: GENERATION,
            first_operation_id: 10,
            local_enrollment_key: 60,
            side: SC_SESSION_SIDE_INITIATOR,
            media_role: SC_SESSION_MEDIA_ROLE_HOST,
            origin: SC_SESSION_ORIGIN_MUTUAL_AUTHENTICATION_REQUIRED,
            reserved0: 0,
            local_identity: identity(LOCAL_IDENTITY),
            reserved1: 0,
            reserved2: 0,
        },
        max_plaintext_bytes: 0,
        reserved0: 0,
        reserved1: 0,
    }
}

fn new_handle() -> Handle {
    let mut output = ptr::null_mut();
    assert_eq!(
        unsafe { sc_secure_connection_new_v1(&config(), &mut output) },
        SC_OK
    );
    assert!(!output.is_null());
    Handle(output)
}

fn event(event_type: u32) -> ScSessionEventV1 {
    ScSessionEventV1 {
        struct_size: size_of::<ScSessionEventV1>() as u32,
        api_version: SC_API_VERSION_V1,
        event_type,
        credential_state: SC_SESSION_CREDENTIAL_NONE,
        presence: SC_SESSION_FIELD_GENERATION,
        generation: GENERATION,
        ..ScSessionEventV1::default()
    }
}

fn operation_event(event_type: u32, operation: u64) -> ScSessionEventV1 {
    ScSessionEventV1 {
        presence: SC_SESSION_FIELD_GENERATION | SC_SESSION_FIELD_OPERATION,
        operation,
        ..event(event_type)
    }
}

fn apply(handle: &Handle, event: &ScSessionEventV1) {
    assert_eq!(
        unsafe { sc_secure_connection_apply_session_v1(handle.raw(), event) },
        SC_OK
    );
}

fn effect_output() -> ScSecureConnectionEffectV1 {
    ScSecureConnectionEffectV1 {
        struct_size: size_of::<ScSecureConnectionEffectV1>() as u32,
        api_version: SC_API_VERSION_V1,
        ..ScSecureConnectionEffectV1::default()
    }
}

fn drain(handle: &Handle) -> Vec<ScSecureConnectionEffectV1> {
    let mut output = Vec::new();
    loop {
        let mut effect = effect_output();
        match unsafe { sc_secure_connection_pop_effect_v1(handle.raw(), &mut effect) } {
            SC_OK => output.push(effect),
            SC_NO_FRAME => return output,
            status => panic!("unexpected pop status {status}"),
        }
    }
}

fn snapshot(handle: &Handle) -> ScSecureConnectionSnapshotV1 {
    let mut output = ScSecureConnectionSnapshotV1 {
        struct_size: size_of::<ScSecureConnectionSnapshotV1>() as u32,
        api_version: SC_API_VERSION_V1,
        ..ScSecureConnectionSnapshotV1::default()
    };
    assert_eq!(
        unsafe { sc_secure_connection_snapshot_v1(handle.raw(), &mut output) },
        SC_OK
    );
    output
}

fn reach_record_preparation(handle: &Handle) {
    apply(handle, &event(SC_SESSION_EVENT_START));
    assert_eq!(drain(handle).len(), 2);
    apply(
        handle,
        &operation_event(SC_SESSION_EVENT_TRANSPORT_OPENED, 10),
    );
    let opened = drain(handle);
    assert_eq!(opened.len(), 1);
    assert_eq!(
        opened[0].session_effect.effect_type,
        SC_SESSION_EFFECT_SEND_HELLO
    );
    assert_eq!(
        unsafe { sc_secure_connection_observe_record_version_v1(handle.raw(), GENERATION, 1) },
        SC_OK
    );
    assert!(drain(handle).is_empty());

    let hello = ScSessionEventV1 {
        presence: SC_SESSION_FIELD_GENERATION
            | SC_SESSION_FIELD_IDENTITY
            | SC_SESSION_FIELD_AUTH_VERSION
            | SC_SESSION_FIELD_CHALLENGE,
        peer_identity: identity(PEER_IDENTITY),
        auth_version: 1,
        challenge: 70,
        ..event(SC_SESSION_EVENT_PEER_HELLO_ACK)
    };
    apply(handle, &hello);
    assert_eq!(
        drain(handle)[0].session_effect.effect_type,
        SC_SESSION_EFFECT_LOAD_CREDENTIAL
    );

    let credential = ScSessionEventV1 {
        credential_state: SC_SESSION_CREDENTIAL_PRESENT,
        presence: SC_SESSION_FIELD_GENERATION
            | SC_SESSION_FIELD_OPERATION
            | SC_SESSION_FIELD_CREDENTIAL,
        operation: 12,
        credential: 71,
        ..event(SC_SESSION_EVENT_CREDENTIAL_LOADED)
    };
    apply(handle, &credential);
    assert_eq!(
        drain(handle)[0].session_effect.effect_type,
        SC_SESSION_EFFECT_CREATE_AUTH_PROOF
    );

    let proof = ScSessionEventV1 {
        presence: SC_SESSION_FIELD_GENERATION
            | SC_SESSION_FIELD_OPERATION
            | SC_SESSION_FIELD_PROOF
            | SC_SESSION_FIELD_LOCAL_CHALLENGE,
        operation: 13,
        proof: 72,
        local_challenge: 73,
        ..event(SC_SESSION_EVENT_AUTH_PROOF_CREATED)
    };
    apply(handle, &proof);
    assert_eq!(
        drain(handle)[0].session_effect.effect_type,
        SC_SESSION_EFFECT_SEND_AUTH
    );

    let ack = ScSessionEventV1 {
        presence: SC_SESSION_FIELD_GENERATION | SC_SESSION_FIELD_PROOF,
        proof: 74,
        ..event(SC_SESSION_EVENT_PEER_AUTH_ACK)
    };
    apply(handle, &ack);
    assert_eq!(
        drain(handle)[0].session_effect.effect_type,
        SC_SESSION_EFFECT_VERIFY_MUTUAL_PROOF
    );

    let verified = ScSessionEventV1 {
        presence: SC_SESSION_FIELD_GENERATION | SC_SESSION_FIELD_OPERATION,
        operation: 14,
        valid: 1,
        ..event(SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED)
    };
    apply(handle, &verified);
}

fn material() -> ScSecureRecordMaterialV1 {
    ScSecureRecordMaterialV1 {
        struct_size: size_of::<ScSecureRecordMaterialV1>() as u32,
        api_version: SC_API_VERSION_V1,
        generation: GENERATION,
        operation: RECORD_OPERATION,
        success: 1,
        reserved0: [0; 7],
        pair_secret: [0x11; 32],
        responder_challenge: [0x22; 32],
        initiator_challenge: [0x33; 32],
        reserved1: 0,
    }
}

fn activate(handle: &Handle) {
    reach_record_preparation(handle);
    let effects = drain(handle);
    assert_eq!(effects.len(), 1);
    assert_eq!(
        effects[0].effect_type,
        SC_SECURE_CONNECTION_EFFECT_PREPARE_RECORD_CONTEXT_V1
    );
    assert_eq!(effects[0].operation, RECORD_OPERATION);

    assert_eq!(
        unsafe { sc_secure_connection_record_material_prepared_v1(handle.raw(), &material()) },
        SC_OK
    );
    let effects = drain(handle);
    assert_eq!(effects.len(), 1);
    assert_eq!(
        effects[0].effect_type,
        SC_SECURE_CONNECTION_EFFECT_ACTIVATE_RECORDS_V1
    );

    assert_eq!(
        unsafe {
            sc_secure_connection_records_activated_v1(handle.raw(), GENERATION, RECORD_OPERATION, 1)
        },
        SC_OK
    );
    let effects = drain(handle);
    assert_eq!(effects.len(), 1);
    assert_eq!(
        effects[0].effect_type,
        SC_SECURE_CONNECTION_EFFECT_SESSION_V1
    );
    assert_eq!(
        effects[0].session_effect.effect_type,
        SC_SESSION_EFFECT_COMMIT_CAPABILITIES
    );
}

fn make_ready(handle: &Handle) {
    activate(handle);
    apply(
        handle,
        &ScSessionEventV1 {
            success: 1,
            ..operation_event(SC_SESSION_EVENT_CAPABILITIES_COMMITTED, RECORD_OPERATION)
        },
    );
    let effects = drain(handle);
    assert!(effects
        .iter()
        .any(|effect| { effect.session_effect.effect_type == SC_SESSION_EFFECT_NOTIFY_READY }));
}

fn peer_frame(payload: &[u8]) -> Vec<u8> {
    let context =
        derive_session_context(LOCAL_IDENTITY, PEER_IDENTITY, &[0x22; 32], &[0x33; 32]).unwrap();
    let mut sealer = RecordSealer::new(
        &[0x11; 32],
        &context.bytes,
        RecordDirection::ResponderToInitiator,
        context.generation,
        MAX_SECURE_PLAINTEXT,
    )
    .unwrap();
    let (_, record) = sealer.seal(RecordType::Control, 0, payload).unwrap();
    let mut frame = vec![0; record.len() + 6];
    superconnect_core::encode_frame(0, 0, &record, &mut frame).unwrap();
    frame
}

#[test]
fn abi_layout_and_config_are_versioned() {
    assert_eq!(offset_of!(ScSecureConnectionConfigV1, session), 8);
    assert_eq!(offset_of!(ScSecureConnectionEffectV1, session_effect), 32);
    assert_eq!(size_of::<ScSecureRecordMaterialV1>(), 136);
    assert_eq!(
        unsafe { sc_secure_connection_free_v1(ptr::null_mut()) },
        SC_OK
    );

    let mut invalid = config();
    invalid.api_version += 1;
    let mut output = ptr::dangling_mut::<ScSecureConnectionV1>();
    assert_eq!(
        unsafe { sc_secure_connection_new_v1(&invalid, &mut output) },
        SC_UNSUPPORTED_VERSION
    );
    assert!(output.is_null());

    let handle = new_handle();
    let state = snapshot(&handle);
    assert_eq!(state.generation, GENERATION);
    assert_eq!(state.session_phase, SC_SESSION_PHASE_IDLE);
    assert_eq!(state.record_phase, SC_SECURE_CONNECTION_RECORD_INACTIVE_V1);
    assert_eq!(state.records_required, 1);
    assert_eq!(state.invariants_hold, 1);
}

#[test]
fn capability_is_held_until_real_record_activation_completion() {
    let handle = new_handle();
    reach_record_preparation(&handle);
    assert_eq!(
        unsafe {
            sc_secure_connection_records_activated_v1(handle.raw(), GENERATION, RECORD_OPERATION, 1)
        },
        SC_SECURE_CONNECTION_PENDING_OUTPUT
    );
    let prepare = drain(&handle);
    assert_eq!(prepare[0].operation, RECORD_OPERATION);

    assert_eq!(
        unsafe { sc_secure_connection_record_material_prepared_v1(handle.raw(), &material()) },
        SC_OK
    );
    assert_eq!(
        snapshot(&handle).record_phase,
        SC_SECURE_CONNECTION_RECORD_ACTIVATING_V1
    );
    let _ = drain(&handle);
    assert_eq!(
        unsafe {
            sc_secure_connection_records_activated_v1(handle.raw(), GENERATION, RECORD_OPERATION, 1)
        },
        SC_OK
    );
    assert_eq!(
        snapshot(&handle).record_phase,
        SC_SECURE_CONNECTION_RECORD_ACTIVE_V1
    );
    assert_eq!(
        snapshot(&handle).session_phase,
        SC_SESSION_PHASE_CAPABILITY_COMMIT
    );
    assert_eq!(
        drain(&handle)[0].session_effect.effect_type,
        SC_SESSION_EFFECT_COMMIT_CAPABILITIES
    );
}

#[test]
fn seal_query_does_not_advance_counter_and_inbound_is_canonical() {
    let handle = new_handle();
    make_ready(&handle);
    let control = br#"{"type":"ping","seq":7,"t0":123456}"#;

    let mut needed = usize::MAX;
    assert_eq!(
        unsafe {
            sc_secure_connection_seal_frame_v1(
                handle.raw(),
                0,
                0,
                control.as_ptr(),
                control.len(),
                ptr::null_mut(),
                0,
                &mut needed,
            )
        },
        SC_BUFFER_TOO_SMALL
    );
    let mut sealed = vec![0; needed];
    assert_eq!(
        unsafe {
            sc_secure_connection_seal_frame_v1(
                handle.raw(),
                0,
                0,
                control.as_ptr(),
                control.len(),
                sealed.as_mut_ptr(),
                sealed.len(),
                &mut needed,
            )
        },
        SC_OK
    );
    assert_eq!(u64::from_le_bytes(sealed[22..30].try_into().unwrap()), 1);

    let peer = peer_frame(control);
    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), peer.as_ptr(), peer.len()) },
        SC_OK
    );
    let mut view = ScSecureInboundViewV1 {
        struct_size: size_of::<ScSecureInboundViewV1>() as u32,
        api_version: SC_API_VERSION_V1,
        ..ScSecureInboundViewV1::default()
    };
    assert_eq!(
        unsafe { sc_secure_connection_next_inbound_v1(handle.raw(), &mut view) },
        SC_OK
    );
    assert_eq!(view.channel, 0);
    assert_eq!(view.control_present, 1);
    assert_eq!(view.control.kind, SC_CONTROL_KIND_PING_V1);
    assert_eq!(
        unsafe { std::slice::from_raw_parts(view.payload, view.payload_length) },
        control
    );
    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), ptr::null(), 0) },
        SC_SECURE_CONNECTION_PENDING_OUTPUT
    );
    assert_eq!(
        unsafe { sc_secure_connection_consume_inbound_v1(handle.raw(), view.generation + 1) },
        SC_STALE_VIEW
    );
    assert_eq!(
        unsafe { sc_secure_connection_consume_inbound_v1(handle.raw(), view.generation) },
        SC_OK
    );
}

#[test]
fn coalesced_transition_push_exposes_one_frame_per_platform_state_boundary() {
    let handle = new_handle();
    let plaintext = br#"{"type":"hello_ack","peerId":"sink-1","caps":{"codecs":["h264"],"screenWidth":1920,"screenHeight":1080,"scale":2,"refreshRate":60,"pen":true}}"#;
    let mut first = vec![0; plaintext.len() + 6];
    superconnect_core::encode_frame(0, 0, plaintext, &mut first).unwrap();
    let encrypted = peer_frame(br#"{"type":"ping","seq":2}"#);
    let mut coalesced = first;
    coalesced.extend_from_slice(&encrypted);

    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), coalesced.as_ptr(), coalesced.len()) },
        SC_OK
    );
    assert_eq!(snapshot(&handle).pending_inbound_count, 1);
    let mut first_view = ScSecureInboundViewV1 {
        struct_size: size_of::<ScSecureInboundViewV1>() as u32,
        api_version: SC_API_VERSION_V1,
        ..ScSecureInboundViewV1::default()
    };
    assert_eq!(
        unsafe { sc_secure_connection_next_inbound_v1(handle.raw(), &mut first_view) },
        SC_OK
    );
    assert_eq!(
        unsafe { std::slice::from_raw_parts(first_view.payload, first_view.payload_length) },
        plaintext
    );
    assert_eq!(
        unsafe { sc_secure_connection_consume_inbound_v1(handle.raw(), first_view.generation) },
        SC_OK
    );

    activate(&handle);
    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), ptr::null(), 0) },
        SC_OK
    );
    let mut second_view = ScSecureInboundViewV1 {
        struct_size: size_of::<ScSecureInboundViewV1>() as u32,
        api_version: SC_API_VERSION_V1,
        ..ScSecureInboundViewV1::default()
    };
    assert_eq!(
        unsafe { sc_secure_connection_next_inbound_v1(handle.raw(), &mut second_view) },
        SC_OK
    );
    assert_eq!(
        unsafe { std::slice::from_raw_parts(second_view.payload, second_view.payload_length) },
        br#"{"type":"ping","seq":2}"#
    );
    assert_eq!(
        unsafe { sc_secure_connection_consume_inbound_v1(handle.raw(), second_view.generation) },
        SC_OK
    );
}

#[test]
fn pre_record_plaintext_capability_is_rejected_by_the_ffi_boundary() {
    let handle = new_handle();
    apply(&handle, &event(SC_SESSION_EVENT_START));
    let _ = drain(&handle);
    apply(
        &handle,
        &operation_event(SC_SESSION_EVENT_TRANSPORT_OPENED, 10),
    );
    let _ = drain(&handle);
    let capability = concat!(
        "{\"type\":\"capability\",\"capabilityEnvelope\":{\"kind\":\"offer\",",
        "\"generation\":\"41\",\"version\":1,\"capabilities\":\"66049\",",
        "\"offererRole\":\"host\",\"selectorRole\":\"receiver\",",
        "\"projection\":\"mirror\",\"transport\":\"tcp\"}}"
    );
    let mut plaintext = vec![0; capability.len() + 6];
    superconnect_core::encode_frame(0, 0, capability.as_bytes(), &mut plaintext).unwrap();
    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), plaintext.as_ptr(), plaintext.len()) },
        SC_SECURE_CONNECTION_PROTOCOL_REJECTED
    );
    assert_eq!(snapshot(&handle).session_phase, SC_SESSION_PHASE_FATAL);
    assert_eq!(
        snapshot(&handle).record_phase,
        SC_SECURE_CONNECTION_RECORD_DISPOSED_V1
    );
}

#[test]
fn plaintext_downgrade_fails_closed_and_disposes_record_owner() {
    let handle = new_handle();
    make_ready(&handle);
    let control = br#"{"type":"ping","seq":9,"t0":1}"#;
    let mut plaintext = vec![0; control.len() + 6];
    superconnect_core::encode_frame(0, 0, control, &mut plaintext).unwrap();
    assert_eq!(
        unsafe { sc_secure_connection_push_v1(handle.raw(), plaintext.as_ptr(), plaintext.len()) },
        SC_SECURE_CONNECTION_PROTOCOL_REJECTED
    );
    let state = snapshot(&handle);
    assert_eq!(state.session_phase, SC_SESSION_PHASE_FATAL);
    assert_eq!(state.record_phase, SC_SECURE_CONNECTION_RECORD_DISPOSED_V1);
    let effects = drain(&handle);
    assert!(effects
        .iter()
        .any(|effect| { effect.effect_type == SC_SECURE_CONNECTION_EFFECT_DISPOSE_RECORDS_V1 }));
    assert!(effects.iter().any(|effect| {
        effect.effect_type == SC_SECURE_CONNECTION_EFFECT_SESSION_V1
            && effect.session_effect.effect_type == SC_SESSION_EFFECT_NOTIFY_FATAL
            && effect.session_effect.fatal_reason == SC_SESSION_FATAL_PROTOCOL_VIOLATION
    }));
}
