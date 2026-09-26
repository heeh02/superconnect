#pragma once

#include <stddef.h>

#include "superconnect_ffi_types.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_SESSION_MAX_EFFECTS_V1 = 8,
    SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1 = 128,
};

enum {
    SC_SESSION_CONTROL_KIND_BYE_V1 = 1,
    SC_SESSION_CONTROL_KIND_PING_V1 = 2,
    SC_SESSION_CONTROL_KIND_PONG_V1 = 3,
};

enum {
    SC_SESSION_CONTROL_FIELD_T0_V1 = 1U << 0,
    SC_SESSION_CONTROL_FIELD_T1_V1 = 1U << 1,
    SC_SESSION_CONTROL_FIELD_T2_V1 = 1U << 2,
};

enum {
    SC_SESSION_HELLO_KIND_HELLO_V1 = 1,
    SC_SESSION_HELLO_KIND_HELLO_ACK_V1 = 2,
    SC_SESSION_HELLO_ROLE_SOURCE_V1 = 1,
    SC_SESSION_HELLO_ROLE_RECEIVER_V1 = 2,
    SC_SESSION_HELLO_PROJECTION_EXTEND_V1 = 1,
    SC_SESSION_HELLO_PROJECTION_MIRROR_V1 = 2,
    SC_SESSION_HELLO_PROJECTION_PRIMARY_V1 = 3,
};

enum {
    SC_SESSION_HELLO_CODEC_H264_V1 = 1U << 0,
    SC_SESSION_HELLO_CODEC_HEVC_V1 = 1U << 1,
};

enum {
    SC_SESSION_HELLO_FIELD_CAPS_V1 = 1U << 0,
    SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1 = 1U << 1,
    SC_SESSION_HELLO_FIELD_CHALLENGE_V1 = 1U << 2,
    SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1 = 1U << 3,
};

enum {
    SC_SESSION_HELLO_CAP_MAX_WIDTH_V1 = 1U << 0,
    SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1 = 1U << 1,
    SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1 = 1U << 2,
    SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1 = 1U << 3,
    SC_SESSION_HELLO_CAP_SCALE_V1 = 1U << 4,
    SC_SESSION_HELLO_CAP_REFRESH_RATE_V1 = 1U << 5,
    SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1 = 1U << 6,
    SC_SESSION_HELLO_CAP_HIDPI_V1 = 1U << 7,
    SC_SESSION_HELLO_CAP_PEN_V1 = 1U << 8,
    SC_SESSION_HELLO_CAP_HDR_HLG_V1 = 1U << 9,
    SC_SESSION_HELLO_CAP_HDR_PQ_V1 = 1U << 10,
};

enum {
    SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1 = 1U << 0,
    SC_SESSION_HELLO_CAP_VALUE_PEN_V1 = 1U << 1,
    SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1 = 1U << 2,
    SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1 = 1U << 3,
};

enum {
    SC_SESSION_SIDE_INITIATOR = 1,
    SC_SESSION_SIDE_RESPONDER = 2,
};

enum {
    SC_SESSION_ORIGIN_TRUSTED_LOCAL = 1,
    SC_SESSION_ORIGIN_MUTUAL_AUTHENTICATION_REQUIRED = 2,
};

enum {
    SC_SESSION_MEDIA_ROLE_HOST = 1,
    SC_SESSION_MEDIA_ROLE_RECEIVER = 2,
};

enum {
    SC_SESSION_PHASE_IDLE = 0,
    SC_SESSION_PHASE_TRANSPORT = 1,
    SC_SESSION_PHASE_HELLO = 2,
    SC_SESSION_PHASE_CREDENTIAL = 3,
    SC_SESSION_PHASE_ENROLLMENT = 4,
    SC_SESSION_PHASE_MUTUAL_AUTH = 5,
    SC_SESSION_PHASE_ADMISSION = 6,
    SC_SESSION_PHASE_FINAL_ACK = 7,
    SC_SESSION_PHASE_CAPABILITY_COMMIT = 8,
    SC_SESSION_PHASE_READY = 9,
    SC_SESSION_PHASE_STREAMING = 10,
    SC_SESSION_PHASE_CLOSING = 11,
    SC_SESSION_PHASE_CLOSED = 12,
    SC_SESSION_PHASE_FATAL = 13,
};

enum {
    SC_SESSION_CREDENTIAL_NONE = 0,
    SC_SESSION_CREDENTIAL_MISSING = 1,
    SC_SESSION_CREDENTIAL_PRESENT = 2,
    SC_SESSION_CREDENTIAL_UNAVAILABLE = 3,
};

