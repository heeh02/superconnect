# Superconnect

把华为平板变成 macOS 的一块**扩展屏**：投屏 + 触控 + M-Pencil 手写笔 + 键盘。
当前为**有线**（USB）连接，传输层已抽象、为局域网**无线**预留同一套接口；架构按**对称多设备**（任意设备可作主机投出或作从机被投）长期演进。

> 📊 现状快照 → **[`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)** · 🗺 路线图与待办 → **[`docs/ROADMAP.md`](docs/ROADMAP.md)** · 🏛 架构契约 → **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** · 🔌 线协议 → **[`proto/protocol.md`](proto/protocol.md)** · 🔬 调研 → **[`docs/DESIGN.md`](docs/DESIGN.md)**

## 一句话原理
有线 = **`hdc fport`（TCP over USB）** + 平板内 `TCPSocketServer`；同一套 TCP/协议代码将来直接用于局域网 Wi-Fi——只换"连谁"。
投屏链路：Mac `CGVirtualDisplay` 造扩展屏 → `ScreenCaptureKit` 采集 → `VideoToolbox` 硬编(HEVC/H.264) → 平板 `OH_VideoDecoder` 解码 → `XComponent` 渲染；输入链路反向回注（`CGEvent`，含笔压感）。

## 能力一览
| 能力 | 状态 |
|---|---|
| 有线扩展屏投屏（120Hz / HEVC / 能力协商 / HiDPI） | ✅ 真机验证 |
| 物理键盘 + 虚拟键盘（含中文 IME） | ✅ |
| M-Pencil 压感手写（跨应用，无需 DriverKit） | ✅ |
| 触控板：光标/单击/右键/滚动/捏合/拖锁 | ✅ 已接通（仍有缺陷，见路线图 P2） |
| 手指触控（类 iPad 触控板 + 双模式 + 悬浮球） | ✅ |
| Mac 菜单栏 GUI（设备为中心，自动检测，有线/无线标识） | ✅ |
| 静止画面缓存帧画质下降 | 🔧 已定位根因，待修（路线图 P1） |
| 小窗启动 + 双击进全屏 + 通知栏退出 | 🔧 已设计，待实现（路线图 P1） |
| 对称多设备（任意设备主/从） | 🧭 架构已预留接缝（Role/ConnectionEngine） |

## 架构总览
```
华为平板 (HarmonyOS, ArkTS + C++ NDK)            Mac (Swift, SwiftPM)
┌─────────────────────────────────┐            ┌──────────────────────────────────┐
│ TcpServerTransport (TCP server)  │◀── USB ───▶│ TcpTransport (TCP client)         │
│   127.0.0.1:8888                 │ hdc fport  │                                   │
│ Session (CONTROL: hello/ping)    │            │ Session                           │
│   hello_ack 上报 caps ───────────┼──协商─────▶│ 按 caps 适配:分辨率/刷新率/编解码 │
│ VIDEO → OH_VideoDecoder → 渲染   │◀──VIDEO────│ CGVirtualDisplay+SCK+VideoToolbox │
│ 键盘/触控/笔 → InputRouter ──────┼──INPUT────▶│ InputInjector → CGEvent           │
└─────────────────────────────────┘            └──────────────────────────────────┘
```
两端按相同分层组织、**互为镜像**：`models / services(connection·role·discovery) / input / ui / protocol / session / transport`，并各有一个 `AppEnvironment` 组合根选择角色（Receiver/Host）。详见 **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**。

## 仓库结构
```
superconnect/
├── docs/                 # ARCHITECTURE(契约) · ROADMAP · PROJECT-STATUS · DESIGN · ...
├── proto/                # ★ 线协议唯一事实源：protocol.md + vectors.json(黄金向量)
├── mac/                  # macOS 端 (Swift, SwiftPM)
│   ├── Sources/SuperconnectCore/      # FrameCodec / InputCodec / Transport / Session
│   ├── Sources/SuperconnectProducer/  # VirtualDisplay / ScreenCapture / VideoEncoder / Producer / InputInjector
│   ├── Sources/superconnect-app/      # 菜单栏 GUI（MVVM：App/Models/Services/ViewModels/Views）
│   ├── Sources/superconnect-mac/      # 生产端 CLI（造屏→采集→编码→推流→收 INPUT）
│   ├── Sources/superconnect-probe/    # 探针（造屏/采集/编码/HDR dump 诊断）
│   └── Tests/                         # 断言 proto/vectors.json
├── shared/cpp/           # 可移植 C++ 帧编解码（鸿蒙 NDK 复用）+ 主机测试
├── harmony/              # 平板端源码 (ArkTS + cpp/)  ⚠ 见下方"构建说明"
└── tools/                # check-device / fport / dev-up / preflight / grant-permissions
```

## 构建与运行

### 本机即可验证（无需平板）
```bash
cd mac && swift test                    # 协议 + INPUT 黄金向量（跨语言一致性）
cd ../shared/cpp/tests && make test     # C++ 实现与 Swift 逐字节一致
```

### Mac 生产端
```bash
cd mac && swift build
swift run superconnect-mac --produce    # 造扩展屏→采集→编码→推流→收 INPUT 注入
# 或常驻自愈循环（USB 抖动自动重连）：zsh tools/sc-loop.sh
```
权限：投屏需"屏幕录制"、输入注入需"辅助功能"（系统设置 → 隐私与安全性，授予运行的终端）。`tools/grant-permissions.sh` 可引导授予。

### 平板 HAP（HarmonyOS）
> ⚠ **构建说明**：仓库 `harmony/` 是**源码快照**，当前**不含 DevEco 工程脚手架与图标资源**（详见 [`docs/ROADMAP.md`](docs/ROADMAP.md) §4）。真机构建请在 **DevEco Studio** 用"Native C++ 模板"建壳工程，放入 `harmony/` 源码后构建。端到端步骤见 **[`docs/ONDEVICE.md`](docs/ONDEVICE.md)**。

```bash
# DevEco 工程构建/部署（示例）：
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
hvigorw --no-daemon assembleHap -p product=default -p buildMode=debug
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc fport tcp:8888 tcp:8888
hdc shell aa start -a EntryAbility -b <bundleName>
```
> 平板需**解锁 + 应用在前台**（应用本身就是 Mac 的屏幕）；USB-HDC 接口偶尔会掉，重插数据线即可，host 循环会自动重连。

## 目标环境（实测）
macOS 26.5 / Apple Silicon；华为 MatePad Pro 13.2 / HarmonyOS NEXT（USB 枚举为 HiSilicon "HDC Device"，开发者模式已开）。

## 许可证
[MIT](LICENSE)。

## 安全
本仓库不含任何账号凭据或签名私钥；`.gitignore` 已排除签名材料与构建产物。
