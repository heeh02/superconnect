#pragma once

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__) || defined(__clang__)
#define SC_ANDROID_CORE_ABI_EXPORT __attribute__((visibility("default")))
#else
#define SC_ANDROID_CORE_ABI_EXPORT
#endif

/* Writes the shared canonical observer JSON to a duplicate of output_fd. */
SC_ANDROID_CORE_ABI_EXPORT
int sc_android_core_abi_observe_fd_v1(int output_fd);

#undef SC_ANDROID_CORE_ABI_EXPORT

#if defined(__cplusplus)
}
#endif