#define SC_SESSION_FIELD_GENERATION (UINT64_C(1) << 0)
#define SC_SESSION_FIELD_OPERATION (UINT64_C(1) << 1)
#define SC_SESSION_FIELD_TIMER_TOKEN (UINT64_C(1) << 2)
#define SC_SESSION_FIELD_ADMISSION_CLAIM (UINT64_C(1) << 3)
#define SC_SESSION_FIELD_CREDENTIAL (UINT64_C(1) << 4)
#define SC_SESSION_FIELD_CANDIDATE_CREDENTIAL (UINT64_C(1) << 5)
#define SC_SESSION_FIELD_CHALLENGE (UINT64_C(1) << 6)
#define SC_SESSION_FIELD_LOCAL_CHALLENGE (UINT64_C(1) << 7)
#define SC_SESSION_FIELD_PEER_CHALLENGE (UINT64_C(1) << 8)
#define SC_SESSION_FIELD_PROOF (UINT64_C(1) << 9)
#define SC_SESSION_FIELD_ENVELOPE (UINT64_C(1) << 10)
#define SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY (UINT64_C(1) << 11)
#define SC_SESSION_FIELD_PEER_ENROLLMENT_KEY (UINT64_C(1) << 12)
#define SC_SESSION_FIELD_IDENTITY (UINT64_C(1) << 13)
#define SC_SESSION_FIELD_AUTH_VERSION (UINT64_C(1) << 14)

enum {
    SC_SESSION_EVENT_START = 1,
    SC_SESSION_EVENT_TRANSPORT_OPENED = 2,
    SC_SESSION_EVENT_PEER_HELLO_ACK = 3,
    SC_SESSION_EVENT_PEER_HELLO = 4,
    SC_SESSION_EVENT_CREDENTIAL_LOADED = 5,
    SC_SESSION_EVENT_ENROLLMENT_OPENED = 6,
    SC_SESSION_EVENT_ENROLLMENT_APPROVED = 7,
    SC_SESSION_EVENT_ENROLLMENT_PREPARED = 8,
    SC_SESSION_EVENT_CHALLENGE_GENERATED = 9,
    SC_SESSION_EVENT_AUTH_PROOF_CREATED = 10,
    SC_SESSION_EVENT_PEER_AUTH = 11,
    SC_SESSION_EVENT_PEER_PROOF_VERIFIED = 12,
    SC_SESSION_EVENT_ADMISSION_CLAIM_SUCCEEDED = 13,
    SC_SESSION_EVENT_ADMISSION_CLAIM_FAILED = 14,
    SC_SESSION_EVENT_MUTUAL_PROOF_CREATED = 15,
    SC_SESSION_EVENT_PEER_AUTH_ACK = 16,
    SC_SESSION_EVENT_MUTUAL_PROOF_VERIFIED = 17,
    SC_SESSION_EVENT_CREDENTIAL_WRITE_COMPLETED = 18,
    SC_SESSION_EVENT_FINAL_ACK_SUBMITTED = 19,
    SC_SESSION_EVENT_CAPABILITIES_COMMITTED = 20,
    SC_SESSION_EVENT_STREAMING_STARTED = 21,
    SC_SESSION_EVENT_CLOSE_REQUESTED = 22,
    SC_SESSION_EVENT_TRANSPORT_CLOSED = 23,
    SC_SESSION_EVENT_TRANSPORT_FAILED = 24,
    SC_SESSION_EVENT_TIMER_FIRED = 25,
};

