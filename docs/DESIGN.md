# Superconnect — 鸿蒙平板作为 macOS 外接屏（投屏 + 触控 + 手写笔）

> 设计文档 v0.1（2026-05-29）。目标：把华为平板变成 Mac 的一块"扩展屏"，支持投屏、触控、以及 M-Pencil 手写笔笔记。
> 先实现**有线**连接，预留**内网无线**接口。骨架以"后期可维护"为第一原则。

---

## 0. 当前环境与既定事实（本机已实测）

| 项 | 实测值 | 来源 |
|---|---|---|
| Mac OS / 架构 | **macOS 26.5（build 25F71），Apple Silicon arm64** | `sw_vers` / `uname -m` |
| Xcode SDK | **MacOSX26.4.sdk** 在位 | 研究核验 |
| 平板 USB 枚举 | `idVendor=0x12D1`(华为) / `USB Vendor Name=HISILICON` / `USB Product Name=HDC Device` | `ioreg -p IOUSB` |
| 平板形态推断 | **HarmonyOS（极可能是 HarmonyOS NEXT / 纯血鸿蒙）**，已开启开发者模式/USB 调试，正在暴露 **HDC** 接口 | 同上 |
| Mac 侧工具 | `hdc`/`adb` **均未安装**（需装 HarmonyOS Command Line Tools / DevEco） | `command -v` |
| 当前数据链路 | 仅物理连线，**尚无可用数据通道**（未见 USB 网卡/tether 接口） | `networksetup` / `ifconfig` |

**关于"两侧 Type-C 都支持 USB 3.2 且支持视频输出"的澄清（重要）：**
USB-C 的"视频输出"是 **DisplayPort Alt Mode 的 *源*（source）** 能力——Mac 和平板都是"源"。要让平板用纯硬件显示 Mac 画面，平板必须是 DP **sink（像显示器一样接收）**，而消费级平板（含 MatePad）对任意 USB-C 主机**不提供 DP sink**。所以"插线即当显示器"的硬件路走不通，**必须走软件方案**（采集→编码→传输→解码→渲染）。
好消息：USB 3.2（5–10 Gbps）是我们极佳的**数据管道**——HDC 隧道跑在它上面，带宽近乎无限、时延远低于 Wi‑Fi，因此**先做有线**是正确选择，画质/码率可以拉很高。

---

## 1. 核心结论与关键决策

1. **有线传输 = `hdc fport`（TCP over USB）**。这是整个设计的"地基洞察"：
   - Mac 上 `hdc fport tcp:8888 tcp:8888` 把 Mac 本地端口经 USB 隧道转发到平板上监听的端口；
   - 平板侧 app 用 `TCPSocketServer` 监听（仅需 `ohos.permission.INTERNET`，第三方应用自动授予）；
   - **同一套 TCP 代码，未来无线只需把"连 localhost"换成"连局域网 IP"**，传输层以上**零改动**。这正是 scrcpy 的做法。
2. **macOS 扩展屏 = 私有 `CGVirtualDisplay` 造屏 + `ScreenCaptureKit` 采集 + `VideoToolbox` 硬编**。
   - 采集→编码这一半已对着 **macOS 26.4 SDK 头文件确认（高可信）**；造屏是私有 API（DeskPad/BetterDisplay/UltraXReal 在 2026 仍在用），**运行期需在 26.5 真机复验**。
3. **平板端 = 纯鸿蒙 `.hap`，ArkTS/ArkUI + C/C++ NDK**。不能复用任何 APK；可移植的是**纯 C/C++（编解码胶水、协议、数学）**与重写为 ArkTS 的业务逻辑。
   - 视频解码用 native **`OH_VideoDecoder`（surface 模式，低时延）**；渲染走 **`XComponent`(type:'surface') + OHNativeWindow**。
   - 笔/触控用 **`XComponent` + native `ui_input_event.h`**，并用 **`GetHistory*`** 取帧间高频采样点（笔迹平滑的关键），用 `GetToolType==PEN` 区分笔与手指，读 `pressure / tiltX / tiltY / rollAngle`。
