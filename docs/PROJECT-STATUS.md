# Superconnect — 工作总结(截至 2026-05-31)

把华为 MatePad Pro 13.2 当作 macOS 的**有线扩展屏**:投屏 + 触控 + M-Pencil 压感笔记。
传输走 USB(`hdc fport` 的 TCP),为将来无线(局域网)预留了同一套传输接口。

> 前瞻视图（已完成 / 待办 / 多设备方向）见 **[`ROADMAP.md`](ROADMAP.md)**；架构契约见 **[`ARCHITECTURE.md`](ARCHITECTURE.md)**。

---

## 1. 当前可用状态(均已在真机验证 ✅)

| 能力 | 状态 | 说明 |
|---|---|---|
| 扩展屏投屏 | ✅ | 私有 `CGVirtualDisplay` → `ScreenCaptureKit` → `VideoToolbox` 编码 → 平板 `OH_VideoDecoder` 解码 → `XComponent` 渲染 |
| **120Hz** | ✅ | 由平板上报的刷新率协商得到;`macOS mode reports 120Hz` 已确认是真 120Hz |
| **HEVC(自动检测)** | ✅ | 平板硬件支持则用 HEVC,否则自动降级 H.264;编码器对编解码器无关、易扩展(将来可加 AV1) |
| 清晰度 | ✅ | 50 Mbps + 偏向质量(`PrioritizeEncodingSpeedOverQuality=false`),HiDPI 2880×1920 |
| 拖影修复 | ✅ | 解码器积压时"丢到下一个关键帧"(TCP 无丢包,真正诱因是积压而非丢包)+ 1s 关键帧间隔 |
| 全屏 | ✅ | `setWindowLayoutFullScreen(true)` + 隐藏系统栏 |
| 设置里显示刷新率 | ✅ | 虚拟屏列出 120/60 两档模式 + `forceMode` 钉到原生率,System Settings 才会显示刷新率选择器 |
| **手指触控(类 iPad 触控板)** | ✅ | 见第 3 节 |
| **悬浮球切换模式** | ✅ | 应用内可拖动悬浮球,点按切换桌面/绘画模式,边缘吸附 |
| **M-Pencil 压感** | ✅ | 见第 4 节(关键:tablet **proximity** 事件) |
| 防误触 | ✅ | 笔接触期间(+抬笔 0.6s 内)屏蔽手指 |

---

## 2. 架构总览

```
华为平板 (HarmonyOS, ArkTS + C++ NDK)            Mac (Swift, SwiftPM)
┌─────────────────────────────────┐            ┌──────────────────────────────────┐
│ TcpServerTransport (TCP server)  │◀── USB ───▶│ TcpTransport (TCP client)         │
│   127.0.0.1:8888                 │ hdc fport  │   经 hdc fport 反向到平板          │
│ Session (CONTROL: hello/ping)    │            │ Session                           │
│   hello_ack 上报 caps ───────────┼──协商─────▶│ 按 caps 适配:分辨率/刷新率/编解码 │
│ VIDEO → OH_VideoDecoder → 渲染   │◀──VIDEO────│ CGVirtualDisplay+SCK+VideoToolbox │
│ 触控/笔 → GestureController/笔   │──INPUT────▶│ InputInjector → CGEvent           │
└─────────────────────────────────┘            └──────────────────────────────────┘
```

- **协议**:帧 `channel:u8 | flags:u8 | length:u32-LE | payload`;通道 CONTROL/VIDEO/INPUT。
  INPUT 为固定 **44 字节**小端记录(type/tool/buttons/flags/timestamp/x/y/pressure/tiltX/tiltY/scrollX/scrollY/...)。
- **能力协商 = 适配其他平板的接口**:`hello_ack` 的 caps 里带 `{screenWidth,screenHeight,scale,refreshRate,codecs,pen}`,Mac 据此适配。换一台平板无需改 Mac 代码。

---

## 3. 触控手势(状态机 + 两种模式)

全部手指消歧逻辑在**平板侧** `GestureController`(状态机),Mac 只做"几乎无状态"的执行器。

**消歧 = 延迟提交(defer-then-commit)**:第一根手指落下只先发"无按键的光标移动",真正的左键按下**延迟 70ms**,以便第二根手指能把手势升级为双指手势(右键/滚动)而**绝不误触发左键**;移动超过阈值则提前提交(拖动不卡顿)。

| 手势 | 桌面模式 `↖` | 绘画模式 `✎` |
|---|---|---|
| 单指轻点 | 左键单击 | 左键单击(用于点工具栏/选颜色) |
| 单指拖动 | **按住左键拖**(拖窗口/框选) | **只移动光标,不按键 → 不画墨** |
| 双指轻点 | 右键 | 右键 |
| 双指滑动 | 滚动(自然方向) | 滚动 |
| 手写笔 | 画(带压感) | 画(带压感) |

