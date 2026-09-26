#pragma once
#include <stddef.h>
#include "superconnect_ffi_types.h"
#ifdef __cplusplus
extern "C" {
#endif

enum {
    SC_INPUT_RESET_REASON_MAX_BYTES_V1 = 64,
};

typedef struct ScInputResetWireV1 {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t reason_size;
    uint32_t reserved;
    uint8_t reason[SC_INPUT_RESET_REASON_MAX_BYTES_V1];
    uint64_t reserved_u64;
} ScInputResetWireV1;

ScStatus sc_input_reset_wire_encode_v1(
    const ScInputResetWireV1* value,
    uint8_t* output,
    size_t output_capacity,
    size_t* needed
);

ScStatus sc_input_reset_wire_decode_v1(
    const uint8_t* input,
    size_t input_length,
    ScInputResetWireV1* output
);

#ifdef __cplusplus
}
#endif