4. **输入注入到 Mac**：
   - 指针/键盘：`CGEvent` + `CGEventPost(kCGHIDEventTap)`（需"辅助功能"TCC 权限）——简单可靠。
   - 笔压力：分阶段。**先用 CGEvent 的 tablet 子类型**（`kCGEventMouseSubtypeTabletPoint` + `kCGTabletEventPointPressure`，公开 API 可注入压力，对部分 app 有效）；**要让 Photoshop/Procreate 类专业 app 稳定识别压力，需 DriverKit 虚拟 HID（数字化板）系统扩展**（Astropad 路线，需向 Apple 申请 `com.apple.developer.driverkit` 权限，周期长）。
5. **分发假设：个人自用**（"我的华为平板"）。因此：私有 `CGVirtualDisplay`、侧载 `.hap` 都可接受；不上 Mac App Store；DriverKit 走开发者模式（`systemextensionsctl developer on`）即可本机调试。

---

## 2. 总体架构（分层 + 可替换传输边界）

```
┌────────────────────────── macOS App (Swift) ─────────────────────────┐      ┌──────────────────── HarmonyOS App (.hap) ────────────────────┐
│  L5  Session/UI        配对、生命周期、能力协商、设置                  │      │  L5  Session/UI (ArkTS/ArkUI)  连接状态、设置、画布            │
│  L4  Producer Pipeline                                                │      │  L4  Consumer Pipeline                                         │
│       ├ VirtualDisplay(CGVirtualDisplay)  ← 造扩展屏                   │      │       ├ VideoDecoder (OH_VideoDecoder, surface) ← 解码        │
│       ├ ScreenCapture (ScreenCaptureKit)  ← 采集该屏                   │      │       ├ Renderer (XComponent/OHNativeWindow)    ← 渲染       │
│       ├ Encoder (VideoToolbox H.264/HEVC) ← 硬编                       │      │       └ InputCapture (ui_input_event.h, GetHistory*) ← 笔/触控│
│       └ InputInjector (CGEvent / DriverKit-HID) ← 回注输入            │      │                                                              │
│  L3  ChannelMux   [channelId][len][payload] 帧 + 背压 + 丢帧策略       │◀────▶│  L3  ChannelMux  （同一套协议，双端共享定义）                 │
│  L2  Session/Handshake  版本/能力协商 · 时钟同步 · (无线)加密握手      │      │  L2  Session/Handshake                                        │
│  L1  Transport 接口  connect/read/write/close（单条可靠有序字节流）   │◀═══▶│  L1  Transport 接口                                            │
│  L0  TcpTransport（有线: 连 127.0.0.1:P + hdc fport / 无线: 连 LAN IP）│      │  L0  TcpServerTransport（监听 127.0.0.1:P，无线时 0.0.0.0:P）  │
└───────────────────────────────────────────────────────────────────────┘      └───────────────────────────────────────────────────────────────┘
                              ▲  USB 3.2 线（hdc fport 隧道）  /  未来：内网 Wi‑Fi
```

**可维护性的关键：L2 及以上的所有代码"只写一次"，切换 USB↔Wi‑Fi 只动 L0/L1 与"发现"逻辑。**

---

## 3. 关键技术选型（逐层，附 API 与出处）

### 3.1 macOS：虚拟扩展屏 `CGVirtualDisplay`（私有）
- `CGVirtualDisplayDescriptor`（name/maxPixels/sizeInMillimeters/vendor-product-serial）→ `CGVirtualDisplay(descriptor:)` → 读回 **`displayID: CGDirectDisplayID`** → `applySettings:`（含 `CGVirtualDisplayMode` 分辨率表 + `hiDPI=1`）。
- 参考实现：**DeskPad**（开源、可直接抄头文件 `CGVirtualDisplayPrivate.h`）、**VirtualDisplayKit**（SPM 封装）、**UltraXReal**（2026 仍在 Apple Silicon 上用）。
- 注意：HiDPI 需把采集宽高乘 `backingScaleFactor`，否则糊；macOS 15+ 需 `showCursor:true` 否则光标在虚拟屏消失；私有 API → 不能上架、需做"安全退出"快捷键以拆除卡死的虚拟屏。
- ⚠️ **待真机复验**：CGVirtualDisplay 在 macOS 26.5 是否仍能注册出可被 SCK 枚举的 `CGDirectDisplayID`。

