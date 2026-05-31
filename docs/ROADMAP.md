# Superconnect — 路线图与待办（Roadmap & TODO）

> 状态快照见 **[`PROJECT-STATUS.md`](PROJECT-STATUS.md)**；架构契约见 **[`ARCHITECTURE.md`](ARCHITECTURE.md)**。
> 本文是**前瞻视图**：已完成的能力、明确的待办、以及每项待办的根因/设计建议。
> 更新于 2026-05-31。

图例：✅ 已完成并真机验证 · 🔧 待办（含优先级 P1/P2/P3） · 🧭 方向（多设备长期目标）

---

## 1. 已完成（✅ Finished）

| 能力 | 说明 |
|---|---|
| 有线投屏 | `CGVirtualDisplay` → `ScreenCaptureKit` → `VideoToolbox(HEVC/H.264)` → 平板 `OH_VideoDecoder` → `XComponent`，经 `hdc fport`(TCP over USB) |
| 120Hz / HEVC / 能力协商 | 由平板 `hello_ack` 上报 caps，Mac 据此适配分辨率/刷新率/编解码，换机型无需改 Mac 代码 |
| **物理键盘 + 虚拟键盘** | 快捷键/具名键 `onKeyPreIme` 预 IME 消费并以原始键回传；可打印 + 中文 IME 合成走 `onChange` 提交为 Unicode 文本。**两者均正常，本项收尾。** |
| 手写笔压感（M-Pencil） | ArkUI `TouchEvent`(sourceTool=Pen) + `pressure/tilt` + `getHistoricalPoints`，Mac 侧 `CGEvent` tablet 子类型 + proximity 包裹。跨应用真压感，无需 DriverKit |
| 触控板光标/单击/右键/滚动/捏合缩放/拖锁 | 见已知问题（仍有缺陷，列为 P2） |
| Mac 端窗口式 GUI（MVVM） | 独立窗口设备仪表盘（侧栏设备 + 右侧详情/连接/权限）+ 菜单栏快捷入口；自动检测、有线/无线标识，预留对称多设备接口 |
| 平板端代码仓库可维护性升级 | 单体 `Index.ets`(740→210) 拆分；与 Mac 镜像的分层（Models/Services/Connection/Role/Engine/Discovery + `AppEnvironment` 组合根 + 统一 `ConnectionStatus`）；输入/UI/协议分层 |
| 统一应用图标 | 星座/GH 图标（仅存在于 DevEco 工程，仓库待补，见 §4） |

---

## 2. 待办（🔧 TODO，按优先级）

### ✅ 已完成（v0）— 静止画面画质（曾因缓存帧发糊）
**状态**：已修复（commit `eefcc06`）。空闲心跳改为重发 **P 帧**（编码器细化并保持静止画面），关键帧只在最后一次真实帧后 ~2s 的同步窗内强制（`Producer.swift` `lastRealFrameNs`/`idleSyncWindowNs`）。下方为历史根因分析，保留备查。

**现象**：屏幕很久没动后，画面变软/发糊（"缓存帧导致画质下降"）。

**根因（已定位）**：编码器用 `kVTCompressionPropertyKey_AverageBitRate` + `ExpectedFrameRate = fps`（`mac/Sources/SuperconnectProducer/VideoEncoder.swift:75-76`），ABR 速率控制把每帧预算约束为 `码率 ÷ fps`（50Mbps/60fps ≈ 104KB/帧）。空闲时心跳每 ~0.8s 强制重发一个**关键帧**（`Producer.swift:58-64`，`allowSkipKeyframe:false`），但每个关键帧仍被钉在"按 60fps 计的单帧预算"内 —— 一个整帧 intra 远不够用，于是被高度量化，**静止画面被一帧帧更软的关键帧替换**，越放越糊。

**修复方案（下一轮实现，本轮仅记录）**：
1. **（推荐）停止/退避空闲重发，关键帧改为事件驱动**：TCP 无丢包且解码器会保留上一帧，静止画面一旦正确显示就无需重编。把盲目的 0.8s 关键帧重发改为：①新客户端接入（late-join）时发关键帧；②解码器报损（拖影恢复）时按需发；③画面真正变化时发。可保留一个极低频（3–5s）安全关键帧兜底。既消除劣化又省带宽。
2. **空闲关键帧提质**：发空闲/静止关键帧时临时提高质量 —— 设高 `kVTCompressionPropertyKey_Quality`，或对该帧临时上调 `AverageBitRate`/放宽 `DataRateLimits`。静止帧本身压得很小，代价低。
3. **改用质量优先速率控制**：加 `DataRateLimits`（给足窗口）或转 CRF 类模式，使孤立关键帧不被 60fps 单帧预算钳制。

> 建议：方案 1 直击症状且顺带省流，必要时叠加方案 2（对真正发出的那一帧）。