- **悬浮球**:应用内 56vp 圆球(最上层 `zIndex`,不抢画布触摸),点按切换 `isDrawingMode`,可拖动 + 边缘吸附。无需系统悬浮窗权限。
- **核心理念**:**笔负责画,手指负责操作界面**(类 iPad + Apple Pencil)。

---

## 4. M-Pencil 压感(免费方案,未用 DriverKit)

- **采集(平板)**:用 ArkUI 标准 `TouchEvent` —— `sourceTool===Pen` 判断笔,`TouchObject.pressure`(0~1)取压感,`tiltX/tiltY` 取倾斜,`getHistoricalPoints()` 补采样;笔锁定到自己的 `contact id`,历史采样按 id 过滤,**手指绝不污染笔迹**。这就是 HarmonyOS 上报 M-Pencil 压感的官方通道(没有、也不需要单独的"压感笔 SDK")。
- **注入(Mac)**:`CGEvent` 数位板指针子类型 + `tabletEventPointPressure/Tilt`。
- **关键修复**:每笔用 **tablet PROXIMITY(笔进入/离开感应区)事件**包裹,并声明 `pointerType=pen` + 设备 ID。**这是之前压感失效的真正原因** —— 应用要先收到 proximity 才进入"手写笔模式"去读压力,否则把事件当普通鼠标。加上后 Notability 线条**随力度变粗细已确认生效**。
- **结论**:跨应用真压感**已实现,免费、无需 DriverKit、无需付费 Apple 账号**。DriverKit 路线因此**搁置**(不需要了)。

---

## 5. 关键文件

**Mac(`mac/Sources/`)**
- `SuperconnectProducer/VirtualDisplay.swift` —— 虚拟屏(HiDPI、多刷新率模式、`forceMode`、`currentRefreshRate`)
- `SuperconnectProducer/Producer.swift` —— 采集+编码循环、周期关键帧、空闲心跳
- `SuperconnectProducer/VideoEncoder.swift` —— `VideoCodec` 抽象(h264/hevc)、低延迟、参数集→Annex-B
- `SuperconnectProducer/InputInjector.swift` —— 笔(proximity+压感)/手指(左/右键、滚动)注入
- `superconnect-mac/main.swift` —— CLI、握手、`displayConfigFromCaps`/`codecFromCaps`、输入日志
- `SuperconnectCore/` —— `FrameCodec` / `InputCodec`(44 字节) / `Session` / `TcpTransport`

**平板(`harmony/entry/src/main/`)**
- `ets/pages/Index.ets` —— XComponent + 透明触摸层 + 路由(笔/手指)+ 防误触 + 悬浮球挂载
- `ets/input/GestureController.ets` —— 手指手势状态机(本次新增)
- `ets/components/FloatingBall.ets` —— 悬浮球(本次新增)
- `ets/session/Session.ets` —— CONTROL 握手 + caps 上报(分辨率/刷新率/HEVC)
- `ets/transport/TcpServerTransport.ets` —— TCP 服务端
- `cpp/video_decoder.{h,cpp}` —— `OH_VideoDecoder`(surface 模式)+ 丢到关键帧
- `cpp/napi_init.cpp` —— native 模块(supportsHevc/setCodec/pushVideo/setVideoSize/XComponent)

---

## 6. 构建与运行

**Mac host**
```bash
cd mac && swift build
# 常驻自愈循环(USB 抖动自动重连):
zsh /tmp/sc-loop.sh        # 内部: ./.build/.../superconnect-mac --produce
```

**平板 HAP(DevEco 工程在 ~/DevEcoStudioProjects/superconnect,源码与仓库 harmony/ 同步)**
```bash
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH=$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --no-daemon \
  assembleHap -p product=default -p buildMode=debug
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" fport tcp:8888 tcp:8888
"$HDC" shell aa start -a EntryAbility -b com.superconnect.pad
```
> 注意:平板需**解锁 + 应用在前台**(应用本身就是 Mac 的屏幕);USB-HDC 接口偶尔会掉,重插数据线即可,host 循环会自动重连。

---

## 7. 可调参数(on-device tuning)

