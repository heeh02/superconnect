use serde_json::Value;
use superconnect_core::auth_v1::{
    auth_context, auth_proof, derive_pair_key, open_pair_secret, p256_public_key, seal_pair_secret,
    verify_auth_proof, AeadNonce, AuthNonce, AuthProof, P256PrivateScalar, P256PublicKey, PairKey,
    PairSecret, PairingSalt, PeerId, SealedPairSecret, MAX_PEER_ID_UTF8_BYTES,
};

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../proto/auth-vectors.json"))
        .expect("proto/auth-vectors.json must remain valid JSON")
}

fn hex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).unwrap();
            u8::from_str_radix(text, 16).unwrap()
        })
        .collect()
}

fn b64_value(value: u8) -> u8 {
    match value {
        b'A'..=b'Z' => value - b'A',
        b'a'..=b'z' => value - b'a' + 26,
        b'0'..=b'9' => value - b'0' + 52,
        b'+' => 62,
        b'/' => 63,
        _ => panic!("invalid base64 fixture"),
    }
}

fn b64(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    assert_eq!(bytes.len() % 4, 0);
    let mut output = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks_exact(4) {
        let a = b64_value(chunk[0]);
        let b = b64_value(chunk[1]);
        output.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = b64_value(chunk[2]);
            output.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                output.push((c << 6) | b64_value(chunk[3]));
            }
        }
    }
    output
}

fn peer(value: &str) -> PeerId {
    PeerId::try_from(value).unwrap()
}

#[test]
fn golden_auth_proofs_are_directional_and_byte_exact() {
    let document = vectors();
    let hmac = &document["hmac"];
    let secret_bytes = hex(hmac["secretHex"].as_str().unwrap());
    let secret = PairSecret::try_from(secret_bytes.as_slice()).unwrap();
    let first = peer(hmac["macPeerId"].as_str().unwrap());
    let second = peer(hmac["tabletPeerId"].as_str().unwrap());

    let first_nonce_bytes = b64(hmac["nonceB64"].as_str().unwrap());
    let first_nonce = AuthNonce::try_from(first_nonce_bytes.as_slice()).unwrap();
    let first_context = auth_context(&first, &second, &first_nonce).unwrap();
    assert_eq!(
        first_context.as_bytes(),
        hmac["contextMac"].as_str().unwrap().as_bytes()
    );
    let first_expected_bytes = b64(hmac["proofMacB64"].as_str().unwrap());
    let first_expected = AuthProof::try_from(first_expected_bytes.as_slice()).unwrap();
    let first_actual = auth_proof(&secret, &first, &second, &first_nonce).unwrap();
    assert_eq!(first_actual.as_bytes(), first_expected.as_bytes());
    assert!(verify_auth_proof(
        &first_expected,
        &secret,
        &first,
        &second,
        &first_nonce
    ));

    let second_nonce_bytes = b64(hmac["macNonceB64"].as_str().unwrap());
    let second_nonce = AuthNonce::try_from(second_nonce_bytes.as_slice()).unwrap();
    let second_context = auth_context(&second, &first, &second_nonce).unwrap();
    assert_eq!(
        second_context.as_bytes(),
        hmac["contextPad"].as_str().unwrap().as_bytes()
    );
    let second_expected_bytes = b64(hmac["proofPadB64"].as_str().unwrap());
    let second_expected = AuthProof::try_from(second_expected_bytes.as_slice()).unwrap();
    assert_eq!(
        auth_proof(&secret, &second, &first, &second_nonce)
            .unwrap()
            .as_bytes(),
        second_expected.as_bytes()
    );
    assert!(!verify_auth_proof(
        &first_expected,
        &secret,
        &second,
        &first,
        &first_nonce
    ));
}

#[test]
fn wrong_proof_secret_or_peer_identity_is_rejected() {
    let document = vectors();
    let hmac = &document["hmac"];
    let secret_bytes = hex(hmac["secretHex"].as_str().unwrap());
    let secret = PairSecret::try_from(secret_bytes.as_slice()).unwrap();
    let prover = peer(hmac["macPeerId"].as_str().unwrap());
    let verifier = peer(hmac["tabletPeerId"].as_str().unwrap());
    let nonce_bytes = b64(hmac["nonceB64"].as_str().unwrap());
    let nonce = AuthNonce::try_from(nonce_bytes.as_slice()).unwrap();
    let proof_bytes = b64(hmac["proofMacB64"].as_str().unwrap());
    let proof = AuthProof::try_from(proof_bytes.as_slice()).unwrap();

    let mut tampered_bytes = proof_bytes;
    tampered_bytes[7] ^= 0x80;
    let tampered = AuthProof::try_from(tampered_bytes.as_slice()).unwrap();
    assert!(!verify_auth_proof(
        &tampered, &secret, &prover, &verifier, &nonce
    ));

    let wrong_verifier = peer("33333333-3333-4333-8333-333333333333");
    assert!(!verify_auth_proof(
        &proof,
        &secret,
        &prover,
        &wrong_verifier,
        &nonce
    ));

    let mut wrong_secret_bytes = secret_bytes;
    wrong_secret_bytes[0] ^= 1;
    let wrong_secret = PairSecret::try_from(wrong_secret_bytes.as_slice()).unwrap();
    assert!(!verify_auth_proof(
        &proof,
        &wrong_secret,
        &prover,
        &verifier,
        &nonce
    ));
}

