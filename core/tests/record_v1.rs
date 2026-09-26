use superconnect_core::record_v1::{
    derive_session_context, RecordDirection, RecordError, RecordOpener, RecordSealer, RecordType,
    MAX_RECORD_PLAINTEXT, RECORD_CONTEXT_BYTES, RECORD_HEADER_BYTES, RECORD_KEY_BYTES,
    RECORD_OVERHEAD_BYTES,
};

const SECRET: [u8; RECORD_KEY_BYTES] = [0x11; RECORD_KEY_BYTES];
const CONTEXT: [u8; RECORD_CONTEXT_BYTES] = [0x22; RECORD_CONTEXT_BYTES];
const GENERATION: u64 = 0x0102_0304_0506_0708;

fn sealer(direction: RecordDirection, generation: u64, maximum: usize) -> RecordSealer {
    RecordSealer::new(&SECRET, &CONTEXT, direction, generation, maximum).unwrap()
}

fn opener(direction: RecordDirection, generation: u64, maximum: usize) -> RecordOpener {
    RecordOpener::new(&SECRET, &CONTEXT, direction, generation, maximum).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[test]
fn golden_record_and_all_type_direction_round_trips_are_exact() {
    let context =
        derive_session_context(b"mac-peer", b"pad-peer", &[0x33; 32], &[0x44; 32]).unwrap();
    assert_eq!(
        hex(&context.bytes),
        "5942c4b5e28c86346fee9765f45f7deca85d450547cf24105deada794285a218"
    );
    assert_eq!(context.generation, 0x3486_8ce2_b5c4_4259);
    let mut golden_sealer = sealer(RecordDirection::InitiatorToResponder, GENERATION, 64);
    let (metadata, golden) = golden_sealer
        .seal(RecordType::Control, 0, b"hello record")
        .unwrap();
    assert_eq!(metadata.counter, 1);
    assert_eq!(golden.len(), b"hello record".len() + RECORD_OVERHEAD_BYTES);
    assert_eq!(
        hex(&golden),
        "5343523101010100080706050403020101000000000000000c000000000000008a5a195b04b71c973031afe5b33e833258e8008dc8a511b108dd2e31"
    );

    for direction in [
        RecordDirection::InitiatorToResponder,
        RecordDirection::ResponderToInitiator,
    ] {
        for record_type in [RecordType::Control, RecordType::Video, RecordType::Input] {
            let mut seal = sealer(direction, GENERATION, 64);
            let mut open = opener(direction, GENERATION, 64);
            let (sealed_metadata, record) = seal.seal(record_type, 0xa5, b"payload").unwrap();
            assert_eq!(sealed_metadata.flags, 0xa5);
            assert_eq!(open.plaintext_length(&record), Ok(7));
            let (opened_metadata, plaintext) = open.open(&record).unwrap();
            assert_eq!(opened_metadata, sealed_metadata);
            assert_eq!(plaintext, b"payload");
        }
    }

    let mut seal = sealer(RecordDirection::InitiatorToResponder, GENERATION, 64);
    let mut open = opener(RecordDirection::InitiatorToResponder, GENERATION, 64);
    let (control_meta, control) = seal.seal(RecordType::Control, 0, b"control").unwrap();
    let (video_meta, video) = seal.seal(RecordType::Video, 1, b"video").unwrap();
    assert_eq!((control_meta.counter, video_meta.counter), (1, 1));
    assert_eq!(open.open(&video).unwrap().1, b"video");
    assert_eq!(open.open(&control).unwrap().1, b"control");
}

#[test]
fn key_derivation_separates_secret_context_direction_and_generation() {
    let payload = b"same bytes";
    let (_, baseline) = sealer(RecordDirection::InitiatorToResponder, 7, 64)
        .seal(RecordType::Control, 0, payload)
        .unwrap();
    let (_, reverse) = sealer(RecordDirection::ResponderToInitiator, 7, 64)
        .seal(RecordType::Control, 0, payload)
        .unwrap();
    let (_, next_generation) = sealer(RecordDirection::InitiatorToResponder, 8, 64)
        .seal(RecordType::Control, 0, payload)
        .unwrap();
    let mut other_context = CONTEXT;
    other_context[0] ^= 1;
    let (_, context_record) = RecordSealer::new(
        &SECRET,
        &other_context,
        RecordDirection::InitiatorToResponder,
        7,
        64,
    )
    .unwrap()
    .seal(RecordType::Control, 0, payload)
    .unwrap();
    assert_ne!(baseline, reverse);
    assert_ne!(baseline, next_generation);
    assert_ne!(baseline, context_record);

    let mut wrong_secret = SECRET;
    wrong_secret[0] ^= 1;
    let mut wrong_opener = RecordOpener::new(
        &wrong_secret,
        &CONTEXT,
        RecordDirection::InitiatorToResponder,
        7,
        64,
    )
    .unwrap();
    assert_eq!(
        wrong_opener.open(&baseline),
        Err(RecordError::AuthenticationFailed)
    );
    assert_eq!(
        opener(RecordDirection::ResponderToInitiator, 7, 64).open(&baseline),
        Err(RecordError::WrongDirection)
    );
    assert_eq!(
        opener(RecordDirection::InitiatorToResponder, 8, 64).open(&baseline),
        Err(RecordError::WrongGeneration)
    );
}

#[test]
fn header_ciphertext_and_tag_tampering_fail_without_advancing_state() {
    let (_, record) = sealer(RecordDirection::InitiatorToResponder, GENERATION, 64)
        .seal(RecordType::Control, 0, b"authenticated")
        .unwrap();
    for index in [5, 16, RECORD_HEADER_BYTES, record.len() - 1] {
        let mut tampered = record.clone();
        tampered[index] ^= 1;
        let mut open = opener(RecordDirection::InitiatorToResponder, GENERATION, 64);
        assert!(open.open(&tampered).is_err(), "tamper index {index}");
        assert_eq!(open.open(&record).unwrap().1, b"authenticated");
    }

    let mut reserved = record.clone();
    reserved[28] = 1;
    assert_eq!(
        opener(RecordDirection::InitiatorToResponder, GENERATION, 64).open(&reserved),
        Err(RecordError::InvalidRecord)
    );
}

#[test]
fn replay_late_reorder_and_malformed_lengths_fail_closed() {
    let mut seal = sealer(RecordDirection::InitiatorToResponder, GENERATION, 64);
    let (_, first) = seal.seal(RecordType::Video, 1, b"first").unwrap();
    let (_, second) = seal.seal(RecordType::Video, 0, b"second").unwrap();
    let mut open = opener(RecordDirection::InitiatorToResponder, GENERATION, 64);
    assert_eq!(open.open(&second).unwrap().1, b"second");
    assert_eq!(open.open(&first), Err(RecordError::ReplayOrReorder));
    assert_eq!(open.open(&second), Err(RecordError::ReplayOrReorder));

    let mut truncated = first.clone();
    truncated.pop();
    assert_eq!(
        opener(RecordDirection::InitiatorToResponder, GENERATION, 64).open(&truncated),
        Err(RecordError::InvalidRecord)
    );
    let mut extended = first;
    extended.push(0);
    assert_eq!(
        opener(RecordDirection::InitiatorToResponder, GENERATION, 64).open(&extended),
        Err(RecordError::InvalidRecord)
    );
}

#[test]
fn empty_boundary_and_invalid_configuration_are_explicit() {
    let mut seal = sealer(RecordDirection::ResponderToInitiator, 1, 8);
    let (_, empty) = seal.seal(RecordType::Input, 0, &[]).unwrap();
    assert_eq!(empty.len(), RECORD_OVERHEAD_BYTES);
    assert_eq!(
        opener(RecordDirection::ResponderToInitiator, 1, 8)
            .open(&empty)
            .unwrap()
            .1,
        b""
    );
    assert_eq!(seal.required_length(8), Ok(8 + RECORD_OVERHEAD_BYTES));
    assert_eq!(seal.required_length(9), Err(RecordError::PlaintextTooLarge));
    assert_eq!(
        sealer(
            RecordDirection::InitiatorToResponder,
            1,
            MAX_RECORD_PLAINTEXT
        )
        .required_length(MAX_RECORD_PLAINTEXT + 1),
        Err(RecordError::PlaintextTooLarge)
    );

    assert!(matches!(
        RecordSealer::new(
            &[0; RECORD_KEY_BYTES],
            &CONTEXT,
            RecordDirection::InitiatorToResponder,
            1,
            8
        ),
        Err(RecordError::InvalidSecret)
    ));
    assert!(matches!(
        RecordOpener::new(
            &SECRET,
            &[0; RECORD_CONTEXT_BYTES],
            RecordDirection::InitiatorToResponder,
            1,
            8
        ),
        Err(RecordError::InvalidContext)
    ));
    assert!(matches!(
        RecordSealer::new(
            &SECRET,
            &CONTEXT,
            RecordDirection::InitiatorToResponder,
            0,
            8
        ),
        Err(RecordError::InvalidGeneration)
    ));
    assert!(matches!(
        RecordOpener::new(
            &SECRET,
            &CONTEXT,
            RecordDirection::InitiatorToResponder,
            1,
            0
        ),
        Err(RecordError::InvalidMaximum)
    ));
}
