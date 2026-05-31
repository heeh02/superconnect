# Superconnect — HarmonyOS (Pad) app

Tablet-side receiver: accepts the Mac's connection (tunnelled over USB by `hdc fport`),
negotiates caps (`hello_ack`), decodes the incoming HEVC/H.264 stream on the hardware
`OH_VideoDecoder` and renders it onto an `XComponent` surface, and sends touch / pen /
keyboard / trackpad input back over the INPUT channel. Launches in a small windowed
preview; double-tap → immersive fullscreen (exit via the notification bar).

## Layout (mirrors the Mac app's layering)

```
harmony/                       # a complete, buildable DevEco Studio project
├── build-profile.json5        # signingConfigs:[] — use DevEco "automatic signing" (no certs committed)
├── hvigorfile.ts · oh-package.json5 · hvigor/   # build scaffolding
├── AppScope/                  # app.json5 (bundle com.superconnect.pad) + resources/media (icon)
└── entry/src/main/
    ├── module.json5
    ├── ets/
    │   ├── app/AppEnvironment.ets            # composition root (selects the role engine)
    │   ├── models/                           # Role · ConnectionStatus · StreamInfo · Peer · DisplayMode
    │   ├── services/                         # ConnectionManager · connection/{ConnectionEngine,role/*} · discovery · WindowMode · FullscreenNotification
    │   ├── input/                            # InputRouter · KeyboardHandler · GestureController · FrameInputSender
    │   ├── ui/                               # IdleView · WindowedView · ControlPanel · PausedBanner · Theme
    │   ├── protocol/  session/  transport/   # FrameCodec · InputCodec · Session (handshake) · TcpServerTransport
    │   └── pages/Index.ets                   # thin @Entry: XComponent + overlays + state
    ├── cpp/                                  # OH_VideoDecoder (surface mode) + napi bridge (video_decoder.* , napi_init.cpp)
    └── resources/
```

## Build & run (DevEco Studio)

Targets **HarmonyOS NEXT (API 12+)**. This is a self-contained project — no shell-project step.

1. Install **DevEco Studio** + the HarmonyOS SDK (and the **Command Line Tools** for `hdc`).
2. Open this `harmony/` folder in DevEco; run **`ohpm install`** to fetch dependencies.
3. **Signing**: `build-profile.json5` ships with `signingConfigs: []` (no certs committed). In
   **File → Project Structure → Signing Configs**, enable **"Automatically generate signature"**
   to sign with your own Huawei developer identity.
4. Enable **Developer Mode + USB debugging** on the tablet; connect USB; trust the host.
5. **Run** ▶ to install + launch. On the Mac, start the host (the `Superconnect.app` menu/window,
   or `tools/sc-loop.sh`); the tablet shows the Mac screen.

CLI build (after signing is configured): `hvigorw assembleHap -p product=default -p buildMode=debug`.

## Cross-language wire format

`protocol/FrameCodec.ets` + `protocol/InputCodec.ets` are verified byte-identical to the Mac
(Swift) and the portable C++ via the shared golden vectors (`proto/vectors.json`). You can
sanity-check the Swift/C++ side with no device (`mac/` tests + `shared/cpp/tests`).
