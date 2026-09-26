#pragma once

#include <stddef.h>
#include <stdint.h>

#include "superconnect_auth_v1.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_RECORD_PAIR_SECRET_BYTES = 32,
    SC_RECORD_SESSION_CONTEXT_BYTES = 32,
    SC_RECORD_CHALLENGE_BYTES = 32,
    SC_RECORD_MAX_PEER_ID_BYTES = 128,
    SC_RECORD_HEADER_BYTES = 32,
    SC_RECORD_TAG_BYTES = 16,
    SC_RECORD_OVERHEAD_BYTES = 48,
    SC_RECORD_MAX_PLAINTEXT_BYTES = 16 * 1024 * 1024,
};

enum {
    SC_RECORD_DIRECTION_INITIATOR_TO_RESPONDER = 1,
    SC_RECORD_DIRECTION_RESPONDER_TO_INITIATOR = 2,
};

enum {
    SC_RECORD_TYPE_CONTROL = 1,
    SC_RECORD_TYPE_VIDEO = 2,
    SC_RECORD_TYPE_INPUT = 3,
};

enum {
    SC_RECORD_REPLAYED = 110,
    SC_RECORD_COUNTER_EXHAUSTED = 111,
    SC_RECORD_TOO_LARGE = 112,
};

/* Stable 96-byte layout on supported 32-bit and 64-bit C ABIs. */
typedef struct ScRecordConfigV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t pair_secret[SC_RECORD_PAIR_SECRET_BYTES];
    uint8_t session_context[SC_RECORD_SESSION_CONTEXT_BYTES];
    uint64_t session_generation;
    uint64_t max_plaintext_bytes;
    uint8_t direction;
    uint8_t reserved[7];
} ScRecordConfigV1;

/* Stable 344-byte transcript-to-context request. */
typedef struct ScRecordContextRequestV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t initiator_peer_id_length;
    uint32_t responder_peer_id_length;
    uint32_t reserved[2];
    uint8_t responder_challenge[SC_RECORD_CHALLENGE_BYTES];
    uint8_t initiator_challenge[SC_RECORD_CHALLENGE_BYTES];
    uint8_t initiator_peer_id[SC_RECORD_MAX_PEER_ID_BYTES];
    uint8_t responder_peer_id[SC_RECORD_MAX_PEER_ID_BYTES];
} ScRecordContextRequestV1;

/* Stable 48-byte canonical context and nonzero wire generation. */
typedef struct ScRecordContextV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint8_t bytes[SC_RECORD_SESSION_CONTEXT_BYTES];
    uint64_t session_generation;
} ScRecordContextV1;

typedef struct ScRecordSealerV1 ScRecordSealerV1;
typedef struct ScRecordOpenerV1 ScRecordOpenerV1;

ScStatus sc_record_context_derive_v1(
    const ScRecordContextRequestV1* request,
    ScRecordContextV1* output
);

/* Handles have one owner, retain no platform pointer, and must be used serially. */
ScStatus sc_record_sealer_new_v1(
    const ScRecordConfigV1* config,
    ScRecordSealerV1** output
);
ScStatus sc_record_sealer_free_v1(ScRecordSealerV1* sealer);
ScStatus sc_record_opener_new_v1(
    const ScRecordConfigV1* config,
    ScRecordOpenerV1** output
);
ScStatus sc_record_opener_free_v1(ScRecordOpenerV1* opener);

/*
 * A null output with zero capacity is a non-consuming size query and returns
 * SC_BUFFER_TOO_SMALL, including for an empty plaintext. All non-SC_OK calls
 * leave the output bytes unchanged. Open commits its counter only after full
 * authentication and successful copy into caller-owned output.
 */
ScStatus sc_record_seal_v1(
    ScRecordSealerV1* sealer,
    uint8_t record_type,
    uint8_t flags,
    const uint8_t* plaintext,
    size_t plaintext_length,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);
ScStatus sc_record_open_v1(
    ScRecordOpenerV1* opener,
    uint8_t expected_record_type,
    const uint8_t* record,
    size_t record_length,
    uint8_t* authenticated_flags,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

#ifdef __cplusplus
}
#endif