### 3.2 macOS：屏幕捕获 `ScreenCaptureKit`（公开，已确认）
- 流程：`SCShareableContent.getShareableContent` → 找 `SCDisplay.displayID == 我们的虚拟屏 displayID` → `SCContentFilter(display:excludingWindows:[])` → `SCStream(filter:configuration:delegate:)`。
- 配置 `SCStreamConfiguration`：`minimumFrameInterval=kCMTimeZero`(原生刷新) 或目标 fps；`pixelFormat='420f'/'420v'`(NV12, 编码器直吃)；`width/height = points × pointPixelScale`；`queueDepth=3~5`；`showsCursor`。
- 帧：`stream:didOutputSampleBuffer:` 给 **IOSurface 背书的 CMSampleBuffer**，`SCStreamFrameInfoStatus==Complete` 才用。
- 若采集**本进程自己创建**的虚拟屏，可用 `getCurrentProcessShareableContent`(14.4+) **免 TCP 录屏弹窗**。`CGDisplayStream` 在 15.0 已**废除（不可编译）**，不要用。

### 3.3 macOS：硬件编码 `VideoToolbox`（公开，已确认）
- `VTCompressionSession`，把 SCK 的 `CVPixelBuffer` 直接喂 `VTCompressionSessionEncodeFrame`（IOSurface→零拷贝）。
- 低时延配方：`EnableLowLatencyRateControl=true`(11.3+) + `RealTime=true` + `AllowFrameReordering=false` + `MaxFrameDelayCount=0` + `PrioritizeEncodingSpeedOverQuality=true` + `AverageBitRate` + 短窗 `DataRateLimits`。
- 码流：用 `CMVideoFormatDescriptionGetHEVC/H264ParameterSetAtIndex` 取 **VPS/SPS/PPS**，转 Annex-B 后随每个 IDR 下发；丢包恢复用 `ForceKeyFrame` 或 LTR（`EnableLTR`）。
- 编码增加的时延约 ≤1 帧（60fps ~3–16ms）；端到端主要被网络/抖动缓冲决定——而我们走 USB，几乎无抖动。
- **H.264 vs HEVC**：Retina 高分辨率屏推荐 **HEVC**（省 30–50% 码率、文字更清晰），平板侧确认 HW HEVC 解码即可；先用 **H.264** 打通最稳。

### 3.4 macOS：输入注入
- **指针/键盘**：`CGEventCreateMouseEvent`(绝对坐标，跨屏统一坐标系，注意 AppKit 是左下原点需翻转 Y) / `CGEventCreateKeyboardEvent` → `CGEventPost(kCGHIDEventTap, e)`；需**辅助功能 TCC**（`AXIsProcessTrusted` / `CGPreflightPostEventAccess`）。
- **笔压力（分阶段）**：
  - 阶段法 A（便宜）：在合成鼠标事件上设 `kCGMouseEventSubtype=kCGEventMouseSubtypeTabletPoint` 再写 `kCGTabletEventPointPressure/TiltX/TiltY`。**公开 API 可注入压力**，但**专业 app 是否认账需逐个实测**。
  - 阶段法 B（稳）：**DriverKit/HIDDriverKit 虚拟 HID 数字化板**（usage page 0x0D），让系统自己产生真正的 `NSTabletPoint`，专业 app 原生识别压力。需 Apple 授予 `com.apple.developer.driverkit`，参考 `Karabiner-DriverKit-VirtualHIDDevice`（但它只有键鼠，**数字化板报告描述符要自己写**）。

### 3.5 传输层：`hdc fport`（TCP over USB）
- `hdc fport tcp:<macPort> tcp:<padPort>`（host→device，类比 `adb forward`）；`hdc fport ls` 查、`hdc fport rm` 删。仅需**平板开发者模式 + 首次授权**，**不需要 app 特殊签名**；但 hdc 只转发字节、**不会拉起 app**，app 必须先监听。
- ⚠️ **待真机复验**：当前 HarmonyOS 5.x 是否对"侧载第三方 app 的监听端口"放行 fport（Android 某些配置会限 debuggable）。
- 备选（不推荐为主路）：USB Accessory（`openAccessory`，需写 Mac 侧 libusb 主机驱动）；USB tether / `setCurrentFunctions` 是**系统 API，第三方 app 用不了（202）**。