enum {
    SC_SESSION_EFFECT_OPEN_TRANSPORT = 1,
    SC_SESSION_EFFECT_ARM_HANDSHAKE_TIMER = 2,
    SC_SESSION_EFFECT_CANCEL_HANDSHAKE_TIMER = 3,
    SC_SESSION_EFFECT_SEND_HELLO = 4,
    SC_SESSION_EFFECT_LOAD_CREDENTIAL = 5,
    SC_SESSION_EFFECT_OPEN_ENROLLMENT = 6,
    SC_SESSION_EFFECT_REQUEST_ENROLLMENT_APPROVAL = 7,
    SC_SESSION_EFFECT_PREPARE_ENROLLMENT = 8,
    SC_SESSION_EFFECT_GENERATE_CHALLENGE = 9,
    SC_SESSION_EFFECT_SEND_HELLO_ACK = 10,
    SC_SESSION_EFFECT_SEND_ENROLLMENT = 11,
    SC_SESSION_EFFECT_CREATE_AUTH_PROOF = 12,
    SC_SESSION_EFFECT_VERIFY_PEER_PROOF = 13,
    SC_SESSION_EFFECT_CLAIM_ADMISSION = 14,
    SC_SESSION_EFFECT_CREATE_MUTUAL_PROOF = 15,
    SC_SESSION_EFFECT_SUBMIT_FINAL_AUTH_ACK = 16,
    SC_SESSION_EFFECT_SUBMIT_FINAL_HELLO_ACK = 17,
    SC_SESSION_EFFECT_SEND_AUTH = 18,
    SC_SESSION_EFFECT_VERIFY_MUTUAL_PROOF = 19,
    SC_SESSION_EFFECT_WRITE_CREDENTIAL = 20,
    SC_SESSION_EFFECT_CANCEL_CREDENTIAL_WRITE = 21,
    SC_SESSION_EFFECT_COMMIT_CAPABILITIES = 22,
    SC_SESSION_EFFECT_NOTIFY_READY = 23,
    SC_SESSION_EFFECT_NOTIFY_STREAMING = 24,
    SC_SESSION_EFFECT_CLOSE_TRANSPORT = 25,
    SC_SESSION_EFFECT_NOTIFY_CLOSED = 26,
    SC_SESSION_EFFECT_RELEASE_ADMISSION = 27,
    SC_SESSION_EFFECT_NOTIFY_FATAL = 28,
};

enum {
    SC_SESSION_FATAL_NONE = 0,
    SC_SESSION_FATAL_AUTHENTICATION_REQUIRED = 1,
    SC_SESSION_FATAL_AUTHENTICATION_FAILED = 2,
    SC_SESSION_FATAL_UNEXPECTED_REENROLLMENT = 3,
    SC_SESSION_FATAL_CREDENTIAL_UNAVAILABLE = 4,
    SC_SESSION_FATAL_CAPABILITY_COMMIT_FAILED = 5,
    SC_SESSION_FATAL_ADMISSION_REJECTED = 6,
    SC_SESSION_FATAL_HANDSHAKE_TIMED_OUT = 7,
    SC_SESSION_FATAL_IDENTIFIER_SPACE_EXHAUSTED = 8,
    SC_SESSION_FATAL_TRANSPORT_FAILED = 9,
    SC_SESSION_FATAL_FINAL_ACK_FAILED = 10,
    SC_SESSION_FATAL_PAIRING_REJECTED = 11,
    SC_SESSION_FATAL_PROTOCOL_VIOLATION = 12,
};

/* Empty means absent. A present identity has length 1..128 and zero tail. */
typedef struct ScSessionPeerIdentityV1 {
    uint32_t length;
    uint8_t bytes[SC_SESSION_MAX_PEER_IDENTITY_BYTES_V1];
} ScSessionPeerIdentityV1;

/* Stable 192-byte configuration. Every identifier is required and nonzero. */
typedef struct ScSessionConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t first_operation_id;
    uint64_t local_enrollment_key;
    uint32_t side;
    uint32_t media_role;
    uint32_t origin;
    uint32_t reserved0;
    ScSessionPeerIdentityV1 local_identity;
    uint32_t reserved1;
    uint64_t reserved2;
} ScSessionConfigV1;

/*
 * Stable 280-byte semantic event. presence must exactly match the event type.
 * A present u64 identifier is nonzero; an absent value is zero. Fields not
 * selected by type are zero, including identity length and its entire tail.
 */
typedef struct ScSessionEventV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t type;
    uint32_t credential_state;
    uint64_t presence;
    uint64_t generation;
    uint64_t operation;
    uint64_t timer_token;
    uint64_t admission_claim;
    uint64_t credential;
    uint64_t candidate_credential;
    uint64_t challenge;
    uint64_t local_challenge;
    uint64_t peer_challenge;
    uint64_t proof;
    uint64_t envelope;
    uint64_t local_enrollment_key;
    uint64_t peer_enrollment_key;
    uint16_t auth_version;
    uint8_t enrollment;
    uint8_t approved;
    uint8_t valid;
    uint8_t success;
    uint8_t reserved0[2];
    ScSessionPeerIdentityV1 peer_identity;
    uint32_t reserved1;
    uint64_t reserved2;
} ScSessionEventV1;

