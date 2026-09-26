#include "superconnect_core.h"
#include "superconnect_media_recovery.h"

#include <jni.h>

#include <array>
#include <cstdint>
#include <vector>

namespace {

template <std::size_t Size>
jlongArray LongArray(JNIEnv* env, const std::array<jlong, Size>& values) {
    const auto result = env->NewLongArray(static_cast<jsize>(Size));
    if (result != nullptr) {
        env->SetLongArrayRegion(result, 0, static_cast<jsize>(Size), values.data());
    }
    return result;
}

jbyteArray ByteArray(JNIEnv* env, const std::vector<std::uint8_t>& values) {
    const auto result = env->NewByteArray(static_cast<jsize>(values.size()));
    if (result != nullptr && !values.empty()) {
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(values.size()),
                                reinterpret_cast<const jbyte*>(values.data()));
    }
    return result;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_core_abi_version_v1());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeEncodeWire(
    JNIEnv* env, jobject, jlongArray record) {
    if (record == nullptr || env->GetArrayLength(record) != 11) return nullptr;
    std::array<jlong, 11> values{};
    env->GetLongArrayRegion(record, 0, static_cast<jsize>(values.size()), values.data());
    if (env->ExceptionCheck() || values[0] <= 0 || values[0] > UINT32_MAX ||
        values[1] <= 0 || values[10] < 0 || values[10] > 1) return nullptr;
    ScReceiverProgressWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    wire.session_generation = static_cast<std::uint32_t>(values[0]);
    wire.awaiting_keyframe = static_cast<std::uint32_t>(values[10]);
    wire.decoder_generation = static_cast<std::uint64_t>(values[1]);
    for (std::size_t index = 0; index < 4; ++index) {
        if (values[index + 2] < 0 || values[index + 6] < 0 ||
            values[index + 6] > UINT32_MAX) return nullptr;
        wire.stage_counts[index] = static_cast<std::uint64_t>(values[index + 2]);
        wire.latest_source_frame_ids[index] = static_cast<std::uint32_t>(values[index + 6]);
    }
    std::size_t needed = 0;
    if (sc_receiver_progress_wire_encode_v1(&wire, nullptr, 0, &needed) !=
            SC_BUFFER_TOO_SMALL || needed == 0 || needed > 1024) return nullptr;
    std::vector<std::uint8_t> output(needed);
    std::size_t written = 0;
    if (sc_receiver_progress_wire_encode_v1(
            &wire, output.data(), output.size(), &written) != SC_OK ||
        written != output.size()) return nullptr;
    return ByteArray(env, output);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeDecodeWire(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const auto length = env->GetArrayLength(source);
    if (length < 0 || length > 1024) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    if (length != 0) {
        env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
        if (env->ExceptionCheck()) return nullptr;
    }
    ScReceiverProgressWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    if (sc_receiver_progress_wire_decode_v1(
            bytes.data(), bytes.size(), &wire) != SC_OK) return nullptr;
    std::array<jlong, 11> values{};
    values[0] = wire.session_generation;
    values[1] = static_cast<jlong>(wire.decoder_generation);
    for (std::size_t index = 0; index < 4; ++index) {
        values[index + 2] = static_cast<jlong>(wire.stage_counts[index]);
        values[index + 6] = wire.latest_source_frame_ids[index];
    }
    values[10] = wire.awaiting_keyframe;
    return LongArray(env, values);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeEncodeKeyframeRequest(
    JNIEnv* env, jobject, jint reason) {
    if (reason < SC_KEYFRAME_REQUEST_REASON_UNSPECIFIED ||
        reason > SC_KEYFRAME_REQUEST_REASON_CONFIG_REARM) return nullptr;
    ScKeyframeRequestWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    wire.reason = static_cast<std::uint32_t>(reason);
    std::size_t needed = 0;
    if (sc_keyframe_request_wire_encode_v1(&wire, nullptr, 0, &needed) !=
            SC_BUFFER_TOO_SMALL || needed == 0 || needed > 256) return nullptr;
    std::vector<std::uint8_t> output(needed);
    const std::size_t expected = needed;
    if (sc_keyframe_request_wire_encode_v1(
            &wire, output.data(), output.size(), &needed) != SC_OK ||
        needed != expected) return nullptr;
    return ByteArray(env, output);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeDecodeKeyframeRequest(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return -1;
    const auto length = env->GetArrayLength(source);
    if (length < 0 || length > 256) return -1;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    if (length != 0) {
        env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
        if (env->ExceptionCheck()) return -1;
    }
    ScKeyframeRequestWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    return sc_keyframe_request_wire_decode_v1(bytes.data(), bytes.size(), &wire) == SC_OK
        ? static_cast<jint>(wire.reason) : -1;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeEncodeVideoConfig(
    JNIEnv* env, jobject, jintArray record) {
    if (record == nullptr || env->GetArrayLength(record) != 6) return nullptr;
    std::array<jint, 6> values{};
    env->GetIntArrayRegion(record, 0, static_cast<jsize>(values.size()), values.data());
    if (env->ExceptionCheck()) return nullptr;
    ScVideoConfigWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    wire.codec = static_cast<std::uint32_t>(values[0]);
    wire.hdr = static_cast<std::uint32_t>(values[1]);
    wire.width = static_cast<std::uint32_t>(values[2]);
    wire.height = static_cast<std::uint32_t>(values[3]);
    wire.refresh_rate = static_cast<std::uint32_t>(values[4]);
    wire.low_latency = static_cast<std::uint8_t>(values[5]);
    std::size_t needed = 0;
    if (sc_video_config_wire_encode_v1(&wire, nullptr, 0, &needed) != SC_BUFFER_TOO_SMALL ||
        needed == 0 || needed > 256) return nullptr;
    std::vector<std::uint8_t> output(needed);
    const auto capacity = needed;
    if (sc_video_config_wire_encode_v1(&wire, output.data(), output.size(), &needed) != SC_OK ||
        needed != capacity) return nullptr;
    return ByteArray(env, output);
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_superconnect_receiver_ReceiverProgressNative_nativeDecodeVideoConfig(
    JNIEnv* env, jobject, jbyteArray source) {
    if (source == nullptr) return nullptr;
    const auto length = env->GetArrayLength(source);
    if (length < 0 || length > 256) return nullptr;
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
    if (length != 0) {
        env->GetByteArrayRegion(source, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
        if (env->ExceptionCheck()) return nullptr;
    }
    ScVideoConfigWireV1 wire{};
    wire.struct_size = sizeof(wire);
    wire.api_version = SC_API_VERSION_V1;
    if (sc_video_config_wire_decode_v1(bytes.data(), bytes.size(), &wire) != SC_OK) return nullptr;
    const std::array<jint, 6> values{static_cast<jint>(wire.codec), static_cast<jint>(wire.hdr),
        static_cast<jint>(wire.width), static_cast<jint>(wire.height),
        static_cast<jint>(wire.refresh_rate), static_cast<jint>(wire.low_latency)};
    const auto result = env->NewIntArray(static_cast<jsize>(values.size()));
    if (result != nullptr) {
        env->SetIntArrayRegion(result, 0, static_cast<jsize>(values.size()), values.data());
    }
    return result;
}