### 3.6 鸿蒙：解码 + 渲染
- `OH_VideoDecoder_CreateByMime(AVC/HEVC)` → `RegisterCallback`(新 `OH_AVBuffer` 回调模型) → `Configure`(含 `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY=1`) → `SetSurface(从 XComponent 拿的 OHNativeWindow)` → `Prepare/Start`。
- 输入喂 **Annex-B NAL**，SPS/PPS(/VPS) 用 `CODEC_DATA` flag 先发、IDR 打 `SYNC_FRAME`。
- 渲染：`XComponent type:'surface'`，`OnSurfaceCreated` 拿 `OHNativeWindow*` 交给解码器；`OnNewOutputBuffer` 里 `RenderOutputBuffer(index)` 显示、`FreeOutputBuffer` 丢弃迟到帧（低时延关键）。
- C++ 模块的 `nm_modname` 必须等于 ArkTS `XComponent` 的 `libraryname`；通过 **Node-API(napi)** 与 ArkTS 通信。

### 3.7 鸿蒙：触控/笔输入采集
- 路径推荐：**`XComponent` + native `ui_input_event.h`**。`OH_ArkUI_UIInputEvent_GetToolType`(PEN=2) 区分笔；`OH_ArkUI_PointerEvent_GetPressure / GetTiltX/Y / GetRollAngle / GetX/Y`。
- **高频采样**：`onTouch` 每 vsync 才回调一次，必须用 **`OH_ArkUI_PointerEvent_GetHistory*`**（或 ArkTS `getHistoricalPoints()`）取帧间所有设备采样点，否则笔迹会"折线化"。
- 掌拒在 OS/驱动层做；app 侧策略：笔落下时忽略并发的手指点。可选 **Pen Kit**（`PointPredictor` 降低笔迹延迟、`InstantShapeGenerator`）——华为私有、需确认授权。

### 3.8 鸿蒙：网络
- `socket.constructTCPSocketServerInstance()` + `tcpServer.listen({address:'127.0.0.1', port:8888})`；仅 `ohos.permission.INTERNET`（normal/system_grant，自动授予）。
- 无线阶段：同样代码改 `listen('0.0.0.0', 8888)`，去掉 hdc，加 **mDNS（`net.mdns`）发现**或手动输 IP。

---

## 4. 传输抽象与有线/无线切换（L1 边界）

```
// 概念接口（两端各自语言实现，语义一致）
interface Transport {
  connect()/listen() -> Stream      // 单条 可靠/有序/双向 字节流（= 一个 TCP 连接）
  read(buf) -> n
  write(buf) -> n
  close()
  onClosed / onError 事件
}
```
- **有线**：`TcpTransport` 连 `127.0.0.1:P`，外部由 `hdc fport` 把 P 经 USB 隧道接到平板的监听端口。app 完全不知道底下是 USB。
- **无线**：同一个 `TcpTransport` 连 `<padIP>:P`（mDNS 发现），去掉 hdc。**L1 以上全部不变。**
- "发现/地址解析"放在 L1 **之上**：它只产出一个 `host:port` 交给 Transport。
- USB 隧道只能转 **TCP**（UDP/WebRTC 不走 hdc），所以**基线就用"单 TCP 连接 + 自定义分帧复用"**（scrcpy 模型）。仅当未来真实 Wi‑Fi 丢包导致 TCP 队头阻塞明显时，再把 **VIDEO 通道**单独搬到 UDP/QUIC/WebRTC（CONTROL/INPUT 仍留可靠通道）。

---

## 5. 线协议设计（双端共享定义）

