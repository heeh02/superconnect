#include "SuperconnectCoreFFI.h"
#include "../../../core/include/superconnect_core_abi_observer_v1.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int sc_mac_core_abi_observer_write_file_v1(const char* output_path) {
    static const char suffix[] = ".tmp.XXXXXX";
    if (output_path == NULL || output_path[0] == '\0') {
        return 1;
    }

    const size_t output_length = strlen(output_path);
    if (output_length > SIZE_MAX - sizeof(suffix)) {
        return 1;
    }
    const size_t temporary_length = output_length + sizeof(suffix);
    char* temporary_path = malloc(temporary_length);
    if (temporary_path == NULL) {
        return 1;
    }
    if (snprintf(temporary_path, temporary_length, "%s%s", output_path, suffix) < 0) {
        free(temporary_path);
        return 1;
    }

    int descriptor = mkstemp(temporary_path);
    if (descriptor < 0) {
        free(temporary_path);
        return 1;
    }
    if (fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        close(descriptor);
        unlink(temporary_path);
        free(temporary_path);
        return 1;
    }
    FILE* output = fdopen(descriptor, "w");
    if (output == NULL) {
        close(descriptor);
        unlink(temporary_path);
        free(temporary_path);
        return 1;
    }

    const ScCoreAbiObserverFunctionsV1 functions = {
        .abi_version = sc_core_abi_version_v1,
        .abi_identity = sc_core_abi_identity_v1,
        .input_encode = sc_input_encode_v1,
        .input_decode = sc_input_decode_v1,
        .sequenced_encode = sc_input_sequenced_encode_v1,
        .sequenced_decode = sc_input_sequenced_decode_v1,
    };
    int result = sc_core_abi_observer_write_json_v1(output, &functions);
    if (result == SC_CORE_ABI_OBSERVER_OK_V1 && fflush(output) != 0) {
        result = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    if (result == SC_CORE_ABI_OBSERVER_OK_V1 && fsync(descriptor) != 0) {
        result = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    if (fclose(output) != 0) {
        result = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    if (result == SC_CORE_ABI_OBSERVER_OK_V1 && rename(temporary_path, output_path) != 0) {
        result = SC_CORE_ABI_OBSERVER_IO_ERROR_V1;
    }
    if (result != SC_CORE_ABI_OBSERVER_OK_V1) {
        unlink(temporary_path);
    }
    free(temporary_path);
    return result;
}
