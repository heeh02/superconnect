#include "AndroidWireBridge.h"

#include <jni.h>

#include <array>
#include <cstring>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

using superconnect::android_wire::DecodedFrame;
using superconnect::android_wire::FrameDecoder;
using superconnect::android_wire::InputFields;
using superconnect::android_wire::ScopedObjectWipe;
using superconnect::android_wire::ScopedVectorWipe;
using superconnect::android_wire::SecureWipe;
using superconnect::android_wire::VideoMetaDecode;
using superconnect::android_wire::VideoMetaFields;

namespace {

void Throw(JNIEnv* env, const char* type, const char* message) {
    const jclass klass = env->FindClass(type);
    if (klass != nullptr) env->ThrowNew(klass, message);
}

void ThrowStatus(JNIEnv* env, ScStatus status) {
    if (status == SC_INVALID_ARGUMENT || status == SC_FRAME_TOO_LARGE) {
        Throw(env, "java/lang/IllegalArgumentException", "Rust wire ABI rejected input");
    } else if (status == SC_DECODER_POISONED) {
        Throw(env, "java/lang/IllegalStateException", "Rust frame decoder is poisoned; reset required");
    } else {
        Throw(env, "java/lang/IllegalStateException", "Rust wire ABI operation failed");
    }
}

bool DirectRange(JNIEnv* env, jobject buffer, jint offset, jint length, const std::uint8_t** output) {
    if (buffer == nullptr || offset < 0 || length < 0) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid direct ByteBuffer range");
        return false;
    }
    const jlong capacity = env->GetDirectBufferCapacity(buffer);
    auto* base = static_cast<const std::uint8_t*>(env->GetDirectBufferAddress(buffer));
    if (capacity < 0 || (capacity != 0 && base == nullptr) ||
        !superconnect::android_wire::IsValidBufferRange(
            static_cast<std::size_t>(capacity), static_cast<std::size_t>(offset),
            static_cast<std::size_t>(length))) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid direct ByteBuffer range");
        return false;
    }
    *output = length == 0 ? nullptr : base + offset;
    return true;
}

jbyteArray ToByteArray(JNIEnv* env, const std::uint8_t* bytes, std::size_t length) {
    if (length > static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
        Throw(env, "java/lang/IllegalStateException", "native output exceeds JVM array limit");
        return nullptr;
    }
    const auto output = env->NewByteArray(static_cast<jsize>(length));
    if (output != nullptr && length != 0) {
        env->SetByteArrayRegion(output, 0, static_cast<jsize>(length),
                                reinterpret_cast<const jbyte*>(bytes));
    }
    return output;
}

FrameDecoder* Decoder(jlong handle) {
    return reinterpret_cast<FrameDecoder*>(static_cast<std::uintptr_t>(handle));
}

