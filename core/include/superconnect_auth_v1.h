#pragma once

#include <stddef.h>
#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_AUTH_MAX_PEER_ID_BYTES = 128,
    SC_AUTH_PAIR_SECRET_BYTES = 32,
    SC_AUTH_NONCE_BYTES = 32,
    SC_AUTH_PROOF_BYTES = 32,
    SC_AUTH_P256_PRIVATE_BYTES = 32,
    SC_AUTH_P256_PUBLIC_BYTES = 65,
    SC_AUTH_PAIRING_SALT_BYTES = 16,
    SC_AUTH_AEAD_NONCE_BYTES = 12,
    SC_AUTH_PAIR_KEY_BYTES = 32,
    SC_AUTH_SEALED_SECRET_BYTES = 48,
    SC_AUTH_WIRE_KIND_AUTH = 1,
    SC_AUTH_WIRE_KIND_AUTH_ACK = 2,
    SC_AUTH_WIRE_KIND_PAIR_SECRET = 3,
};

/* A well-formed proof or authenticated ciphertext did not verify. */
enum {
    SC_AUTHENTICATION_FAILED = 100,
};

/*
 * Stable 144-byte canonical peer identity. length is 1..128; bytes after
 * length and reserved must be zero. The selected bytes must satisfy the
 * SC-AUTH-v1 UTF-8 identity grammar.
 */
typedef struct ScAuthPeerIdV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t length;
    uint32_t reserved;
    uint8_t bytes[SC_AUTH_MAX_PEER_ID_BYTES];
} ScAuthPeerIdV1;

/* Stable 344-byte directional HMAC proof request. */
typedef struct ScAuthProofCreateRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t prover_id_length;
    uint32_t verifier_id_length;
    uint32_t reserved[2];
    uint8_t pair_secret[SC_AUTH_PAIR_SECRET_BYTES];
    uint8_t nonce[SC_AUTH_NONCE_BYTES];
    uint8_t prover_id[SC_AUTH_MAX_PEER_ID_BYTES];
    uint8_t verifier_id[SC_AUTH_MAX_PEER_ID_BYTES];
} ScAuthProofCreateRequestV1;

/* Stable 376-byte directional HMAC verification request. */
typedef struct ScAuthProofVerifyRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t prover_id_length;
    uint32_t verifier_id_length;
    uint32_t reserved[2];
    uint8_t pair_secret[SC_AUTH_PAIR_SECRET_BYTES];
    uint8_t nonce[SC_AUTH_NONCE_BYTES];
    uint8_t prover_id[SC_AUTH_MAX_PEER_ID_BYTES];
    uint8_t verifier_id[SC_AUTH_MAX_PEER_ID_BYTES];
    uint8_t proof[SC_AUTH_PROOF_BYTES];
} ScAuthProofVerifyRequestV1;

typedef struct ScAuthP256PrivateRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t private_scalar[SC_AUTH_P256_PRIVATE_BYTES];
} ScAuthP256PrivateRequestV1;

/* Stable 128-byte P-256 ECDH + HKDF request. */
typedef struct ScAuthPairKeyDeriveRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t private_scalar[SC_AUTH_P256_PRIVATE_BYTES];
    uint8_t peer_public_key[SC_AUTH_P256_PUBLIC_BYTES];
    uint8_t pairing_salt[SC_AUTH_PAIRING_SALT_BYTES];
    uint8_t reserved[7];
} ScAuthPairKeyDeriveRequestV1;

typedef struct ScAuthSealRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t pair_secret[SC_AUTH_PAIR_SECRET_BYTES];
    uint8_t pair_key[SC_AUTH_PAIR_KEY_BYTES];
    uint8_t nonce[SC_AUTH_AEAD_NONCE_BYTES];
    uint8_t reserved[4];
} ScAuthSealRequestV1;

typedef struct ScAuthOpenRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t sealed_secret[SC_AUTH_SEALED_SECRET_BYTES];
    uint8_t pair_key[SC_AUTH_PAIR_KEY_BYTES];
    uint8_t nonce[SC_AUTH_AEAD_NONCE_BYTES];
    uint8_t reserved[4];
} ScAuthOpenRequestV1;

typedef struct ScAuthProofV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t proof[SC_AUTH_PROOF_BYTES];
} ScAuthProofV1;

typedef struct ScAuthP256PublicKeyV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t public_key[SC_AUTH_P256_PUBLIC_BYTES];
    uint8_t reserved[7];
} ScAuthP256PublicKeyV1;

typedef struct ScAuthPairKeyV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t pair_key[SC_AUTH_PAIR_KEY_BYTES];
} ScAuthPairKeyV1;

typedef struct ScAuthSealedPairSecretV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t sealed_secret[SC_AUTH_SEALED_SECRET_BYTES];
} ScAuthSealedPairSecretV1;

typedef struct ScAuthPairSecretV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t pair_secret[SC_AUTH_PAIR_SECRET_BYTES];
} ScAuthPairSecretV1;

/* Stable 160-byte canonical auth CONTROL record. Unused fields and reserved bytes are zero. */
typedef struct ScAuthWireMessageV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t kind;
    uint8_t reserved0[7];
    uint8_t proof[SC_AUTH_PROOF_BYTES];
    uint8_t challenge[SC_AUTH_NONCE_BYTES];
    uint8_t sealed_secret[SC_AUTH_SEALED_SECRET_BYTES];
    uint8_t pairing_salt[SC_AUTH_PAIRING_SALT_BYTES];
    uint8_t aead_nonce[SC_AUTH_AEAD_NONCE_BYTES];
    uint8_t reserved1[4];
} ScAuthWireMessageV1;

/* Canonical auth/auth_ack/pair_secret JSON. Output is not NUL-terminated. */
ScStatus sc_auth_wire_encode_v1(
    const ScAuthWireMessageV1* message,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

/* Caller initializes output.struct_size and output.api_version. */
ScStatus sc_auth_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScAuthWireMessageV1* output
);

/*
 * All functions are deterministic, retain no pointer, and call no host code.
 * Outputs are written only after complete validation and cryptographic success.
 * Proof order is directional: prover_id then verifier_id. Verification/open of
 * well-formed but unauthentic data returns SC_AUTHENTICATION_FAILED.
 */
ScStatus sc_auth_peer_id_validate_v1(const ScAuthPeerIdV1* input);
ScStatus sc_auth_proof_create_v1(
    const ScAuthProofCreateRequestV1* input,
    ScAuthProofV1* output
);
ScStatus sc_auth_proof_verify_v1(const ScAuthProofVerifyRequestV1* input);
ScStatus sc_auth_p256_public_from_private_v1(
    const ScAuthP256PrivateRequestV1* input,
    ScAuthP256PublicKeyV1* output
);
ScStatus sc_auth_pair_key_derive_v1(
    const ScAuthPairKeyDeriveRequestV1* input,
    ScAuthPairKeyV1* output
);
ScStatus sc_auth_pair_secret_seal_v1(
    const ScAuthSealRequestV1* input,
    ScAuthSealedPairSecretV1* output
);
ScStatus sc_auth_pair_secret_open_v1(
    const ScAuthOpenRequestV1* input,
    ScAuthPairSecretV1* output
);

#ifdef __cplusplus
}
#endif
