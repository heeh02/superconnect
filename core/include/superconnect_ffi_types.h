#pragma once

#include <stdint.h>

enum {
    SC_API_VERSION_V1 = 1,
};

typedef int32_t ScStatus;
enum {
    SC_OK = 0,
    SC_INVALID_ARGUMENT = 1,
    SC_FRAME_TOO_LARGE = 2,
    SC_CALLBACK_ABORTED = 3,
    SC_INTERNAL_ERROR = 4,
    SC_BUFFER_TOO_SMALL = 5,
    SC_NO_FRAME = 6,
    SC_STALE_VIEW = 7,
    SC_UNSUPPORTED_VERSION = 8,
    SC_DECODER_POISONED = 9,
};