### ✅ 已完成（v0）— 平板端：小窗启动 + 双击进全屏 + 通知栏退出
**状态**：已实现（commit `4c7df70`）。`DisplayMode{Windowed,Fullscreen}` 状态机：连接后小窗预览（不转发输入）→ 双击进沉浸全屏（输入转发 + 发"退出全屏"通知，含控制面板兜底）。下方为原始需求，保留备查。
**需求**：连数据线、Mac 确认后**不要**立刻进全屏；先在**应用内小窗**显示画面；用户**双击**后进全屏；进全屏后利用**通知栏**，用户可在通知栏点击**退出全屏**。

**动机**：面向多设备 —— 将来可能同时管理多路投屏/多窗口，自动全屏过于武断。

**设计建议（下一轮实现）**：
- **小窗（windowed）**：连接后不调用 `setWindowLayoutFullScreen(true)`；XComponent 渲染在一个定比例（如 16:10）的居中容器里，周围保留状态/控制 UI。
- **双击进全屏**：在视频区加双击手势 → 切换沉浸式全屏（`setWindowLayoutFullScreen(true)` + 隐藏系统栏 + XComponent 撑满）。注意与触控板/触控的双击语义区分（仅在"小窗态"的视频空白区生效，或用专门的进全屏按钮兜底）。
- **通知栏退出**：用 `@ohos.notificationManager` 发布带操作按钮的常驻通知，按钮经 `WantAgent` 触发 `EntryAbility` 的退出全屏动作（回到小窗态）。进全屏时发布、退全屏时取消。
- **状态机**：`windowed ⇄ fullscreen`，与现有 `ConnectionStatus` 正交；可放在平板 `models/` 下作为一个 `DisplayMode` 模型 + UI 层消费。

### P2 — 触控板（trackpad）仍有问题
当前移动/单击/右键/滚动/捏合/双击拖锁已接通，但实际使用仍有缺陷（手感/边界/丢事件）。**用户明确：列为 to-do，非当前重点。** 待复现并系统化修复（建议补 SCDIAG 轨迹再定位）。

### P2 — 触控：部分功能未实现
触控总体很好，但并非全部功能可用，例如**双击应用侧边栏让应用全屏**未实现。需要梳理触控可达的系统手势集合，补齐缺口（可能与 P1 的小窗/全屏状态机一并设计）。

### P3 — 收尾项
- 悬浮球响应区为 56×56 方形（可改纯圆形），低优先级。
- 压感曲线偏窄（约 0.07–0.58），如需更强轻重对比可加 gamma 拉伸（当前手感够用）。

---

## 3. 多设备方向（🧭 长期）

目标：**任意设备均可作为主设备投屏，或作为从设备被投屏**（对称角色）。架构已为此预留：

- **角色接缝**：`ConnectionEngine` + `Role`（Receiver/Host）。Mac 与平板均已是 `HostConnection`/`ReceiverConnection` 一真一桩，启用对称未来 = 改 `AppEnvironment.engineForRole` 一行 + 实现对应桩。
- **Layer A（近期）**：每会话一条连接、以 `peerId` 索引，零线协议改动即可多设备并存。
- **Layer B（远期）**：`sessionId` 复用单连接，延后。

待办协议阶段（见 `ARCHITECTURE.md` 的演进策略）：
- **Phase 2**：协议一致性测试台（golden vectors 跨 Swift/ArkTS/C++ 校验自动化）。
- **Phase 5**：向后兼容的 v2 握手（`peerId` + host/receiver 角色协商 + 能力位 + 保留字段）。
- **Phase 6**：多会话注册表（Layer A）。
- Phase 7–9（延后）：Mac 作接收端、平板作主机端、1→N 协调器。

---

## 4. 开源前置（仓库就绪性，🔧 P1）

- **HarmonyOS 工程可构建性**：✅ 已完成（2026-05-31）。`harmony/` 现为**完整的 DevEco 工程**（脚手架 `build-profile.json5`/`hvigorfile.ts`/`oh-package.json5`/`hvigor/` + `media/` 星座图标 + `entrybackupability` 全部就位），可直接 `ohpm install` + 构建。**签名已清空**（`signingConfigs: []`，不含证书/密钥/口令），克隆者用 DevEco 自动签名。bundle 为 `com.superconnect.pad`。
  - **建议**：把 DevEco 工程的脚手架与 `resources/.../media/`（含星座图标 `background/foreground/layered_image`）同步进仓库，排除 `oh_modules/`、`build/`、签名材料，使开源仓库可直接 `ohpm install` + 构建。
- **许可证**：尚未选择（MIT / Apache-2.0 / …），开源前需补 `LICENSE`。
- **安全**：仓库已确认不含任何测试账号/签名私钥；`.gitignore` 已排除签名材料与构建产物。
