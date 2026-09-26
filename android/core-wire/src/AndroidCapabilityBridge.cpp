#include "AndroidCapabilityBridge.h"

#include <new>

namespace superconnect::android_capability {

ScStatus New(std::uint64_t generation, std::uint64_t authorized_capabilities,
             std::uint8_t projection, Handle** output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    *output = nullptr;
    ScCapabilityConfigV1 config{};
    config.struct_size = sizeof(config);
    config.api_version = SC_API_VERSION_V1;
    config.generation = generation;
    config.authorized_capabilities = authorized_capabilities;
    config.side = SC_CAPABILITY_SIDE_SELECTOR;
    config.local_role = SC_CAPABILITY_ROLE_RECEIVER;
    config.desired_peer_role = SC_CAPABILITY_ROLE_HOST;
    config.projection = projection;
    config.transport = SC_CAPABILITY_TRANSPORT_TCP;
    auto* wrapper = new (std::nothrow) Handle{};
    if (wrapper == nullptr) return SC_INTERNAL_ERROR;
    const auto status = sc_capability_negotiation_new_v1(&config, &wrapper->negotiation);
    if (status != SC_OK) {
        delete wrapper;
        return status;
    }
    *output = wrapper;
    return SC_OK;
}

ScStatus Apply(Handle* handle, const Event& input, Effects* output) {
    if (handle == nullptr || handle->negotiation == nullptr || output == nullptr) {
        return SC_INVALID_ARGUMENT;
    }
    ScCapabilityEventV1 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    event.event_type = input.type;
    event.generation = input.generation;
    event.capabilities = input.capabilities;
    event.negotiation_version = input.version;
    event.has_negotiation_version = input.has_version ? 1 : 0;
    event.offerer_role = input.offerer_role;
    event.selector_role = input.selector_role;
    event.projection = input.projection;
    event.transport = input.transport;
    output->values = {};
    output->written = 0;
    std::size_t written = 0;
    const auto status = sc_capability_negotiation_apply_v1(
        handle->negotiation, &event, output->values.data(), output->values.size(), &written);
    if (status == SC_OK) output->written = written;
    return status;
}

ScStatus Free(Handle* handle) {
    if (handle == nullptr) return SC_INVALID_ARGUMENT;
    const auto status = sc_capability_negotiation_free_v1(handle->negotiation);
    handle->negotiation = nullptr;
    delete handle;
    return status;
}

}  // namespace superconnect::android_capability
