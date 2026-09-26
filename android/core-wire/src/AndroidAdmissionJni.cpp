#include "AndroidAdmissionBridge.h"
#include "AndroidWireBridge.h"

#include <jni.h>

#include <array>
#include <cstdint>

namespace admission = superconnect::android_admission;

namespace {

void Throw(JNIEnv* env, const char* type, const char* message) {
    const auto klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    if (status == SC_INVALID_ARGUMENT) {
        Throw(env, "java/lang/IllegalArgumentException", "Rust admission ABI rejected input");
    } else {
        Throw(env, "java/lang/IllegalStateException", "Rust admission ABI operation failed");
    }
}

admission::Handle* Handle(jlong value) {
    return reinterpret_cast<admission::Handle*>(static_cast<std::uintptr_t>(value));
}

jlong HandleValue(admission::Handle* value) {
    return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(value));
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_AdmissionNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_android_wire_active_marker_v1());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_receiver_AdmissionNative_nativeNew(
    JNIEnv* env, jobject, jint max_pending) {
    if (max_pending <= 0) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid admission capacity");
        return 0;
    }
    admission::Handle* output = nullptr;
    const auto status = admission::New(static_cast<std::uint32_t>(max_pending), &output);
    if (status != SC_OK || output == nullptr) {
        ThrowStatus(env, status);
        return 0;
    }
    return HandleValue(output);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_AdmissionNative_nativeApply(
    JNIEnv* env, jobject, jlong handle_value, jint kind, jlong owner, jlong token) {
    auto* handle = Handle(handle_value);
    if (handle == nullptr || kind <= 0 || owner <= 0 || token < 0) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid admission event");
        return nullptr;
    }
    constexpr std::size_t kFields = 5;
    constexpr std::size_t kCapacity = 2;
    std::array<jlong, 1 + kCapacity * kFields> values{};
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output == nullptr) return nullptr;
    admission::Effects effects{};
    const auto status = admission::Apply(handle, static_cast<std::uint32_t>(kind),
                                         static_cast<std::uint64_t>(owner),
                                         static_cast<std::uint64_t>(token), &effects);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    values[0] = static_cast<jlong>(effects.written);
    for (std::size_t index = 0; index < effects.written; ++index) {
        const auto& effect = effects.values[index];
        const auto offset = 1 + index * kFields;
        values[offset] = static_cast<jlong>(effect.kind);
        values[offset + 1] = static_cast<jlong>(effect.timer_kind);
        values[offset + 2] = static_cast<jlong>(effect.owner);
        values[offset + 3] = static_cast<jlong>(effect.token);
        values[offset + 4] = static_cast<jlong>(effect.timeout_ms);
    }
    env->SetLongArrayRegion(output, 0, static_cast<jsize>(values.size()), values.data());
    return output;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_AdmissionNative_nativeSnapshot(
    JNIEnv* env, jobject, jlong handle_value) {
    auto* handle = Handle(handle_value);
    if (handle == nullptr) {
        Throw(env, "java/lang/IllegalStateException", "admission handle is closed");
        return nullptr;
    }
    ScAdmissionSnapshotV1 snapshot{};
    const auto status = admission::Snapshot(handle, &snapshot);
    if (status != SC_OK) {
        ThrowStatus(env, status);
        return nullptr;
    }
    const std::array<jlong, 3> values{
        static_cast<jlong>(snapshot.active_owner),
        static_cast<jlong>(snapshot.pending_count),
        static_cast<jlong>(snapshot.max_pending),
    };
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output != nullptr) {
        env->SetLongArrayRegion(output, 0, static_cast<jsize>(values.size()), values.data());
    }
    return output;
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_receiver_AdmissionNative_nativeFree(
    JNIEnv* env, jobject, jlong handle_value) {
    const auto status = admission::Free(Handle(handle_value));
    if (status != SC_OK) ThrowStatus(env, status);
}
