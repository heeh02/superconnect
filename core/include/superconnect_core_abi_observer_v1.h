#pragma once

/*
 * Shared raw observer for the canonical Core ABI behavior contract.
 *
 * This header deliberately contains no expected values and makes no pass/fail
 * decision about the six functions it calls. Platform gates must feed the JSON
 * to the independent Python oracle and separately bind the probed bytes to the
 * final artifact. Keeping the implementation here prevents platform wrappers
 * from growing divergent observation or serialization logic.
 */

#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "superconnect_core.h"

#if defined(_WIN32)
#define SC_CORE_ABI_OBSERVER_PLATFORM "windows"
#elif defined(__ANDROID__)
#define SC_CORE_ABI_OBSERVER_PLATFORM "android"
#elif defined(__OHOS__)
#define SC_CORE_ABI_OBSERVER_PLATFORM "harmonyos"
#elif defined(__APPLE__) && defined(__MACH__)
#define SC_CORE_ABI_OBSERVER_PLATFORM "macos"
#elif defined(__linux__)
#define SC_CORE_ABI_OBSERVER_PLATFORM "linux"
#else
#error "unsupported Core ABI observer platform"
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define SC_CORE_ABI_OBSERVER_ARCHITECTURE "arm64"
#elif defined(__x86_64__) || defined(_M_X64) || defined(_M_AMD64)
#define SC_CORE_ABI_OBSERVER_ARCHITECTURE "x86_64"
#else
#error "unsupported Core ABI observer architecture"
#endif

typedef uint32_t (*ScCoreAbiObserverAbiVersionFnV1)(void);
typedef uint64_t (*ScCoreAbiObserverAbiIdentityFnV1)(void);
typedef ScStatus (*ScCoreAbiObserverInputEncodeFnV1)(
    const ScInputEventV1*, uint8_t*, size_t, size_t*);
typedef ScStatus (*ScCoreAbiObserverInputDecodeFnV1)(
    const uint8_t*, size_t, ScInputEventV1*);
typedef ScStatus (*ScCoreAbiObserverSequencedEncodeFnV1)(
    const ScInputEventV1*, uint64_t, uint8_t*, size_t, size_t*);
typedef ScStatus (*ScCoreAbiObserverSequencedDecodeFnV1)(
    const uint8_t*, size_t, ScInputEventV1*, uint64_t*);

typedef struct ScCoreAbiObserverFunctionsV1 {
    ScCoreAbiObserverAbiVersionFnV1 abi_version;
    ScCoreAbiObserverAbiIdentityFnV1 abi_identity;
    ScCoreAbiObserverInputEncodeFnV1 input_encode;
    ScCoreAbiObserverInputDecodeFnV1 input_decode;
    ScCoreAbiObserverSequencedEncodeFnV1 sequenced_encode;
    ScCoreAbiObserverSequencedDecodeFnV1 sequenced_decode;
} ScCoreAbiObserverFunctionsV1;

enum {
    SC_CORE_ABI_OBSERVER_OK_V1 = 0,
    SC_CORE_ABI_OBSERVER_INVALID_ARGUMENT_V1 = 1,
    SC_CORE_ABI_OBSERVER_UNSUPPORTED_DATA_MODEL_V1 = 2,
    SC_CORE_ABI_OBSERVER_IO_ERROR_V1 = 3,
};

typedef union ScCoreAbiObserverAlignedRecordV1 {
    max_align_t alignment;
    uint8_t bytes[SC_INPUT_SEQUENCED_RECORD_V1_SIZE];
} ScCoreAbiObserverAlignedRecordV1;

static inline ScInputEventV1 sc_core_abi_observer_input_event_v1(void) {
    ScInputEventV1 event;
    memset(&event, 0, sizeof(event));
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    event.type = 2;
    event.tool = 2;
    event.buttons = 3;
    event.flags = 5;
    event.timestamp_ms = UINT64_C(1234567890123);
    event.x = 0.5f;
    event.y = 0.25f;
    event.pressure = 0.75f;
    event.tilt_x = 10.0f;
    event.tilt_y = -20.0f;
    event.scroll_x = 3.5f;
    event.scroll_y = -7.25f;
    event.key_code = UINT16_C(0x1234);
    event.pointer_id = UINT16_C(0x5678);
    return event;
}

static inline ScInputEventV1 sc_core_abi_observer_sentinel_event_v1(void) {
    ScInputEventV1 event;
    memset(&event, 0xa5, sizeof(event));
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    return event;
}

