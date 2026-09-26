#include "AndroidAdmissionBridge.h"

namespace superconnect::android_admission {

ScStatus New(std::uint32_t max_pending, Handle** output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScAdmissionConfigV1 config{};
    config.struct_size = sizeof(config);
    config.api_version = SC_API_VERSION_V1;
    config.max_pending = max_pending;
    return sc_admission_new_v1(&config, output);
}

ScStatus Apply(Handle* handle, std::uint32_t kind, std::uint64_t owner,
               std::uint64_t token, Effects* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    output->values = {};
    output->written = 0;
    ScAdmissionEventV1 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    event.kind = kind;
    event.owner = owner;
    event.token = token;
    std::size_t needed = 0;
    return sc_admission_apply_v1(handle, &event, output->values.data(), output->values.size(),
                                 sizeof(ScAdmissionEffectV1), &output->written, &needed);
}

ScStatus Snapshot(const Handle* handle, ScAdmissionSnapshotV1* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    *output = {};
    output->struct_size = sizeof(*output);
    output->api_version = SC_API_VERSION_V1;
    return sc_admission_snapshot_v1(handle, output);
}

ScStatus Free(Handle* handle) { return sc_admission_free_v1(handle); }

}  // namespace superconnect::android_admission
