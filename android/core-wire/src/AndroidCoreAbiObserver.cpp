#include "AndroidCoreAbiObserver.h"

#include "superconnect_core_abi_observer_v1.h"

#include <stdio.h>
#include <unistd.h>

extern "C" int sc_android_core_abi_observe_fd_v1(int output_fd) {
    if (output_fd < 0) {
        return SC_CORE_ABI_OBSERVER_INVALID_ARGUMENT_V1;
    }
    const int duplicate = dup(output_fd);
    if (duplicate < 0) {
        return SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    FILE* output = fdopen(duplicate, "w");
    if (output == nullptr) {
        (void)close(duplicate);
        return SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }

    const ScCoreAbiObserverFunctionsV1 functions = {
        sc_core_abi_version_v1,
        sc_core_abi_identity_v1,
        sc_input_encode_v1,
        sc_input_decode_v1,
        sc_input_sequenced_encode_v1,
        sc_input_sequenced_decode_v1,
    };
    int status = sc_core_abi_observer_write_json_v1(output, &functions);
    if (status == SC_CORE_ABI_OBSERVER_OK_V1 && fflush(output) != 0) {
        status = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    if (fclose(output) != 0) {
        status = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    return status;
}