/* Stable 280-byte copied semantic effect; it never borrows handle storage. */
typedef struct ScSessionEffectV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t type;
    uint32_t fatal_reason;
    uint64_t presence;
    uint64_t generation;
    uint64_t operation;
    uint64_t timer_token;
    uint64_t admission_claim;
    uint64_t credential;
    uint64_t candidate_credential;
    uint64_t challenge;
    uint64_t local_challenge;
    uint64_t peer_challenge;
    uint64_t proof;
    uint64_t envelope;
    uint64_t local_enrollment_key;
    uint64_t peer_enrollment_key;
    uint16_t auth_version;
    uint8_t media_role;
    uint8_t enrollment;
    uint32_t reserved0;
    ScSessionPeerIdentityV1 identity;
    uint32_t reserved1;
    uint64_t reserved2;
} ScSessionEffectV1;

/* Stable 208-byte copied snapshot. */
typedef struct ScSessionSnapshotV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint64_t generation;
    uint64_t first_operation_id;
    uint64_t local_enrollment_key;
    uint32_t phase;
    uint32_t side;
    uint32_t media_role;
    uint32_t origin;
    uint32_t pending_timer_count;
    uint32_t pending_operation_count;
    uint32_t invariants_hold;
    uint32_t reserved0;
    ScSessionPeerIdentityV1 local_identity;
    uint32_t reserved1;
    uint64_t reserved2;
} ScSessionSnapshotV1;

/* Stable 56-byte canonical bye/ping/pong CONTROL record. */
typedef struct ScSessionControlWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t kind;
    uint32_t presence;
    uint64_t sequence;
    uint64_t t0;
    uint64_t t1;
    uint64_t t2;
    uint64_t reserved;
} ScSessionControlWireV1;

typedef struct ScSessionHelloTextV1 {
    uint32_t length;
    uint8_t bytes[128];
} ScSessionHelloTextV1;

/* Stable copied hello/hello_ack record; it never borrows a platform string or wire buffer. */
typedef struct ScSessionHelloWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t kind;
    uint32_t supported_roles;
    uint64_t presence;
    uint16_t protocol_version;
    uint16_t auth_version;
    uint16_t record_version;
    uint16_t capability_version;
    uint16_t capability_intent_version;
    uint16_t frame_meta_version;
    uint16_t media_recovery_version;
    uint16_t udp_video_version;
    uint16_t udp_video_port;
    uint16_t reserved0;
    uint32_t desired_role;
    uint32_t accepted_role;
    uint32_t projection;
    uint32_t codecs;
    uint32_t caps_presence;
    uint32_t caps_values;
    uint32_t max_width;
    uint32_t max_height;
    uint32_t screen_width;
    uint32_t screen_height;
    uint32_t refresh_rate;
    uint32_t refresh_rate_max;
    uint32_t reserved_scale;
    double scale;
    ScSessionHelloTextV1 legacy_role;
    ScSessionHelloTextV1 peer_id;
    ScSessionHelloTextV1 platform;
    ScSessionHelloTextV1 device_name;
    ScSessionHelloTextV1 app_version;
    ScSessionHelloTextV1 pairing_token;
    uint8_t enrollment_key[65];
    uint8_t challenge[32];
    uint8_t needs_pairing;
    uint8_t reserved1[6];
    uint64_t reserved2;
} ScSessionHelloWireV1;

typedef struct ScSessionV1 ScSessionV1;

/*
 * The opaque handle has exactly one owner and must be accessed serially. Core
 * retains no caller pointer and owns no callback, thread, platform object,
 * crypto object, credential store, application payload, or wire buffer.
 */
ScStatus sc_session_new_v1(const ScSessionConfigV1* config, ScSessionV1** output);
ScStatus sc_session_free_v1(ScSessionV1* session);

/*
 * The caller supplies at least SC_SESSION_MAX_EFFECTS_V1 slots. A smaller
 * capacity returns SC_BUFFER_TOO_SMALL, written=0, needed=8, and does not
 * advance state. Success writes copied effects, actual written, and needed=8.
 */
ScStatus sc_session_apply_v1(
    ScSessionV1* session,
    const ScSessionEventV1* event,
    ScSessionEffectV1* effects,
    uint32_t effect_capacity,
    uint32_t* written,
    uint32_t* needed
);
ScStatus sc_session_snapshot_v1(const ScSessionV1* session, ScSessionSnapshotV1* output);
ScStatus sc_session_control_wire_encode_v1(
    const ScSessionControlWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_session_control_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScSessionControlWireV1* output
);
ScStatus sc_session_hello_wire_encode_v1(
    const ScSessionHelloWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_session_hello_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScSessionHelloWireV1* output
);

#ifdef __cplusplus
}
#endif
