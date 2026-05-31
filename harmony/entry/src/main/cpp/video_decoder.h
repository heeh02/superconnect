// Superconnect native decoder/renderer — HarmonyOS NEXT (API 12+).
//
// Wraps OH_VideoDecoder in SURFACE mode for low-latency H.264 decode, rendering
// directly to the Surface bound to an ArkUI XComponent (OHNativeWindow). Input
// is Annex-B NAL access units fed from ArkTS via napi (see napi_init.cpp).
//
// NOTE: This targets the HarmonyOS NEXT native AVCodec API and must be built &
// verified in DevEco Studio (it cannot be compiled on the Mac host).
#ifndef SUPERCONNECT_VIDEO_DECODER_H
#define SUPERCONNECT_VIDEO_DECODER_H

#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <native_window/external_window.h>

namespace superconnect {

class VideoDecoder {
public:
    VideoDecoder() = default;
    ~VideoDecoder();

    // Bind to the XComponent's native window and start decoding at width×height.
    bool start(OHNativeWindow* window, int32_t width, int32_t height);
    void stop();

    // Set the codec MIME (e.g. OH_AVCODEC_MIMETYPE_VIDEO_AVC/HEVC) before start().
    void setCodec(const char* mime);

    // Enable 10-bit HDR (HEVC Main10 + BT.2020 PQ) before start(). Off = SDR (default).
    void setHdr(bool on);

    // Feed one Annex-B access unit (may contain SPS/PPS + IDR). Thread-safe.
    void pushAccessUnit(const uint8_t* data, size_t size, bool isKeyframe);

    // Codec callback plumbing (called from the decoder's worker threads).
    void onNeedInputBuffer(uint32_t index, OH_AVBuffer* buffer);
    void onNewOutputBuffer(uint32_t index, OH_AVBuffer* buffer);
    void onError(int32_t errorCode);

private:
    struct InputSlot { uint32_t index; OH_AVBuffer* buffer; };
    struct Packet { std::vector<uint8_t> bytes; bool keyframe; int64_t pts; };

    void feed();  // match a pending packet to an available input slot

    OH_AVCodec* codec_ = nullptr;
    OHNativeWindow* window_ = nullptr;
    std::string codecMime_ = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    bool hdr_ = false;   // 10-bit HEVC Main10 + BT.2020 PQ when true
    int32_t width_ = 0;
    int32_t height_ = 0;
    int64_t ptsCounter_ = 0;
    bool started_ = false;
    bool awaitingKeyframe_ = false;   // after a drop, discard P-frames until next IDR (anti-smear)

    std::mutex mutex_;
    std::deque<InputSlot> freeInputs_;
    std::deque<Packet> pending_;
};

}  // namespace superconnect

#endif  // SUPERCONNECT_VIDEO_DECODER_H