static inline uint32_t sc_core_abi_observer_float_bits_v1(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline void sc_core_abi_observer_write_hex_v1(
    FILE* output,
    const uint8_t* bytes,
    size_t length
) {
    size_t index;
    for (index = 0; index < length; ++index) {
        (void)fprintf(output, "%02x", (unsigned)bytes[index]);
    }
}

static inline void sc_core_abi_observer_write_event_v1(
    FILE* output,
    const ScInputEventV1* event
) {
    (void)fprintf(
        output,
        "{\"structSize\":%" PRIu32 ",\"apiVersion\":%" PRIu32
        ",\"type\":%u,\"tool\":%u,\"buttons\":%u,\"flags\":%u"
        ",\"reserved\":%" PRIu32 ",\"timestampMs\":%" PRIu64
        ",\"xBits\":\"%08" PRIx32 "\",\"yBits\":\"%08" PRIx32
        "\",\"pressureBits\":\"%08" PRIx32
        "\",\"tiltXBits\":\"%08" PRIx32
        "\",\"tiltYBits\":\"%08" PRIx32
        "\",\"scrollXBits\":\"%08" PRIx32
        "\",\"scrollYBits\":\"%08" PRIx32
        "\",\"keyCode\":%u,\"pointerId\":%u}",
        event->struct_size,
        event->api_version,
        (unsigned)event->type,
        (unsigned)event->tool,
        (unsigned)event->buttons,
        (unsigned)event->flags,
        event->reserved,
        event->timestamp_ms,
        sc_core_abi_observer_float_bits_v1(event->x),
        sc_core_abi_observer_float_bits_v1(event->y),
        sc_core_abi_observer_float_bits_v1(event->pressure),
        sc_core_abi_observer_float_bits_v1(event->tilt_x),
        sc_core_abi_observer_float_bits_v1(event->tilt_y),
        sc_core_abi_observer_float_bits_v1(event->scroll_x),
        sc_core_abi_observer_float_bits_v1(event->scroll_y),
        (unsigned)event->key_code,
        (unsigned)event->pointer_id
    );
}

static inline int sc_core_abi_observer_functions_valid_v1(
    const ScCoreAbiObserverFunctionsV1* functions
) {
    return functions != NULL
        && functions->abi_version != NULL
        && functions->abi_identity != NULL
        && functions->input_encode != NULL
        && functions->input_decode != NULL
        && functions->sequenced_encode != NULL
        && functions->sequenced_decode != NULL;
}

static inline int sc_core_abi_observer_write_json_v1(
    FILE* output,
    const ScCoreAbiObserverFunctionsV1* functions
) {
    const uint64_t sequence_value = UINT64_C(0x0001020304050607);
    const size_t needed_sentinel = (size_t)UINT64_C(0x5a5a5a5a5a5a5a5a);
    ScInputEventV1 event;
    ScInputEventV1 input_decoded;
    ScInputEventV1 input_wrong_decoded;
    ScInputEventV1 sequenced_decoded;
    ScInputEventV1 sequenced_wrong_decoded;
    ScInputEventV1 zero_decoded;
    uint8_t input_buffer[SC_INPUT_RECORD_V1_SIZE + 2];
    uint8_t input_short_buffer[SC_INPUT_RECORD_V1_SIZE + 2];
    uint8_t sequenced_buffer[SC_INPUT_SEQUENCED_RECORD_V1_SIZE + 2];
    uint8_t sequenced_short_buffer[SC_INPUT_SEQUENCED_RECORD_V1_SIZE + 2];
    uint8_t zero_encode_buffer[SC_INPUT_SEQUENCED_RECORD_V1_SIZE + 2];
    uint8_t zero_decode_bytes[SC_INPUT_SEQUENCED_RECORD_V1_SIZE];
    ScCoreAbiObserverAlignedRecordV1 input_alias_buffer;
    ScCoreAbiObserverAlignedRecordV1 sequenced_alias_buffer;
    size_t size_query_needed = 0;
    size_t input_needed = 0;
    size_t input_short_needed = needed_sentinel;
    size_t sequenced_needed = 0;
    size_t sequenced_short_needed = needed_sentinel;
    size_t zero_encode_needed = needed_sentinel;
    uint64_t decoded_sequence = 0;
    uint64_t wrong_decoded_sequence = UINT64_C(0x5a5a5a5a5a5a5a5a);
    uint64_t zero_decode_sequence = UINT64_C(0x5a5a5a5a5a5a5a5a);
    ScStatus size_query_status;
    ScStatus input_encode_status;
    ScStatus input_short_status;
    ScStatus input_wrong_decode_status;
    ScStatus input_alias_status;
    ScStatus input_decode_status;
    ScStatus sequenced_encode_status;
    ScStatus sequenced_short_status;
    ScStatus sequenced_wrong_decode_status;
    ScStatus sequenced_alias_status;
    ScStatus sequenced_decode_status;
    ScStatus zero_encode_status;
    ScStatus zero_decode_status;

    if (output == NULL || !sc_core_abi_observer_functions_valid_v1(functions)) {
        return SC_CORE_ABI_OBSERVER_INVALID_ARGUMENT_V1;
    }
    if (sizeof(size_t) != sizeof(uint64_t) || sizeof(ScInputEventV1) != 56) {
        return SC_CORE_ABI_OBSERVER_UNSUPPORTED_DATA_MODEL_V1;
    }

    event = sc_core_abi_observer_input_event_v1();
    input_decoded = sc_core_abi_observer_sentinel_event_v1();
    input_wrong_decoded = sc_core_abi_observer_sentinel_event_v1();
    sequenced_decoded = sc_core_abi_observer_sentinel_event_v1();
    sequenced_wrong_decoded = sc_core_abi_observer_sentinel_event_v1();
    zero_decoded = sc_core_abi_observer_sentinel_event_v1();
    memset(input_buffer, 0xa5, sizeof(input_buffer));
    memset(input_short_buffer, 0xa5, sizeof(input_short_buffer));
    memset(sequenced_buffer, 0xa5, sizeof(sequenced_buffer));
    memset(sequenced_short_buffer, 0xa5, sizeof(sequenced_short_buffer));
    memset(zero_encode_buffer, 0xa5, sizeof(zero_encode_buffer));
    memset(&input_alias_buffer, 0xa5, sizeof(input_alias_buffer));
    memset(&sequenced_alias_buffer, 0xa5, sizeof(sequenced_alias_buffer));

    size_query_status = functions->input_encode(&event, NULL, 0, &size_query_needed);
    input_encode_status = functions->input_encode(
        &event, &input_buffer[1], SC_INPUT_RECORD_V1_SIZE, &input_needed);
    input_short_status = functions->input_encode(
        &event, &input_short_buffer[1], SC_INPUT_RECORD_V1_SIZE - 1,
        &input_short_needed);
    input_wrong_decode_status = functions->input_decode(
        &input_buffer[1], SC_INPUT_RECORD_V1_SIZE - 1, &input_wrong_decoded);
    input_alias_status = functions->input_encode(
        &event, input_alias_buffer.bytes, SC_INPUT_RECORD_V1_SIZE,
        (size_t*)input_alias_buffer.bytes);
    input_decode_status = functions->input_decode(
        &input_buffer[1], SC_INPUT_RECORD_V1_SIZE, &input_decoded);
    sequenced_encode_status = functions->sequenced_encode(
        &event, sequence_value, &sequenced_buffer[1],
        SC_INPUT_SEQUENCED_RECORD_V1_SIZE, &sequenced_needed);
    sequenced_short_status = functions->sequenced_encode(
        &event, sequence_value, &sequenced_short_buffer[1],
        SC_INPUT_SEQUENCED_RECORD_V1_SIZE - 1, &sequenced_short_needed);
    sequenced_wrong_decode_status = functions->sequenced_decode(
        &sequenced_buffer[1], SC_INPUT_SEQUENCED_RECORD_V1_SIZE - 1,
        &sequenced_wrong_decoded, &wrong_decoded_sequence);
    sequenced_alias_status = functions->sequenced_encode(
        &event, sequence_value, sequenced_alias_buffer.bytes,
        SC_INPUT_SEQUENCED_RECORD_V1_SIZE, (size_t*)sequenced_alias_buffer.bytes);
    sequenced_decode_status = functions->sequenced_decode(
        &sequenced_buffer[1], SC_INPUT_SEQUENCED_RECORD_V1_SIZE,
        &sequenced_decoded, &decoded_sequence);
    zero_encode_status = functions->sequenced_encode(
        &event, 0, &zero_encode_buffer[1], SC_INPUT_SEQUENCED_RECORD_V1_SIZE,
        &zero_encode_needed);
    memcpy(zero_decode_bytes, &sequenced_buffer[1], sizeof(zero_decode_bytes));
    memset(&zero_decode_bytes[SC_INPUT_RECORD_V1_SIZE], 0, sizeof(uint64_t));
    zero_decode_status = functions->sequenced_decode(
        zero_decode_bytes, SC_INPUT_SEQUENCED_RECORD_V1_SIZE,
        &zero_decoded, &zero_decode_sequence);

    (void)fprintf(
        output,
        "{\"contract\":{\"name\":\"superconnect.core-abi-behavior-probe\","
        "\"version\":1},\"platform\":\"%s\",\"architecture\":\"%s\","
        "\"observations\":{\"abiVersion\":%" PRIu32
        ",\"abiIdentity\":\"%016" PRIx64 "\",",
        SC_CORE_ABI_OBSERVER_PLATFORM,
        SC_CORE_ABI_OBSERVER_ARCHITECTURE,
        functions->abi_version(),
        functions->abi_identity());
    (void)fprintf(output,
        "\"inputSizeQuery\":{\"status\":%d,\"needed\":%zu},",
        size_query_status, size_query_needed);
    (void)fprintf(output,
        "\"inputEncode\":{\"status\":%d,\"needed\":%zu,\"bytesHex\":\"",
        input_encode_status, input_needed);
    sc_core_abi_observer_write_hex_v1(
        output, &input_buffer[1], SC_INPUT_RECORD_V1_SIZE);
    (void)fprintf(output,
        "\",\"guardPrefixHex\":\"%02x\",\"guardSuffixHex\":\"%02x\"},",
        (unsigned)input_buffer[0],
        (unsigned)input_buffer[SC_INPUT_RECORD_V1_SIZE + 1]);
    (void)fprintf(output,
        "\"inputShortEncode\":{\"status\":%d,\"needed\":%zu,\"bufferHex\":\"",
        input_short_status, input_short_needed);
    sc_core_abi_observer_write_hex_v1(output, input_short_buffer,
        sizeof(input_short_buffer));
    (void)fprintf(output,
        "\"},\"inputWrongLengthDecode\":{\"status\":%d,\"eventBytesHex\":\"",
        input_wrong_decode_status);
    sc_core_abi_observer_write_hex_v1(output,
        (const uint8_t*)&input_wrong_decoded, sizeof(input_wrong_decoded));
    (void)fprintf(output,
        "\"},\"inputOutputNeededAlias\":{\"status\":%d,\"bufferHex\":\"",
        input_alias_status);
    sc_core_abi_observer_write_hex_v1(
        output, input_alias_buffer.bytes, SC_INPUT_RECORD_V1_SIZE);
    (void)fprintf(output, "\"},\"inputDecode\":{\"status\":%d,\"event\":",
        input_decode_status);
    sc_core_abi_observer_write_event_v1(output, &input_decoded);
    (void)fprintf(output,
        "},\"sequencedEncode\":{\"status\":%d,\"needed\":%zu,\"bytesHex\":\"",
        sequenced_encode_status, sequenced_needed);
    sc_core_abi_observer_write_hex_v1(
        output, &sequenced_buffer[1], SC_INPUT_SEQUENCED_RECORD_V1_SIZE);
    (void)fprintf(output,
        "\",\"guardPrefixHex\":\"%02x\",\"guardSuffixHex\":\"%02x\"},",
        (unsigned)sequenced_buffer[0],
        (unsigned)sequenced_buffer[SC_INPUT_SEQUENCED_RECORD_V1_SIZE + 1]);
    (void)fprintf(output,
        "\"sequencedShortEncode\":{\"status\":%d,\"needed\":%zu,"
        "\"bufferHex\":\"", sequenced_short_status, sequenced_short_needed);
    sc_core_abi_observer_write_hex_v1(output, sequenced_short_buffer,
        sizeof(sequenced_short_buffer));
    (void)fprintf(output,
        "\"},\"sequencedWrongLengthDecode\":{\"status\":%d,"
        "\"eventBytesHex\":\"", sequenced_wrong_decode_status);
    sc_core_abi_observer_write_hex_v1(output,
        (const uint8_t*)&sequenced_wrong_decoded,
        sizeof(sequenced_wrong_decoded));
    (void)fprintf(output,
        "\",\"sequenceHex\":\"%016" PRIx64
        "\"},\"sequencedOutputNeededAlias\":{\"status\":%d,"
        "\"bufferHex\":\"", wrong_decoded_sequence, sequenced_alias_status);
    sc_core_abi_observer_write_hex_v1(
        output, sequenced_alias_buffer.bytes, SC_INPUT_SEQUENCED_RECORD_V1_SIZE);
    (void)fprintf(output,
        "\"},\"sequencedDecode\":{\"status\":%d,"
        "\"sequenceHex\":\"%016" PRIx64 "\",\"event\":",
        sequenced_decode_status, decoded_sequence);
    sc_core_abi_observer_write_event_v1(output, &sequenced_decoded);
    (void)fprintf(output,
        "},\"zeroSequenceEncode\":{\"status\":%d,"
        "\"neededHex\":\"%016" PRIx64 "\",\"bufferHex\":\"",
        zero_encode_status, (uint64_t)zero_encode_needed);
    sc_core_abi_observer_write_hex_v1(output, zero_encode_buffer,
        sizeof(zero_encode_buffer));
    (void)fprintf(output,
        "\"},\"zeroSequenceDecode\":{\"status\":%d,\"eventBytesHex\":\"",
        zero_decode_status);
    sc_core_abi_observer_write_hex_v1(output,
        (const uint8_t*)&zero_decoded, sizeof(zero_decoded));
    (void)fprintf(output,
        "\",\"sequenceHex\":\"%016" PRIx64 "\"}}}\n",
        zero_decode_sequence);

    return ferror(output)
        ? SC_CORE_ABI_OBSERVER_IO_ERROR_V1
        : SC_CORE_ABI_OBSERVER_OK_V1;
}