- **分帧**：`[channelId: u8][flags: u8][length: u32-LE][payload]`。
- **逻辑通道**：`CONTROL=0`（握手/能力/时钟/心跳）、`VIDEO=1`、`INPUT=2`、`AUDIO=3`(预留)、`STATS=4`(预留)。
- **握手（CONTROL）**：协议版本 → 能力协商（编解码 H264/HEVC、分辨率梯度、fps、是否支持笔压、HiDPI 标量）→ NTP 式 3 段时钟同步（对齐 `mach_absolute_time` ↔ 鸿蒙单调钟，测端到端时延/驱动抖动缓冲）。
- **VIDEO**：`[ptsMonotonic][isKeyframe][codecConfig?]` + Annex-B NAL。新分辨率走 IDR + 新参数集。
- **INPUT**（平板→Mac）：统一事件模型（借鉴 Moonlight `LiSendPenEvent`）：
  `type(touchDown/Move/Up, keyDown/Up, scroll)`、`tool(finger/pen/eraser)`、归一化 `x,y`(相对虚拟屏)、`pressure[0,1]`、`tiltX/Y`、`rollAngle`、`buttons`、`tsMonotonic`。一个高频笔触可携带多个历史采样点。
- **背压/丢帧**：VIDEO 用"最新帧邮箱"（容量 1，新帧覆盖未发出的旧帧，编码器据此自适应降码率）；INPUT 用有界 FIFO（**绝不丢点击/按键**，鼠标移动可合并）；写线程独立，socket 写满不阻塞采集。

---

## 6. 数据流

**投屏（Mac→平板）**：CGVirtualDisplay 造屏 → SCK 采集 IOSurface 帧 → VideoToolbox 硬编 NAL → ChannelMux(VIDEO) → TCP(hdc/USB) → 平板 ChannelMux → OH_VideoDecoder → RenderOutputBuffer → XComponent 屏幕。

**输入（平板→Mac）**：XComponent 采集触控/笔（含 GetHistory* 高频点）→ 归一化坐标+压力 → ChannelMux(INPUT) → TCP → Mac → 映射到虚拟屏全局坐标 → CGEvent/DriverKit 注入。

---

## 7. 权限、签名与分发

| 端 | 事项 |
|---|---|
| macOS | 录屏 TCC（采集，可用 getCurrentProcessShareableContent 规避）；辅助功能 TCC（CGEvent 注入）；Developer ID 签名 + 硬化运行时 + 公证（个人自用可 `xattr -cr`）；私有 API → 不上架；DriverKit 走 `systemextensionsctl developer on` 本机调试，正式需申请 driverkit 权限 |
| HarmonyOS | 开发者模式 + USB 调试 + 首次 hdc 授权；`.hap` **强制签名**（DevEco 调试自动签名 + 注册测试设备）；`ohos.permission.INTERNET` 自动授予；Mac 需装 HarmonyOS Command Line Tools 以获得 `hdc` |

---

## 8. 工程骨架（建议目录）

```
superconnect/
├── docs/                      # 设计/协议/运维文档（本文件在此）
├── proto/                     # ★ 双端共享的线协议"单一事实源"
│   └── protocol.md            #   帧格式、通道、事件枚举（先文档化，后可codegen）
├── mac/                       # macOS 端 (Swift, SwiftPM/Xcode)
│   └── Sources/
│       ├── Transport/         # L0/L1: Transport 协议 + TcpTransport
│       ├── Session/           # L2: 握手/能力/时钟同步
│       ├── ChannelMux/        # L3: 分帧复用 + 背压
│       ├── Display/           # CGVirtualDisplay 封装 (+私有头)
│       ├── Capture/           # ScreenCaptureKit
│       ├── Encoder/           # VideoToolbox
│       ├── Input/             # CGEvent 注入 (+ 后续 DriverKit 扩展)
│       └── App/               # L5 UI/生命周期/设置
├── harmony/                   # 平板端 (.hap, DevEco 工程)
│   ├── entry/src/main/ets/    # ArkTS: UI/Session/连接管理
│   └── entry/src/main/cpp/    # C++ NDK: Transport/Mux/Decoder/Render/Input(napi+XComponent)
├── tools/                     # Mac 侧脚本：装/校验 hdc、起 fport、拉起两端
└── README.md
```
设计原则：`proto/` 是协议**唯一事实源**；`Transport` 是唯一知道"USB vs Wi‑Fi"的地方；每层只依赖下层接口、不依赖实现。

