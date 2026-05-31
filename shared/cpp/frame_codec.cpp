#include "frame_codec.h"

namespace superconnect {

std::vector<uint8_t> encodeFrame(uint8_t channel, uint8_t flags,
                                 const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> out;
    out.reserve(kFrameHeaderSize + payload.size());
    out.push_back(channel);
    out.push_back(flags);
    const uint32_t len = static_cast<uint32_t>(payload.size());
    out.push_back(static_cast<uint8_t>(len & 0xff));
    out.push_back(static_cast<uint8_t>((len >> 8) & 0xff));
    out.push_back(static_cast<uint8_t>((len >> 16) & 0xff));
    out.push_back(static_cast<uint8_t>((len >> 24) & 0xff));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

std::vector<Frame> FrameDecoder::push(const uint8_t* data, std::size_t len) {
    buffer_.insert(buffer_.end(), data, data + len);
    std::vector<Frame> frames;
    std::size_t cursor = 0;
    while (buffer_.size() - cursor >= kFrameHeaderSize) {
        const std::size_t base = cursor;
        const uint8_t channel = buffer_[base];
        const uint8_t flags = buffer_[base + 1];
        const uint32_t plen = static_cast<uint32_t>(buffer_[base + 2]) |
                              (static_cast<uint32_t>(buffer_[base + 3]) << 8) |
                              (static_cast<uint32_t>(buffer_[base + 4]) << 16) |
                              (static_cast<uint32_t>(buffer_[base + 5]) << 24);
        if (plen > kMaxFramePayload) {
            throw std::runtime_error("frame payload exceeds kMaxFramePayload");
        }
        const std::size_t total = kFrameHeaderSize + plen;
        if (buffer_.size() - base < total) break;  // wait for more bytes
        Frame f;
        f.channel = channel;
        f.flags = flags;
        f.payload.assign(buffer_.begin() + base + kFrameHeaderSize,
                         buffer_.begin() + base + total);
        frames.push_back(std::move(f));
        cursor += total;
    }
    if (cursor > 0) buffer_.erase(buffer_.begin(), buffer_.begin() + cursor);
    return frames;
}

}  // namespace superconnect
