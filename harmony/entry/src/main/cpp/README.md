# Native (C++ / NDK) module — Phase 1 (implemented)

Latency-critical receiver code. **Targets HarmonyOS NEXT API 12+ and must be
built/verified in DevEco Studio** (it cannot be compiled on the Mac host).

```
cpp/
├── CMakeLists.txt            # builds libsuperconnect.so
├── napi_init.cpp             # napi module "superconnect"; XComponent surface
│                             #   callbacks; exposes setVideoSize()/pushVideo()
├── video_decoder.{h,cpp}     # OH_VideoDecoder (surface mode, low-latency)
└── types/libsuperconnect/    # index.d.ts + oh-package.json5 (ArkTS typings)
```

## Flow
1. ArkTS `XComponent({ type: SURFACE, libraryname: 'superconnect' })` → on surface
   create, `napi_init.cpp` binds the `OHNativeWindow` to the decoder.
2. ArkTS `Session` routes VIDEO-channel frames to `sc.pushVideo(arraybuffer, isKeyframe)`.
3. `VideoDecoder` feeds Annex-B access units to `OH_VideoDecoder` and renders each
   decoded frame straight to the surface via `OH_VideoDecoder_RenderOutputBuffer`
   (zero-copy, late frames dropped).

## Enabling the native build in DevEco
The committed files are the **sources**; DevEco owns the build wiring. Easiest:
1. In DevEco: module `entry` → right-click → **Add C++ to Module** (or create the
   project with the *Native C++* template). This generates the
   `externalNativeOptions { path "./src/main/cpp/CMakeLists.txt" }` block in
   `entry/build-profile.json5` and a default `cpp/`. Replace the generated `cpp/`
   with this one (keep DevEco's `build-profile.json5` edits).
2. Add the native types dependency so ArkTS resolves `libsuperconnect.so`:
   in `entry/oh-package.json5` →
   `"dependencies": { "libsuperconnect.so": "file:./src/main/cpp/types/libsuperconnect" }`.
3. Build & run.

## Phase 2 hook
`DispatchTouchEvent` in `napi_init.cpp` is where pen/touch capture will live
(`ui_input_event.h`: `GetToolType==PEN`, pressure/tilt, `GetHistory*`) → INPUT channel.

## To verify on device
- HEVC: add `OH_AVCODEC_MIMETYPE_VIDEO_HEVC` path + capability check (`OH_AVCapability`).
- Confirm the decoder accepts a full access unit (SPS/PPS+IDR) per `OH_AVBuffer`,
  and that `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY` is honored on the target SoC.
- Drive `setVideoSize()` from the negotiated handshake resolution rather than a
  hard-coded 2560×1600 (see protocol hello caps).
