#pragma once

#include "superconnect_core.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <vector>

#if defined(__GNUC__) || defined(__clang__)
#define SC_ANDROID_WIRE_EXPORT __attribute__((visibility("default")))
#else
#define SC_ANDROID_WIRE_EXPORT
#endif

extern "C" SC_ANDROID_WIRE_EXPORT uint32_t sc_android_wire_active_marker_v1(void);

namespace superconnect::android_wire {

constexpr std::size_t kFrameHeaderSize = 6;
constexpr std::size_t kMaxFramePayload = 16U * 1024U * 1024U;

/** Volatile wipe used only for adapter-owned transient copies; it does not alter the public C ABI. */
inline void SecureWipe(void* value, std::size_t size) noexcept {
    auto* bytes = static_cast<volatile std::uint8_t*>(value);
    while (size != 0) {
        *bytes++ = 0;
        --size;
    }
}

template <typename Value>
class ScopedObjectWipe final {
public:
    explicit ScopedObjectWipe(Value* value) noexcept : value_(value) {
        static_assert(std::is_trivially_copyable_v<Value>);
    }
    ~ScopedObjectWipe() { if (value_ != nullptr) SecureWipe(value_, sizeof(Value)); }
    ScopedObjectWipe(const ScopedObjectWipe&) = delete;
    ScopedObjectWipe& operator=(const ScopedObjectWipe&) = delete;

private:
    Value* value_;
};

template <typename Value>
class ScopedVectorWipe final {
public:
    explicit ScopedVectorWipe(std::vector<Value>* value) noexcept : value_(value) {
        static_assert(std::is_trivially_copyable_v<Value>);
    }
    ~ScopedVectorWipe() {
        if (value_ != nullptr && !value_->empty()) {
            SecureWipe(value_->data(), value_->size() * sizeof(Value));
        }
    }
    ScopedVectorWipe(const ScopedVectorWipe&) = delete;
    ScopedVectorWipe& operator=(const ScopedVectorWipe&) = delete;

private:
    std::vector<Value>* value_;
};

struct DecodedFrame {
    std::uint8_t channel = 0;
    std::uint8_t flags = 0;
    std::vector<std::uint8_t> payload;
};

struct InputFields {
    std::uint8_t type = 0;
    std::uint8_t tool = 0;
    std::uint8_t buttons = 0;
    std::uint8_t flags = 0;
    std::uint64_t timestamp_ms = 0;
    float x = 0;
    float y = 0;
    float pressure = 0;
    float tilt_x = 0;
    float tilt_y = 0;
    float scroll_x = 0;
    float scroll_y = 0;
    std::uint16_t key_code = 0;
    std::uint16_t pointer_id = 0;
};

struct VideoMetaFields {
    std::uint32_t wire_version = 0;
    bool is_synthetic = false;
    bool is_keyframe = false;
    std::uint32_t source_frame_id = 0;
    std::uint32_t capture_time_ms = 0;
    std::uint32_t access_unit_seq = 0;
    std::uint64_t stream_epoch = 0;
};

struct VideoMetaDecode : VideoMetaFields {
    std::uint32_t result = 0;
    std::uint32_t payload_offset = 0;
};

ScStatus EncodeFrame(std::uint8_t channel, std::uint8_t flags, const std::uint8_t* payload,
                     std::size_t payload_length, std::vector<std::uint8_t>* output);
ScStatus EncodeInput(const InputFields& input, std::array<std::uint8_t, 44>* output);
ScStatus DecodeInput(const std::uint8_t* bytes, std::size_t length, InputFields* output);
ScStatus EncodeVideoMeta(const VideoMetaFields& input, std::vector<std::uint8_t>* output);
ScStatus DecodeVideoMeta(const std::uint8_t* bytes, std::size_t length, VideoMetaDecode* output);
bool IsValidBufferRange(std::size_t capacity, std::size_t offset, std::size_t length);

class FrameDecoder final {
public:
    FrameDecoder();
    ~FrameDecoder();
    FrameDecoder(const FrameDecoder&) = delete;
    FrameDecoder& operator=(const FrameDecoder&) = delete;

    bool IsOpen() const { return decoder_ != nullptr; }
    ScStatus Push(const std::uint8_t* bytes, std::size_t length, std::vector<DecodedFrame>* output);
    ScStatus Reset();
    void Close();

private:
    ScStatus Drain(std::vector<DecodedFrame>* output);
    ScStatus PushSlice(const std::uint8_t* bytes, std::size_t length);
    ScFrameDecoderV1* decoder_ = nullptr;
    std::array<std::uint8_t, kFrameHeaderSize> header_{};
    std::size_t header_length_ = 0;
    std::size_t payload_remaining_ = 0;
};

}  // namespace superconnect::android_wire

#undef SC_ANDROID_WIRE_EXPORT
