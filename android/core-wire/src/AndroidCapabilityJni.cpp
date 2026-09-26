#include "AndroidCapabilityBridge.h"
#include "AndroidWireBridge.h"

#include <jni.h>

#include <array>
#include <cstdint>
#include <vector>

namespace capability = superconnect::android_capability;

namespace {

void Throw(JNIEnv* env, const char* type, const char* message) {
    const auto klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    Throw(env, status == SC_INVALID_ARGUMENT ? "java/lang/IllegalArgumentException"
                                             : "java/lang/IllegalStateException",
          status == SC_INVALID_ARGUMENT ? "Rust capability ABI rejected input"
                                        : "Rust capability ABI operation failed");
}

capability::Handle* Handle(jlong value) {
    return reinterpret_cast<capability::Handle*>(static_cast<std::uintptr_t>(value));
}

jlong HandleValue(capability::Handle* value) {
    return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(value));
}

bool ReadWireRecord(JNIEnv* env, jlongArray source, ScCapabilityEventV1* value) {
    if (source == nullptr || value == nullptr || env->GetArrayLength(source) != 8) return false;
    std::array<jlong, 8> fields{};
    env->GetLongArrayRegion(source, 0, fields.size(), fields.data());
    if (env->ExceptionCheck()) return false;
    value->struct_size = sizeof(*value); value->api_version = SC_API_VERSION_V1;
    value->event_type = static_cast<std::uint8_t>(fields[0]);
    value->generation = static_cast<std::uint64_t>(fields[1]);
    value->capabilities = static_cast<std::uint64_t>(fields[2]);
    value->negotiation_version = static_cast<std::uint16_t>(fields[3]);
    value->has_negotiation_version = 1;
    value->offerer_role = static_cast<std::uint8_t>(fields[4]);
    value->selector_role = static_cast<std::uint8_t>(fields[5]);
    value->projection = static_cast<std::uint8_t>(fields[6]);
    value->transport = static_cast<std::uint8_t>(fields[7]);
    return fields[0] > 0 && fields[0] <= UINT8_MAX && fields[3] > 0 && fields[3] <= UINT16_MAX &&
        fields[4] > 0 && fields[4] <= UINT8_MAX && fields[5] > 0 && fields[5] <= UINT8_MAX &&
        fields[6] > 0 && fields[6] <= UINT8_MAX && fields[7] > 0 && fields[7] <= UINT8_MAX;
}

jlongArray WireRecord(JNIEnv* env, const ScCapabilityEventV1& value) {
    std::array<jlong, 8> fields{value.event_type, static_cast<jlong>(value.generation),
        static_cast<jlong>(value.capabilities), value.negotiation_version, value.offerer_role,
        value.selector_role, value.projection, value.transport};
    auto output = env->NewLongArray(fields.size());
    if (output != nullptr) env->SetLongArrayRegion(output, 0, fields.size(), fields.data());
    return output;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_android_wire_active_marker_v1());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeNew(
    JNIEnv* env, jobject, jlong generation, jlong authorized_capabilities, jint projection) {
    if (generation == 0 || authorized_capabilities == 0 || projection <= 0 || projection > UINT8_MAX) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid capability configuration");
        return 0;
    }
    capability::Handle* output = nullptr;
    const auto status = capability::New(
        static_cast<std::uint64_t>(generation),
        static_cast<std::uint64_t>(authorized_capabilities),
        static_cast<std::uint8_t>(projection), &output);
    if (status != SC_OK || output == nullptr) {
        ThrowStatus(env, status);
        return 0;
    }
    return HandleValue(output);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeApply(
    JNIEnv* env, jobject, jlong handle_value, jint type, jlong generation,
    jlong capabilities, jint version, jboolean has_version, jint offerer_role,
    jint selector_role, jint projection, jint transport) {
    if (Handle(handle_value) == nullptr || type <= 0 || type > UINT8_MAX || generation == 0 ||
        version < 0 || version > UINT16_MAX || offerer_role < 0 ||
        offerer_role > UINT8_MAX || selector_role < 0 || selector_role > UINT8_MAX ||
        projection < 0 || projection > UINT8_MAX || transport < 0 || transport > UINT8_MAX) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid capability event");
        return nullptr;
    }
    capability::Event event{};
    event.type = static_cast<std::uint8_t>(type);
    event.generation = static_cast<std::uint64_t>(generation);
    event.capabilities = static_cast<std::uint64_t>(capabilities);
    event.version = static_cast<std::uint16_t>(version);
    event.has_version = has_version == JNI_TRUE;
    event.offerer_role = static_cast<std::uint8_t>(offerer_role);
    event.selector_role = static_cast<std::uint8_t>(selector_role);
    event.projection = static_cast<std::uint8_t>(projection);
    event.transport = static_cast<std::uint8_t>(transport);
    constexpr std::size_t kFields = 12;
    std::array<jlong, 1 + SC_CAPABILITY_MAX_EFFECTS_V1 * kFields> values{};
    const auto result = env->NewLongArray(static_cast<jsize>(values.size()));
    if (result == nullptr) return nullptr;
    capability::Effects effects{};
    const auto status = capability::Apply(Handle(handle_value), event, &effects);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    values[0] = static_cast<jlong>(effects.written);
    for (std::size_t index = 0; index < effects.written; ++index) {
        const auto& effect = effects.values[index];
        const auto offset = 1 + index * kFields;
        values[offset] = effect.effect_type;
        values[offset + 1] = effect.reason;
        values[offset + 2] = static_cast<jlong>(effect.generation);
        values[offset + 3] = static_cast<jlong>(effect.capabilities);
        values[offset + 4] = effect.negotiation_version;
        values[offset + 5] = effect.offerer_role;
        values[offset + 6] = effect.selector_role;
        values[offset + 7] = effect.local_role;
        values[offset + 8] = effect.peer_role;
        values[offset + 9] = effect.projection;
        values[offset + 10] = effect.transport;
        values[offset + 11] = effect.negotiated;
    }
    env->SetLongArrayRegion(result, 0, static_cast<jsize>(values.size()), values.data());
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeFree(
    JNIEnv* env, jobject, jlong handle_value) {
    const auto status = capability::Free(Handle(handle_value));
    if (status != SC_OK) ThrowStatus(env, status);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeEncodeWire(
    JNIEnv* env, jobject, jlongArray source) {
    ScCapabilityEventV1 value{};
    if (!ReadWireRecord(env, source, &value)) return nullptr;
    std::size_t needed = 0;
    if (sc_capability_wire_encode_v1(&value, nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL ||
        needed == 0) return nullptr;
    std::vector<std::uint8_t> bytes(needed); const auto capacity = needed;
    if (sc_capability_wire_encode_v1(&value, bytes.data(), bytes.size(), &needed) != SC_OK ||
        needed != capacity) return nullptr;
    auto output = env->NewByteArray(bytes.size());
    if (output != nullptr) env->SetByteArrayRegion(
        output, 0, bytes.size(), reinterpret_cast<const jbyte*>(bytes.data()));
    return output;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_CapabilityNative_nativeDecodeWire(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const auto length = env->GetArrayLength(source);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    if (length != 0) env->GetByteArrayRegion(
        source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
    ScCapabilityEventV1 value{}; value.struct_size = sizeof(value); value.api_version = SC_API_VERSION_V1;
    if (env->ExceptionCheck() || sc_capability_wire_decode_v1(
        bytes.data(), bytes.size(), &value) != SC_OK) return nullptr;
    return WireRecord(env, value);
}
