#include "video_decoder.h"

#include <algorithm>
#include <cstring>

#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>   // OH_NativeWindow_SetColorSpace (HDR presentation)

namespace superconnect {

// ── C trampolines required by the OH_AVCodecCallback struct ──────────────────
static void OnErrorCb(OH_AVCodec*, int32_t errorCode, void* userData) {
    static_cast<VideoDecoder*>(userData)->onError(errorCode);
}
static void OnStreamChangedCb(OH_AVCodec*, OH_AVFormat*, void*) {
    // Resolution/format change — handled by reconfiguring in a later phase.
}
static void OnNeedInputBufferCb(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    static_cast<VideoDecoder*>(userData)->onNeedInputBuffer(index, buffer);
}
static void OnNewOutputBufferCb(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    static_cast<VideoDecoder*>(userData)->onNewOutputBuffer(index, buffer);
}

VideoDecoder::~VideoDecoder() { stop(); }

bool VideoDecoder::start(OHNativeWindow* window, int32_t width, int32_t height) {
    if (started_) return true;
    window_ = window;
    width_ = width;
    height_ = height;

    codec_ = OH_VideoDecoder_CreateByMime(codecMime_.c_str());
    if (codec_ == nullptr) return false;

    OH_AVCodecCallback cb;
    cb.onError = OnErrorCb;
    cb.onStreamChanged = OnStreamChangedCb;
    cb.onNeedInputBuffer = OnNeedInputBufferCb;
    cb.onNewOutputBuffer = OnNewOutputBufferCb;
    if (OH_VideoDecoder_RegisterCallback(codec_, cb, this) != AV_ERR_OK) return false;

    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    if (hdr_) {
        // 10-bit Main10 so the HW decoder negotiates a P010 surface buffer; BT.2020 PQ
        // colorimetry rides in the HEVC VUI/SEI. (Do NOT set PIXEL_FORMAT or the
        // HDR->SDR OUTPUT_COLOR_SPACE key — those would clamp to 8-bit / force tone-map.)
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, HEVC_PROFILE_MAIN_10);
    }
    int32_t cfg = OH_VideoDecoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    if (cfg != AV_ERR_OK) return false;

    // Surface mode: bind the output window AFTER Configure. (Verified on a
    // HarmonyOS 6.1 device — calling SetSurface before Configure returns
    // "set output surface failed".)
    if (OH_VideoDecoder_SetSurface(codec_, window_) != AV_ERR_OK) return false;

    if (hdr_ && window_ != nullptr) {
        // Tell the compositor this surface is BT.2020 PQ (video-range) → it presents HDR.
        OH_NativeWindow_SetColorSpace(window_, OH_COLORSPACE_BT2020_PQ_LIMIT);
    }

    if (OH_VideoDecoder_Prepare(codec_) != AV_ERR_OK) return false;
    if (OH_VideoDecoder_Start(codec_) != AV_ERR_OK) return false;

    started_ = true;
    return true;
}

void VideoDecoder::stop() {
    // Detach codec_ under the lock first so any callback racing on a worker
    // thread sees nullptr and bails before we Stop/Destroy it.
    OH_AVCodec* local = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        local = codec_;
        codec_ = nullptr;
        started_ = false;
        awaitingKeyframe_ = false;
        freeInputs_.clear();
        pending_.clear();
    }
    if (local != nullptr) {
        OH_VideoDecoder_Stop(local);
        OH_VideoDecoder_Destroy(local);
    }
}

void VideoDecoder::setCodec(const char* mime) {
    if (mime == nullptr || *mime == '\0') return;
    std::lock_guard<std::mutex> lock(mutex_);
    codecMime_ = mime;
}

void VideoDecoder::setHdr(bool on) {
    std::lock_guard<std::mutex> lock(mutex_);
    hdr_ = on;
}

void VideoDecoder::pushAccessUnit(const uint8_t* data, size_t size, bool isKeyframe) {
    if (size == 0) return;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (codec_ == nullptr) return;

        if (isKeyframe) {
            // Resync cleanly from the keyframe: drop any stale backlog.
            awaitingKeyframe_ = false;
            pending_.clear();
        } else if (awaitingKeyframe_) {
            return;  // after a drop, discard orphan P-frames until the next IDR (avoids smear)
        } else if (pending_.size() >= 8) {
            // Falling behind: don't feed a broken GOP. Freeze on the last good
            // frame and wait for the next keyframe (≤1s) — a brief pause, not a smear.
            pending_.clear();
            awaitingKeyframe_ = true;
            return;
        }

        Packet p;
        p.bytes.assign(data, data + size);
        p.keyframe = isKeyframe;
        p.pts = ptsCounter_++;
        pending_.push_back(std::move(p));
    }
    feed();
}

void VideoDecoder::onNeedInputBuffer(uint32_t index, OH_AVBuffer* buffer) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        freeInputs_.push_back({index, buffer});
    }
    feed();
}

void VideoDecoder::feed() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (codec_ == nullptr) return;
    while (!freeInputs_.empty() && !pending_.empty()) {
        InputSlot slot = freeInputs_.front();
        Packet& pkt = pending_.front();

        uint8_t* dst = OH_AVBuffer_GetAddr(slot.buffer);
        int32_t cap = OH_AVBuffer_GetCapacity(slot.buffer);
        if (dst == nullptr || cap < static_cast<int32_t>(pkt.bytes.size())) {
            // Drop oversized packet; keep the input slot for the next one.
            pending_.pop_front();
            continue;
        }
        std::memcpy(dst, pkt.bytes.data(), pkt.bytes.size());

        OH_AVCodecBufferAttr attr;
        attr.offset = 0;
        attr.size = static_cast<int32_t>(pkt.bytes.size());
        attr.pts = pkt.pts;
        attr.flags = pkt.keyframe ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);

        OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        freeInputs_.pop_front();
        pending_.pop_front();
    }
}

void VideoDecoder::onNewOutputBuffer(uint32_t index, OH_AVBuffer* /*buffer*/) {
    // Surface mode: render directly to the bound window (low latency, zero copy).
    // Guard codec_ under the lock so a concurrent stop() can't free it mid-call.
    std::lock_guard<std::mutex> lock(mutex_);
    if (codec_ != nullptr) {
        OH_VideoDecoder_RenderOutputBuffer(codec_, index);
    }
}

void VideoDecoder::onError(int32_t /*errorCode*/) {
    // Phase 1: best-effort. A robust version would surface this to ArkTS and
    // trigger a reconfigure / keyframe request.
}

}  // namespace superconnect