| 参数 | 位置 | 当前值 | 作用 |
|---|---|---|---|
| `scrollGain` | InputInjector.swift | 2.5 | 双指滚动速度;滚动方向已设为自然(取负),想要经典方向翻一行符号即可 |
| `PALM_GRACE_MS` | Index.ets | 600 | 绘画模式下抬笔后继续屏蔽手指的时长(防手掌) |
| `TWO_WIN_MS` | GestureController.ets | 70 | 单指按下延迟(用于识别第二根手指) |
| `MOVE_GATE/TAP_SLOP/...` | GestureController.ets | 8/8/250… | 拖动/轻点/双指点击的距离与时间阈值 |
| `--bitrate` / `--maxfps` | main.swift | 50Mbps / 120 | 码率与帧率上限 |

---

## 8. 已知限制 / 后续

- **悬浮球响应区是 56×56 方形**(可见圆形四角外一点点也会响应);靠边停靠时影响很小,低优先级,需要可改成纯圆形。
- **压感曲线**:M-Pencil 经 ArkUI 的压感值偏窄(日志约 0.07~0.58),如需更强的轻↔重对比可加一条 gamma 拉伸(已确认目前手感够用,暂不做)。
- **无线(Phase 4)**:传输层已抽象,改 `0.0.0.0` 监听 + mDNS 发现即可走局域网,代码主体复用。
- **DriverKit 真数位板**:已搁置——proximity 方案已让压感跨应用生效,无需付费账号;若将来要做专业级(更高精度/被所有 pro app 原生识别),仍可走 DriverKit(需付费 Apple 账号 + entitlement 审批),设计见 `docs/PRESSURE-DRIVERKIT.md`。

---

## 9. 本阶段(2026-05-30)做了什么

1. **120Hz + HEVC + 能力协商 + 拖影修复** —— 投屏更顺更清,且为商用多机型预留适配接口。
2. **System Settings 刷新率显示修复** —— 多模式 + 钉模式。
3. **Phase 3 触控系统** —— 经"设计评审 + 对抗式代码审查"两轮多智能体打磨后实现:手势状态机、悬浮球、桌面/绘画双模式、双指滚动/右键。
4. **笔/手指彻底分离 + 智能防误触** —— 笔锁定 contact id、手指按 proximity/grace 屏蔽,绘画模式手指不出墨、仅操作 UI。
5. **压感跨应用生效(免费)** —— 定位到 proximity 事件缺失这一根因并修复。

---

## 10. 本阶段(2026-05-31)做了什么 —— 可维护性升级 + GUI + 现状梳理

1. **Mac 端窗口式 GUI(MVVM)** —— 独立窗口设备仪表盘(侧栏设备 + 右侧详情/连接/权限) + 菜单栏快捷入口;设备为中心、自动检测、右下角有线/无线标识,UI 与逻辑分离,预留对称多设备接口。
2. **平板端代码仓库可维护性升级** —— 单体 `Index.ets`(740→210 行)拆分,建立与 Mac **镜像的分层**:`models/`(Role/ConnectionStatus/StreamInfo/Peer)、`services/`(ConnectionManager)、`services/connection/`(ConnectionEngine + TunnelService + role/{Receiver,Host}Connection)、`services/discovery/`、`input/`、`ui/`、`protocol/`、`session/`、`transport/`,加 `app/AppEnvironment` 组合根。
3. **角色接缝(对称多设备前置)** —— `ConnectionEngine` 接口 + `Role`(Receiver/Host)。平板 `ReceiverConnection` 为真实角色、`HostConnection` 为桩(与 Mac 一真一桩对称镜像)。启用"平板投出"对称未来 = 改 `AppEnvironment.engineForRole` 一行。
4. **统一状态模型** —— 页面改用 `ConnectionStatus` 枚举(替代裸字符串),空闲界面显示干净文案(等待 Mac 连接 / 已连接)。
5. **HDR 调研与决策** —— 完整建好 HDR 编/采/解链路(平板已验证可解 10-bit),但**私有 `CGVirtualDisplay` 无法让系统报告 EDR>1.0**,虚拟屏 HDR 暂不可行 → **接受 SDR**,HDR 代码保留并在协商处关闭。
6. **统一应用图标** —— 星座/GH 图标(仅存在于 DevEco 工程,仓库待补,见 ROADMAP §4)。
7. **现状梳理(本轮无代码改动)** —— 物理/虚拟键盘**收尾**;触控板仍有缺陷(P2);触控部分功能未实现如双击侧边栏进全屏(P2);**定位"静止画面缓存帧导致画质下降"根因**(ABR + ExpectedFrameRate 钳制空闲关键帧预算)并给出修复方案(P1,见 ROADMAP §2);记录"小窗启动 + 双击进全屏 + 通知栏退出"新需求(P1)。
8. **开源就绪** —— `git init` + `.gitignore`(排除构建产物/签名/`oh_modules`/会话数据);确认仓库不含测试账号或私钥;待补 `LICENSE` 与 harmony 工程脚手架(见 ROADMAP §4)。