#[test]
fn peer_identity_uses_the_frozen_utf8_grammar() {
    assert!(PeerId::try_from("a").is_ok());
    assert!(PeerId::try_from("a".repeat(MAX_PEER_ID_UTF8_BYTES).as_str()).is_ok());
    assert!(PeerId::try_from("界".repeat(42).as_str()).is_ok());

    assert!(PeerId::try_from("").is_err());
    assert!(PeerId::try_from("a".repeat(MAX_PEER_ID_UTF8_BYTES + 1).as_str()).is_err());
    assert!(PeerId::try_from("界".repeat(43).as_str()).is_err());
    assert!(PeerId::try_from("left|right").is_err());
    for control in ['\u{0000}', '\u{001f}', '\u{007f}', '\u{009f}'] {
        assert!(PeerId::try_from(format!("peer{control}").as_str()).is_err());
    }
    assert!(PeerId::try_from(&[0xf0, 0x28, 0x8c, 0x28][..]).is_err());
}

#[test]
fn fixed_width_inputs_reject_every_wrong_length() {
    for length in [0, 31, 33] {
        let bytes = vec![1_u8; length];
        assert!(PairSecret::try_from(bytes.as_slice()).is_err());
        assert!(AuthNonce::try_from(bytes.as_slice()).is_err());
        assert!(AuthProof::try_from(bytes.as_slice()).is_err());
        assert!(PairKey::try_from(bytes.as_slice()).is_err());
        assert!(P256PrivateScalar::try_from(bytes.as_slice()).is_err());
    }
    for length in [0, 15, 17] {
        assert!(PairingSalt::try_from(vec![1_u8; length].as_slice()).is_err());
    }
    for length in [0, 11, 13] {
        assert!(AeadNonce::try_from(vec![1_u8; length].as_slice()).is_err());
    }
    for length in [0, 64, 66] {
        assert!(P256PublicKey::try_from(vec![1_u8; length].as_slice()).is_err());
    }
    for length in [0, 47, 49] {
        assert!(SealedPairSecret::try_from(vec![1_u8; length].as_slice()).is_err());
    }
}

#[test]
fn golden_p256_public_keys_and_ecdh_hkdf_are_byte_exact() {
    let document = vectors();
    let ecdh = &document["ecdh"];
    let first_scalar_bytes = hex(ecdh["macEphScalarHex"].as_str().unwrap());
    let second_scalar_bytes = hex(ecdh["tabletEphScalarHex"].as_str().unwrap());
    let first_scalar = P256PrivateScalar::try_from(first_scalar_bytes.as_slice()).unwrap();
    let second_scalar = P256PrivateScalar::try_from(second_scalar_bytes.as_slice()).unwrap();
    let first_public_bytes = b64(ecdh["macEphPubB64"].as_str().unwrap());
    let second_public_bytes = b64(ecdh["tabletEphPubB64"].as_str().unwrap());
    let first_public = P256PublicKey::try_from(first_public_bytes.as_slice()).unwrap();
    let second_public = P256PublicKey::try_from(second_public_bytes.as_slice()).unwrap();

    assert_eq!(
        p256_public_key(&first_scalar).as_bytes(),
        first_public.as_bytes()
    );
    assert_eq!(
        p256_public_key(&second_scalar).as_bytes(),
        second_public.as_bytes()
    );

    let salt_bytes = b64(ecdh["saltB64"].as_str().unwrap());
    let salt = PairingSalt::try_from(salt_bytes.as_slice()).unwrap();
    let expected_key = hex(ecdh["ecdhKeyHex"].as_str().unwrap());
    let first_key = derive_pair_key(&first_scalar, &second_public, &salt).unwrap();
    let second_key = derive_pair_key(&second_scalar, &first_public, &salt).unwrap();
    assert_eq!(first_key.as_bytes(), expected_key.as_slice());
    assert_eq!(second_key.as_bytes(), expected_key.as_slice());
}