bool IsU8(jint value) { return value >= 0 && value <= 0xff; }
bool IsU16(jint value) { return value >= 0 && value <= 0xffff; }
bool IsU32(jlong value) { return value >= 0 && static_cast<std::uint64_t>(value) <= UINT32_MAX; }
std::uint32_t FloatBits(float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

class ScopedDecodedFramesWipe final {
public:
    explicit ScopedDecodedFramesWipe(std::vector<DecodedFrame>* frames) : frames_(frames) {}
    ~ScopedDecodedFramesWipe() {
        if (frames_ == nullptr) return;
        for (auto& frame : *frames_) {
            if (!frame.payload.empty()) SecureWipe(frame.payload.data(), frame.payload.size());
        }
    }
    ScopedDecodedFramesWipe(const ScopedDecodedFramesWipe&) = delete;
    ScopedDecodedFramesWipe& operator=(const ScopedDecodedFramesWipe&) = delete;

private:
    std::vector<DecodedFrame>* frames_;
};

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_superconnect_protocol_WireNative_nativeAbiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(sc_android_wire_active_marker_v1());
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeEncodeFrame(
    JNIEnv* env, jobject, jint channel, jint flags, jobject buffer, jint offset, jint length) {
    const std::uint8_t* bytes = nullptr;
    if (!IsU8(channel) || !IsU8(flags) || !DirectRange(env, buffer, offset, length, &bytes)) {
        if (!env->ExceptionCheck()) Throw(env, "java/lang/IllegalArgumentException", "invalid frame fields");
        return nullptr;
    }
    std::vector<std::uint8_t> output;
    ScopedVectorWipe<std::uint8_t> output_wipe(&output);
    const auto status = superconnect::android_wire::EncodeFrame(
        static_cast<std::uint8_t>(channel), static_cast<std::uint8_t>(flags), bytes,
        static_cast<std::size_t>(length), &output);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return ToByteArray(env, output.data(), output.size());
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecoderNew(JNIEnv* env, jobject) {
    auto* decoder = new (std::nothrow) FrameDecoder();
    if (decoder == nullptr || !decoder->IsOpen()) {
        delete decoder;
        Throw(env, "java/lang/IllegalStateException", "failed to create Rust frame decoder");
        return 0;
    }
    return static_cast<jlong>(reinterpret_cast<std::uintptr_t>(decoder));
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecoderPush(
    JNIEnv* env, jobject, jlong handle, jobject buffer, jint offset, jint length) {
    auto* decoder = Decoder(handle);
    const std::uint8_t* bytes = nullptr;
    if (decoder == nullptr || !DirectRange(env, buffer, offset, length, &bytes)) {
        if (!env->ExceptionCheck()) Throw(env, "java/lang/IllegalStateException", "frame decoder is closed");
        return nullptr;
    }
    std::vector<DecodedFrame> frames;
    ScopedDecodedFramesWipe frames_wipe(&frames);
    const auto status = decoder->Push(bytes, static_cast<std::size_t>(length), &frames);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    if (frames.size() > static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
        Throw(env, "java/lang/IllegalStateException", "too many decoded frames");
        return nullptr;
    }
    const jclass byte_array = env->FindClass("[B");
    const auto output = env->NewObjectArray(static_cast<jsize>(frames.size()), byte_array, nullptr);
    for (std::size_t index = 0; output != nullptr && index < frames.size(); ++index) {
        std::vector<std::uint8_t> record;
        ScopedVectorWipe<std::uint8_t> record_wipe(&record);
        try {
            record.reserve(2 + frames[index].payload.size());
            record.push_back(frames[index].channel);
            record.push_back(frames[index].flags);
            record.insert(record.end(), frames[index].payload.begin(), frames[index].payload.end());
        } catch (const std::bad_alloc&) {
            Throw(env, "java/lang/OutOfMemoryError", "failed to copy decoded frame");
            return nullptr;
        }
        const auto value = ToByteArray(env, record.data(), record.size());
        if (value == nullptr) return nullptr;
        env->SetObjectArrayElement(output, static_cast<jsize>(index), value);
        env->DeleteLocalRef(value);
    }
    return output;
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecoderReset(JNIEnv* env, jobject, jlong handle) {
    auto* decoder = Decoder(handle);
    if (decoder == nullptr) { Throw(env, "java/lang/IllegalStateException", "frame decoder is closed"); return; }
    const auto status = decoder->Reset();
    if (status != SC_OK) ThrowStatus(env, status);
}

extern "C" JNIEXPORT void JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecoderFree(JNIEnv*, jobject, jlong handle) {
    delete Decoder(handle);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeEncodeInput(
    JNIEnv* env, jobject, jint type, jint tool, jint buttons, jint flags, jlong timestamp,
    jfloat x, jfloat y, jfloat pressure, jfloat tilt_x, jfloat tilt_y,
    jfloat scroll_x, jfloat scroll_y, jint key_code, jint pointer_id) {
    if (!IsU8(type) || !IsU8(tool) || !IsU8(buttons) || !IsU8(flags) ||
        !IsU16(key_code) || !IsU16(pointer_id)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid input fields");
        return nullptr;
    }
    InputFields input{};
    input.type = static_cast<std::uint8_t>(type); input.tool = static_cast<std::uint8_t>(tool);
    input.buttons = static_cast<std::uint8_t>(buttons); input.flags = static_cast<std::uint8_t>(flags);
    input.timestamp_ms = static_cast<std::uint64_t>(timestamp);
    input.x = x; input.y = y; input.pressure = pressure; input.tilt_x = tilt_x; input.tilt_y = tilt_y;
    input.scroll_x = scroll_x; input.scroll_y = scroll_y;
    input.key_code = static_cast<std::uint16_t>(key_code);
    input.pointer_id = static_cast<std::uint16_t>(pointer_id);
    std::array<std::uint8_t, 44> output{};
    ScopedObjectWipe<decltype(output)> output_wipe(&output);
    const auto status = superconnect::android_wire::EncodeInput(input, &output);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return ToByteArray(env, output.data(), output.size());
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecodeInput(
    JNIEnv* env, jobject, jobject buffer, jint offset, jint length) {
    const std::uint8_t* bytes = nullptr;
    if (!DirectRange(env, buffer, offset, length, &bytes)) return nullptr;
    InputFields decoded{};
    auto status = superconnect::android_wire::DecodeInput(bytes, static_cast<std::size_t>(length), &decoded);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    const std::array<jlong, 14> values{
        decoded.type, decoded.tool, decoded.buttons, decoded.flags,
        static_cast<jlong>(decoded.timestamp_ms),
        FloatBits(decoded.x), FloatBits(decoded.y), FloatBits(decoded.pressure),
        FloatBits(decoded.tilt_x), FloatBits(decoded.tilt_y),
        FloatBits(decoded.scroll_x), FloatBits(decoded.scroll_y),
        decoded.key_code, decoded.pointer_id,
    };
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output != nullptr) env->SetLongArrayRegion(output, 0, values.size(), values.data());
    return output;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeEncodeVideoMeta(
    JNIEnv* env, jobject, jint version, jboolean synthetic, jboolean keyframe,
    jlong source, jlong capture, jlong sequence, jlong epoch) {
    if ((version != 1 && version != 2) || !IsU32(source) || !IsU32(capture) || !IsU32(sequence)) {
        Throw(env, "java/lang/IllegalArgumentException", "invalid video metadata fields");
        return nullptr;
    }
    VideoMetaFields input{};
    ScopedObjectWipe<VideoMetaFields> input_wipe(&input);
    input.wire_version = static_cast<std::uint32_t>(version);
    input.is_synthetic = synthetic == JNI_TRUE; input.is_keyframe = keyframe == JNI_TRUE;
    input.source_frame_id = static_cast<std::uint32_t>(source);
    input.capture_time_ms = static_cast<std::uint32_t>(capture);
    input.access_unit_seq = static_cast<std::uint32_t>(sequence);
    input.stream_epoch = static_cast<std::uint64_t>(epoch);
    std::vector<std::uint8_t> output;
    ScopedVectorWipe<std::uint8_t> output_wipe(&output);
    const auto status = superconnect::android_wire::EncodeVideoMeta(input, &output);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    return ToByteArray(env, output.data(), output.size());
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_superconnect_protocol_WireNative_nativeDecodeVideoMeta(
    JNIEnv* env, jobject, jobject buffer, jint offset, jint length) {
    const std::uint8_t* bytes = nullptr;
    if (!DirectRange(env, buffer, offset, length, &bytes)) return nullptr;
    VideoMetaDecode decoded{};
    const auto status = superconnect::android_wire::DecodeVideoMeta(
        bytes, static_cast<std::size_t>(length), &decoded);
    if (status != SC_OK) { ThrowStatus(env, status); return nullptr; }
    const std::array<jlong, 9> values{
        decoded.result, decoded.wire_version, decoded.is_synthetic ? 1 : 0,
        decoded.is_keyframe ? 1 : 0, decoded.source_frame_id, decoded.capture_time_ms,
        decoded.access_unit_seq, decoded.payload_offset, static_cast<jlong>(decoded.stream_epoch),
    };
    const auto output = env->NewLongArray(static_cast<jsize>(values.size()));
    if (output != nullptr) env->SetLongArrayRegion(output, 0, values.size(), values.data());
    return output;
}
