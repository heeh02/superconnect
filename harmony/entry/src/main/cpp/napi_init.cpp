// Superconnect native entry — registers the napi module "superconnect",
// binds the ArkUI XComponent surface to the decoder, and exposes pushVideo()/
// setVideoSize() to ArkTS.
//
// ArkTS side:  import sc from 'libsuperconnect.so'
//              XComponent({ type: XComponentType.SURFACE, libraryname: 'superconnect' })
//
// Build & verify in DevEco Studio (HarmonyOS NEXT, API 12+).
#include <cstdint>
#include <cstring>

#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>

#include "video_decoder.h"

namespace {

struct AppContext {
    superconnect::VideoDecoder decoder;
    OHNativeWindow* window = nullptr;
    int32_t width = 2560;   // overridden by setVideoSize()
    int32_t height = 1600;
    bool sizeKnown = false;

    void tryStart() {
        if (window != nullptr && sizeKnown) {
            decoder.start(window, width, height);
        }
    }
};

AppContext g_ctx;

// ── XComponent surface lifecycle ─────────────────────────────────────────────
void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    g_ctx.window = static_cast<OHNativeWindow*>(window);
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    g_ctx.tryStart();
}

void OnSurfaceChanged(OH_NativeXComponent* /*component*/, void* /*window*/) {}

void OnSurfaceDestroyed(OH_NativeXComponent* /*component*/, void* /*window*/) {
    g_ctx.decoder.stop();
    g_ctx.window = nullptr;
}

void DispatchTouchEvent(OH_NativeXComponent* /*component*/, void* /*window*/) {
    // Phase 2: capture pen/touch here (OH_NativeXComponent_GetTouchEvent /
    // ui_input_event.h GetToolType/Pressure/Tilt/GetHistory*) → INPUT channel.
}

OH_NativeXComponent_Callback g_xcomponentCallback = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = DispatchTouchEvent,
};

// ── napi functions callable from ArkTS ───────────────────────────────────────
napi_value SetVideoSize(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t w = 0, h = 0;
    napi_get_value_int32(env, args[0], &w);
    napi_get_value_int32(env, args[1], &h);
    if (w > 0 && h > 0) {
        // Resolution changed mid-stream (tablet rotated / Mac re-negotiated) → restart the decoder
        // at the new size. stop() resets started_ so the following tryStart re-Configures the codec.
        if (g_ctx.sizeKnown && (w != g_ctx.width || h != g_ctx.height)) {
            g_ctx.decoder.stop();
        }
        g_ctx.width = w;
        g_ctx.height = h;
        g_ctx.sizeKnown = true;
        g_ctx.tryStart();
    }
    return nullptr;
}

napi_value PushVideo(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // Honor the typed-array view's byteOffset/byteLength (data already points at
    // byteOffset; length is the element/byte count for a Uint8Array).
    napi_typedarray_type type;
    size_t length = 0;
    void* data = nullptr;
    napi_value arraybuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, args[0], &type, &length, &data, &arraybuffer, &byteOffset) != napi_ok ||
        data == nullptr) {
        return nullptr;
    }
    bool isKeyframe = false;
    napi_get_value_bool(env, args[1], &isKeyframe);

    g_ctx.decoder.pushAccessUnit(static_cast<const uint8_t*>(data), length, isKeyframe);
    return nullptr;
}

// supportsHevc(): true if the device has a HARDWARE HEVC decoder.
napi_value SupportsHevc(napi_env env, napi_callback_info /*info*/) {
    OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(OH_AVCODEC_MIMETYPE_VIDEO_HEVC, false, HARDWARE);
    napi_value result;
    napi_get_boolean(env, cap != nullptr, &result);
    return result;
}

// hdrDecodeCaps(): does the HARDWARE HEVC decoder do 10-bit / HDR? Bitmask:
//   bit0 (1) = HEVC Main10 (10-bit)      bit1 (2) = Main10 HDR10 (PQ)
// There is no shell oracle for this on HarmonyOS, so the app must probe the
// decoder's supported profiles at runtime. This is the decisive HDR gate.
napi_value HdrDecodeCaps(napi_env env, napi_callback_info /*info*/) {
    int32_t mask = 0;
    OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(OH_AVCODEC_MIMETYPE_VIDEO_HEVC, false, HARDWARE);
    if (cap != nullptr) {
        const int32_t* profiles = nullptr;
        uint32_t num = 0;
        if (OH_AVCapability_GetSupportedProfiles(cap, &profiles, &num) == AV_ERR_OK && profiles != nullptr) {
            for (uint32_t i = 0; i < num; ++i) {
                if (profiles[i] == HEVC_PROFILE_MAIN_10) { mask |= 1; }
                if (profiles[i] == HEVC_PROFILE_MAIN_10_HDR10) { mask |= 2; }
            }
        }
    }
    napi_value result;
    napi_create_int32(env, mask, &result);
    return result;
}

// setCodec("h264"|"hevc"): choose the decoder MIME (call before frames arrive).
napi_value SetCodec(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char buf[32] = {0};
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len) == napi_ok) {
        const char* mime = (std::strcmp(buf, "hevc") == 0)
            ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        g_ctx.decoder.setCodec(mime);
    }
    return nullptr;
}

// setHdr("off"|"hlg"|"pq"): enable 10-bit HDR decode + BT.2020 presentation (call before frames).
napi_value SetHdr(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char buf[16] = {0};
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len) == napi_ok) {
        g_ctx.decoder.setHdr(std::strcmp(buf, "off") != 0);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"setVideoSize", nullptr, SetVideoSize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushVideo", nullptr, PushVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"supportsHevc", nullptr, SupportsHevc, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hdrDecodeCaps", nullptr, HdrDecodeCaps, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCodec", nullptr, SetCodec, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setHdr", nullptr, SetHdr, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // Grab the XComponent instance the ArkUI XComponent (libraryname:'superconnect')
    // injected into our module exports, and register surface callbacks.
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) == napi_ok) {
        OH_NativeXComponent* nativeXComponent = nullptr;
        if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) == napi_ok &&
            nativeXComponent != nullptr) {
            OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xcomponentCallback);
        }
    }
    return exports;
}

}  // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "superconnect",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSuperconnectModule(void) {
    napi_module_register(&g_module);
}
