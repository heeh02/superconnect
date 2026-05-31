// Superconnect wire framing — portable C++17, zero dependencies.
//
// This is the SAME framing as mac/Sources/SuperconnectCore/FrameCodec.swift and
// the ArkTS FrameCodec.ets, and it is reused inside the HarmonyOS NDK module in
// Phase 1 (decoder/transport native code). It must match proto/vectors.json
// byte-for-byte. See proto/protocol.md.
#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace superconnect {

enum class Channel : uint8_t {
    Control = 0,
    Video = 1,
    Input = 2,
    Audio = 3,
    Stats = 4,
};

namespace frameflags {
constexpr uint8_t Keyframe = 0x01;
constexpr uint8_t CodecConfig = 0x02;
}  // namespace frameflags

struct Frame {
    uint8_t channel;
    uint8_t flags;
    std::vector<uint8_t> payload;
};

constexpr std::size_t kFrameHeaderSize = 6;
constexpr std::size_t kMaxFramePayload = 16u * 1024u * 1024u;  // 16 MiB

// Encode one frame: channel:u8 | flags:u8 | length:u32-LE | payload.
std::vector<uint8_t> encodeFrame(uint8_t channel, uint8_t flags,
                                 const std::vector<uint8_t>& payload);

// Streaming decoder: tolerant of arbitrary fragmentation/coalescing.
class FrameDecoder {
public:
    // Append received bytes; returns frames completed so far.
    std::vector<Frame> push(const uint8_t* data, std::size_t len);
    std::vector<Frame> push(const std::vector<uint8_t>& data) {
        return push(data.data(), data.size());
    }

private:
    std::vector<uint8_t> buffer_;
};

}  // namespace superconnect