---

## 9. 分阶段路线图

- **Phase 0 — 骨架**：建目录、`proto/protocol.md`、两端 Transport+Mux 空实现 + 回环自测；`tools/` 脚本（装 hdc、`hdc fport`、连通性 ping）。
- **Phase 1 — 有线投屏 MVP**：CGVirtualDisplay 造屏 → SCK → VideoToolbox(H.264) → hdc/USB → OH_VideoDecoder → XComponent 显示。**先验证"虚拟屏能被 SCK 枚举""hdc fport 能到侧载 app"两个高风险点。**
- **Phase 2 — 触控 + 基础笔**：平板采集触控/笔 → INPUT 通道 → Mac CGEvent 注入（指针/点击/拖拽 + 笔走光标）。
- **Phase 3 — 笔记/压感**：GetHistory* 高频笔迹；压感先走 CGEvent tablet 子类型，按需上 DriverKit 虚拟 HID；HEVC + 低时延调优；HiDPI。
- **Phase 4 — 内网无线**：mDNS 发现 + TcpTransport 连 LAN + CONTROL 加密握手（Noise/TLS）；按需把 VIDEO 搬 UDP/QUIC。
- **Phase 5 — 打磨**：重连、能力协商、设置 UI、安全退出、自适应码率、（可选）音频/剪贴板。

---

## 10. 风险与待验证项（本次研究的核验结论）

| 项 | 结论 | 行动 |
|---|---|---|
| SCK 按 displayID 采集 + 喂 VideoToolbox | ✅ **已确认**（对 26.4 SDK 头文件核验，高可信） | 直接采用 |
| CGVirtualDisplay 在 26.5 运行期造出可被 SCK 枚举的扩展屏 | ⚠️ 私有 API，架构成立但**运行期未复验** | Phase 1 真机最先验证；备选：先做"镜像现有屏" |
| `hdc fport` 能到侧载第三方 app 监听端口 | ⚠️ **未联网核验**（强先验为可行） | Phase 0/1 真机验证；备选：USB Accessory |
| 平板是 HarmonyOS NEXT（纯鸿蒙、无 APK） | ⚠️ 强证据（HDC/HiSilicon），但并非所有 MatePad 都是 NEXT | 真机看"设置→关于"确认型号/版本 |
| 笔压力注入任意 Mac 专业 app | ⚠️ CGEvent 可注入压力但**专业 app 未必认账**；稳路是 **DriverKit 虚拟 HID**（需申请权限，周期长） | 早提交 driverkit 权限申请；先实测 CGEvent 子类型 |

---

## 11. 参考资料（精选）

- DeskPad（CGVirtualDisplay 范例）: https://github.com/Stengo/DeskPad
- VirtualDisplayKit（SPM 封装）: https://github.com/xocialize/VirtualDisplayKit
- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Apple VideoToolbox / WWDC21 低时延编码: https://developer.apple.com/videos/play/wwdc2021/10158/
- Karabiner DriverKit 虚拟 HID（虚拟设备范例）: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
- scrcpy（USB/adb 隧道 + 输入注入 参考架构）: https://github.com/Genymobile/scrcpy
- Moonlight 协议（开放的笔/触控 wire 格式 `LiSendPenEvent`）: https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h
- HarmonyOS hdc（fport/rport）: https://developer.huawei.com/consumer/en/doc/harmonyos-guides/hdc
- OpenHarmony 视频解码 OH_VideoDecoder: https://gitee.com/openharmony/docs/blob/master/en/application-dev/media/avcodec/video-decoding.md
- OpenHarmony XComponent/NativeWindow: https://gitee.com/openharmony/docs/raw/master/en/application-dev/ui/napi-xcomponent-guidelines.md
- OpenHarmony 触控/笔事件（ui_input_event / GetHistory*）: https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/capi-ui-input-event-h.md
- OpenHarmony net.socket（TCPSocketServer）: https://gitee.com/openharmony/docs/blob/master/en/application-dev/reference/apis-network-kit/js-apis-socket.md
- Astropad LIQUID（压感/低时延 商用参考）: https://astropad.com/blog/liquid-technology/
```