#[test]
fn invalid_private_scalars_and_public_points_fail_closed() {
    assert!(P256PrivateScalar::try_from([0_u8; 32].as_slice()).is_err());
    assert!(P256PrivateScalar::try_from([0xff_u8; 32].as_slice()).is_err());

    let mut wrong_prefix = [0_u8; 65];
    wrong_prefix[0] = 0x02;
    assert!(P256PublicKey::try_from(wrong_prefix.as_slice()).is_err());

    let mut off_curve = [0_u8; 65];
    off_curve[0] = 0x04;
    off_curve[32] = 1;
    off_curve[64] = 1;
    assert!(P256PublicKey::try_from(off_curve.as_slice()).is_err());

    let compressed = [0x02_u8; 33];
    assert!(P256PublicKey::try_from(compressed.as_slice()).is_err());
}

#[test]
fn golden_aes_gcm_seals_and_opens_a_fixed_pair_secret() {
    let document = vectors();
    let ecdh = &document["ecdh"];
    let key_bytes = hex(ecdh["ecdhKeyHex"].as_str().unwrap());
    let key = PairKey::try_from(key_bytes.as_slice()).unwrap();
    let nonce_bytes = b64(ecdh["aeadNonceB64"].as_str().unwrap());
    let nonce = AeadNonce::try_from(nonce_bytes.as_slice()).unwrap();
    let secret_bytes = hex(ecdh["plaintextSecretHex"].as_str().unwrap());
    let secret = PairSecret::try_from(secret_bytes.as_slice()).unwrap();
    let expected_bytes = b64(ecdh["encSecretB64"].as_str().unwrap());
    let expected = SealedPairSecret::try_from(expected_bytes.as_slice()).unwrap();

    let sealed = seal_pair_secret(&secret, &key, &nonce).unwrap();
    assert_eq!(sealed.as_bytes(), expected.as_bytes());
    let opened = open_pair_secret(&expected, &key, &nonce).unwrap();
    assert_eq!(opened.as_bytes(), secret_bytes.as_slice());
}

#[test]
fn aes_gcm_rejects_wrong_tag_key_nonce_and_valid_but_wrong_ecdh_scalar() {
    let document = vectors();
    let ecdh = &document["ecdh"];
    let key_bytes = hex(ecdh["ecdhKeyHex"].as_str().unwrap());
    let key = PairKey::try_from(key_bytes.as_slice()).unwrap();
    let nonce_bytes = b64(ecdh["aeadNonceB64"].as_str().unwrap());
    let nonce = AeadNonce::try_from(nonce_bytes.as_slice()).unwrap();
    let sealed_bytes = b64(ecdh["encSecretB64"].as_str().unwrap());

    let mut wrong_tag_bytes = sealed_bytes.clone();
    wrong_tag_bytes[47] ^= 1;
    let wrong_tag = SealedPairSecret::try_from(wrong_tag_bytes.as_slice()).unwrap();
    assert!(open_pair_secret(&wrong_tag, &key, &nonce).is_err());

    let mut wrong_key_bytes = key_bytes;
    wrong_key_bytes[3] ^= 1;
    let wrong_key = PairKey::try_from(wrong_key_bytes.as_slice()).unwrap();
    let sealed = SealedPairSecret::try_from(sealed_bytes.as_slice()).unwrap();
    assert!(open_pair_secret(&sealed, &wrong_key, &nonce).is_err());

    let mut wrong_nonce_bytes = nonce_bytes;
    wrong_nonce_bytes[0] ^= 1;
    let wrong_nonce = AeadNonce::try_from(wrong_nonce_bytes.as_slice()).unwrap();
    assert!(open_pair_secret(&sealed, &key, &wrong_nonce).is_err());

    let first_scalar_bytes = hex(ecdh["macEphScalarHex"].as_str().unwrap());
    let first_scalar = P256PrivateScalar::try_from(first_scalar_bytes.as_slice()).unwrap();
    let first_public_bytes = b64(ecdh["macEphPubB64"].as_str().unwrap());
    let first_public = P256PublicKey::try_from(first_public_bytes.as_slice()).unwrap();
    let salt_bytes = b64(ecdh["saltB64"].as_str().unwrap());
    let salt = PairingSalt::try_from(salt_bytes.as_slice()).unwrap();
    let self_derived_wrong_key = derive_pair_key(&first_scalar, &first_public, &salt).unwrap();
    assert!(open_pair_secret(&sealed, &self_derived_wrong_key, &nonce).is_err());
}

#[test]
fn sensitive_debug_output_is_redacted() {
    let bytes = [7_u8; 32];
    let secret = PairSecret::try_from(bytes.as_slice()).unwrap();
    let key = PairKey::try_from(bytes.as_slice()).unwrap();
    let scalar = P256PrivateScalar::try_from(bytes.as_slice()).unwrap();
    assert_eq!(format!("{secret:?}"), "PairSecret(REDACTED)");
    assert_eq!(format!("{key:?}"), "PairKey(REDACTED)");
    assert_eq!(format!("{scalar:?}"), "P256PrivateScalar(REDACTED)");
}
