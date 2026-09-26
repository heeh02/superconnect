#include "AndroidWireBridge.h"

#include <algorithm>
#include <cstring>
#include <new>
#include <utility>

extern "C" uint32_t sc_android_wire_active_marker_v1(void) {
    return sc_core_abi_version_v1();
}

namespace superconnect::android_wire {

bool IsValidBufferRange(std::size_t capacity, std::size_t offset, std::size_t length) {
    return offset <= capacity && length <= capacity - offset;
}

ScStatus EncodeFrame(std::uint8_t channel, std::uint8_t flags, const std::uint8_t* payload,
                     std::size_t payload_length, std::vector<std::uint8_t>* output) {
    if (output == nullptr || payload_length > kMaxFramePayload ||
        (payload_length != 0 && payload == nullptr)) return SC_INVALID_ARGUMENT;
    try {
        output->assign(kFrameHeaderSize + payload_length, 0);
    } catch (const std::bad_alloc&) {
        return SC_INTERNAL_ERROR;
    }
    ScFrameV1 frame{};
    frame.struct_size = sizeof(frame);
    frame.api_version = SC_API_VERSION_V1;
    frame.channel = channel;
    frame.flags = flags;
    frame.payload = payload;
    frame.payload_length = payload_length;
    std::size_t needed = 0;
    const auto status = sc_frame_encode_v1(&frame, output->data(), output->size(), &needed);
    if (status != SC_OK || needed != output->size()) {
        if (!output->empty()) SecureWipe(output->data(), output->size());
        output->clear();
        return status == SC_OK ? SC_INTERNAL_ERROR : status;
    }
    return SC_OK;
}

ScStatus EncodeInput(const InputFields& input, std::array<std::uint8_t, 44>* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    ScInputEventV1 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    event.type = input.type;
    event.tool = input.tool;
    event.buttons = input.buttons;
    event.flags = input.flags;
    event.timestamp_ms = input.timestamp_ms;
    event.x = input.x;
    event.y = input.y;
    event.pressure = input.pressure;
    event.tilt_x = input.tilt_x;
    event.tilt_y = input.tilt_y;
    event.scroll_x = input.scroll_x;
    event.scroll_y = input.scroll_y;
    event.key_code = input.key_code;
    event.pointer_id = input.pointer_id;
    std::size_t needed = 0;
    const auto status = sc_input_encode_v1(&event, output->data(), output->size(), &needed);
    return status == SC_OK && needed != output->size() ? SC_INTERNAL_ERROR : status;
}

ScStatus DecodeInput(const std::uint8_t* bytes, std::size_t length, InputFields* output) {
    if (output == nullptr || (length != 0 && bytes == nullptr)) return SC_INVALID_ARGUMENT;
    ScInputEventV1 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    const auto status = sc_input_decode_v1(bytes, length, &event);
    if (status != SC_OK) return status;
    output->type = event.type;
    output->tool = event.tool;
    output->buttons = event.buttons;
    output->flags = event.flags;
    output->timestamp_ms = event.timestamp_ms;
    output->x = event.x;
    output->y = event.y;
    output->pressure = event.pressure;
    output->tilt_x = event.tilt_x;
    output->tilt_y = event.tilt_y;
    output->scroll_x = event.scroll_x;
    output->scroll_y = event.scroll_y;
    output->key_code = event.key_code;
    output->pointer_id = event.pointer_id;
    return SC_OK;
}

ScStatus EncodeVideoMeta(const VideoMetaFields& input, std::vector<std::uint8_t>* output) {
    if (output == nullptr) return SC_INVALID_ARGUMENT;
    const std::size_t size = input.wire_version == 1 ? SC_VIDEO_META_V1_SIZE :
        (input.wire_version == 2 ? SC_VIDEO_META_V2_SIZE : 0);
    if (size == 0) return SC_INVALID_ARGUMENT;
    try {
        output->assign(size, 0);
    } catch (const std::bad_alloc&) {
        return SC_INTERNAL_ERROR;
    }
    ScVideoMetaV1 meta{};
    meta.struct_size = sizeof(meta);
    meta.api_version = SC_API_VERSION_V1;
    meta.wire_version = input.wire_version;
    meta.is_synthetic = input.is_synthetic ? 1U : 0U;
    meta.is_keyframe = input.is_keyframe ? 1U : 0U;
    meta.source_frame_id = input.source_frame_id;
    meta.capture_time_ms = input.capture_time_ms;
    meta.access_unit_seq = input.access_unit_seq;
    meta.stream_epoch = input.stream_epoch;
    std::size_t needed = 0;
    const auto status = sc_video_meta_encode_v1(&meta, output->data(), output->size(), &needed);
    if (status != SC_OK || needed != output->size()) {
        if (!output->empty()) SecureWipe(output->data(), output->size());
        output->clear();
        return status == SC_OK ? SC_INTERNAL_ERROR : status;
    }
    return SC_OK;
}

ScStatus DecodeVideoMeta(const std::uint8_t* bytes, std::size_t length, VideoMetaDecode* output) {
    if (output == nullptr || (length != 0 && bytes == nullptr)) return SC_INVALID_ARGUMENT;
    ScVideoMetaDecodeV1 decoded{};
    decoded.struct_size = sizeof(decoded);
    decoded.api_version = SC_API_VERSION_V1;
    const auto status = sc_video_meta_decode_v1(bytes, length, &decoded);
    if (status != SC_OK) return status;
    output->result = decoded.result;
    output->wire_version = decoded.wire_version;
    output->is_synthetic = decoded.is_synthetic == 1;
    output->is_keyframe = decoded.is_keyframe == 1;
    output->source_frame_id = decoded.source_frame_id;
    output->capture_time_ms = decoded.capture_time_ms;
    output->access_unit_seq = decoded.access_unit_seq;
    output->payload_offset = decoded.payload_offset;
    output->stream_epoch = decoded.stream_epoch;
    return SC_OK;
}

FrameDecoder::FrameDecoder() {
    ScFrameDecoderConfigV1 config{};
    config.struct_size = sizeof(config);
    config.api_version = SC_API_VERSION_V1;
    if (sc_frame_decoder_new_v1(&config, &decoder_) != SC_OK) decoder_ = nullptr;
}

FrameDecoder::~FrameDecoder() { Close(); }

ScStatus FrameDecoder::PushSlice(const std::uint8_t* bytes, std::size_t length) {
    if (decoder_ == nullptr || (length != 0 && bytes == nullptr)) return SC_INVALID_ARGUMENT;
    return sc_frame_decoder_push_v1(decoder_, bytes, length);
}

ScStatus FrameDecoder::Drain(std::vector<DecodedFrame>* output) {
    while (true) {
        ScFrameViewV1 view{};
        view.struct_size = sizeof(view);
        view.api_version = SC_API_VERSION_V1;
        const auto next = sc_frame_decoder_next_v1(decoder_, &view);
        if (next == SC_NO_FRAME) return SC_OK;
        if (next != SC_OK) return next;
        try {
            DecodedFrame frame;
            ScopedVectorWipe<std::uint8_t> frame_wipe(&frame.payload);
            frame.channel = view.channel;
            frame.flags = view.flags;
            if (view.payload_length != 0) {
                if (view.payload == nullptr) return SC_INTERNAL_ERROR;
                frame.payload.assign(view.payload, view.payload + view.payload_length);
            }
            output->push_back(std::move(frame));
        } catch (const std::bad_alloc&) {
            static_cast<void>(Reset());
            return SC_INTERNAL_ERROR;
        }
        const auto consumed = sc_frame_decoder_consume_v1(decoder_, view.generation);
        if (consumed != SC_OK) return consumed;
    }
}

ScStatus FrameDecoder::Push(const std::uint8_t* bytes, std::size_t length,
                            std::vector<DecodedFrame>* output) {
    if (decoder_ == nullptr || output == nullptr || (length != 0 && bytes == nullptr)) {
        return SC_INVALID_ARGUMENT;
    }
    std::size_t offset = 0;
    while (offset < length) {
        if (payload_remaining_ != 0) {
            const auto take = std::min(payload_remaining_, length - offset);
            const auto pushed = PushSlice(bytes + offset, take);
            if (pushed != SC_OK) return pushed;
            offset += take;
            payload_remaining_ -= take;
            if (payload_remaining_ == 0) {
                const auto drained = Drain(output);
                if (drained != SC_OK) return drained;
            }
            continue;
        }
        const auto take = std::min(kFrameHeaderSize - header_length_, length - offset);
        std::memcpy(header_.data() + header_length_, bytes + offset, take);
        const auto pushed = PushSlice(bytes + offset, take);
        if (pushed != SC_OK) {
            SecureWipe(header_.data(), header_.size());
            header_length_ = 0;
            return pushed;
        }
        header_length_ += take;
        offset += take;
        if (header_length_ != kFrameHeaderSize) continue;
        payload_remaining_ = static_cast<std::size_t>(header_[2]) |
            (static_cast<std::size_t>(header_[3]) << 8U) |
            (static_cast<std::size_t>(header_[4]) << 16U) |
            (static_cast<std::size_t>(header_[5]) << 24U);
        SecureWipe(header_.data(), header_.size());
        header_length_ = 0;
        if (payload_remaining_ > kMaxFramePayload) return Drain(output);
        if (payload_remaining_ == 0) {
            const auto drained = Drain(output);
            if (drained != SC_OK) return drained;
        }
    }
    return length == 0 ? Drain(output) : SC_OK;
}

ScStatus FrameDecoder::Reset() {
    if (decoder_ == nullptr) return SC_INVALID_ARGUMENT;
    const auto status = sc_frame_decoder_reset_v1(decoder_);
    SecureWipe(header_.data(), header_.size());
    if (status == SC_OK) {
        header_length_ = 0;
        payload_remaining_ = 0;
    }
    return status;
}

void FrameDecoder::Close() {
    if (decoder_ != nullptr) {
        static_cast<void>(sc_frame_decoder_free_v1(decoder_));
        decoder_ = nullptr;
    }
    SecureWipe(header_.data(), header_.size());
    header_length_ = 0;
    payload_remaining_ = 0;
}

}  // namespace superconnect::android_wire
