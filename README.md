# Superconnect

把**华为平板**变成 **Mac 的一块扩展屏**：用数据线连上，平板就成了 Mac 的第二块显示器，支持**触控、M-Pencil 手写笔、键盘**。

> 当前为**有线（USB）**连接的开发者预览版。平板可作为 Mac 副屏使用；屏幕旋转、手写、键盘、触控手势均已可用。

> 🧭 **接手/上手开发者请先读 [`docs/HANDOFF.md`](docs/HANDOFF.md)** — 项目全貌、先看哪些文档、已完成/进行中/已知问题/待办、构建部署与操作注意事项。

---

## 它能做什么

- 🖥 **扩展屏**：平板显示 Mac 的桌面（不是镜像，是真正多出来的一块屏），最高 120Hz、HiDPI 清晰显示。
- ✍️ **M-Pencil 手写**：带压感，在任意 Mac 应用里书写/绘图。
- 👆 **触控操作**：像触控板一样——单击、拖动、双击（标题栏双击填满窗口）、双指右键、双指滚动、双指捏合缩放。
- ⌨️ **键盘**：平板的物理键盘 / 虚拟键盘直接给 Mac 打字，**支持中文输入法**。
- 🔄 **跟随旋转**：转动平板，Mac 这块副屏会自动切换横屏 / 竖屏比例。

---

## 你需要准备

| | 要求 |
|---|---|
| Mac | macOS 14 及以上，**Apple Silicon 或 Intel**（通用二进制）。实测 macOS 26.5 / Apple Silicon。 |
| 平板 | 华为平板，**HarmonyOS NEXT（API 12+）**，**已开启开发者模式**；需支持硬件 H.264/HEVC 解码（分辨率/刷新率/编码由握手能力协商，换机型免改代码）。实测 MatePad Pro 13.2；**并非所有机型都验证过**，M-Pencil 压感还取决于具体机型/系统。 |
| 数据线 | 一根能传数据的 USB-C 线（连接 Mac 与平板）。 |
| 软件 | **Apple Silicon 上 Mac 端无需任何额外软件**——应用已内置连接所需的 `hdc`。**Intel Mac**：应用可运行，但内置 `hdc` 为 arm64，无法在 Intel 上执行，需另装系统 `hdc`（DevEco Studio 或 HarmonyOS 命令行工具，Intel 版）。（自行构建平板端 App 才需要 DevEco Studio。） |

> 安装分两端：**Mac 端**从 Releases 下载安装包（已内置 `hdc`，开箱即用）；**平板端**走应用市场（上架审核中）或用 DevEco 自行构建。

---

## 安装

### Mac 端（下载安装包）

1. 到 **[Releases](https://github.com/heeh02/superconnect/releases)** 下载最新的 **`Superconnect.dmg`**。
2. 打开 dmg，把 **Superconnect** 拖进 **应用程序（Applications）**。
3. **首次打开**：在「应用程序」里**右键 Superconnect → 打开**，再点一次**打开**即可。
   - 应用是自签名、未经 Apple 公证，所以系统会拦一次；之后就能直接双击打开。
   - 也可终端一行解除拦截：`xattr -dr com.apple.quarantine /Applications/Superconnect.app`
4. 首次运行按提示授予 **屏幕录制** + **辅助功能** 两个权限（系统设置 → 隐私与安全性），授权一次即可。

> 想自己从源码构建：`cd mac && ./build-app.sh`（先 `xcode-select --install`）。

### 平板端（华为）

- **普通用户**：在华为**应用市场（AppGallery）**搜索 **Superconnect** 安装——上架审核通过后即可一键安装，无需开发者模式。
- **开发者 / 抢先体验**：用 **DevEco Studio** 打开 `harmony/` 自行构建安装（需开**开发者模式** + 你自己的华为开发者签名）。步骤见 [`harmony/README.md`](harmony/README.md)。

> 平板端为何不能像 Mac 那样直接下载安装？HarmonyOS 侧载应用必须用开发者身份签名 + 开启开发者模式，是系统硬性限制；面向普通用户的「无感安装」只能走应用市场。

### 连接（即插即用）

Mac 应用**已内置 `hdc`**（华为设备连接工具）。**Apple Silicon（M 系列）Mac 端无需安装任何额外软件**；**Intel Mac** 上内置 `hdc` 是 arm64、无法运行，需另装系统 `hdc`（DevEco Studio 或 HarmonyOS 命令行工具的 Intel 版）。完整流程只有：
1. 平板开启 **开发者模式 + USB 调试**（系统设置里一次性打开——这是 HarmonyOS 对 USB 连接的硬性要求，无法由软件代办）。
2. 数据线连上 Mac，平板首次弹窗 → 点**信任这台电脑**。
3. 打开 Mac 上的 Superconnect → **开始连接**。

---

## 使用

1. **平板**上打开 Superconnect，让它停在前台（这个 App 本身就是 Mac 的屏幕）。
2. 用**数据线**连接 Mac 和平板。
3. **Mac** 上打开 Superconnect，点 **「开始连接」**（它会自动找到平板并建立连接）。
4. 平板上出现 Mac 桌面 → **双击屏幕进入全屏**。
5. 把窗口拖到这块副屏上用，或在「系统设置 → 显示器」里调整它的排列位置。
6. **退出全屏**：从平板顶部下拉**通知栏**，点 Superconnect 的退出。

### 触控 & 手势对照

| 你的操作 | 效果 |
|---|---|
| 单指点一下 | 单击 |
| 单指按住拖动 | 拖动 / 框选 |
| 单指快速点两下 | 双击（双击窗口标题栏 = 填满屏幕） |
| 双指点一下 | 右键 |
| 双指滑动 | 滚动 |
| 双指捏合 / 张开 | 缩小 / 放大 |
| M-Pencil | 手写、绘图（带压感） |
| 键盘打字 | 直接输入到 Mac，支持中文输入法 |

---

## 常见问题

- **Mac 上点「开始连接」找不到平板**：确认平板已开**开发者模式 + USB 调试**、数据线支持传数据。**Apple Silicon** Mac 已内置 `hdc`、无需 DevEco；**Intel Mac** 需另装系统 `hdc`（DevEco Studio / HarmonyOS 命令行工具）。重插一次数据线再试。
- **投屏后 Mac 自己的屏幕变大、可用空间变少**：已修复——连接时会锁住你内置屏的分辨率，断开后自动还原。若仍出现，断开重连一次。
- **画面偶尔卡顿 / 连接中断**：USB-HDC 接口偶尔会掉，**重插数据线**即可，Mac 端会自动重连。
- **双击标题栏没有"填满"**：取决于系统设置 **系统设置 → 桌面与程序坞 → 连按窗口标题栏时** 选了 **"缩放"**（默认就是）。选成"最小化"则会最小化。
- **平板旋转后比例不对**：本版本旋转时会重建副屏以匹配新方向，稍等约 1 秒即跟随。

---

## 了解原理 / 参与开发

技术细节都在 `docs/`，这里只放使用说明：

- 🏛 架构 → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · 🗺 路线图 → [`docs/ROADMAP.md`](docs/ROADMAP.md) · 📊 现状 → [`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md)
- 🔌 线协议 → [`proto/protocol.md`](proto/protocol.md) · 🔬 调研 → [`docs/DESIGN.md`](docs/DESIGN.md) · 📱 平板端说明 → [`harmony/README.md`](harmony/README.md)

一句话原理：Mac 用 `CGVirtualDisplay` 造一块扩展屏 → `ScreenCaptureKit` 采集 → `VideoToolbox` 硬编码 → 经 `hdc fport`（USB 上的 TCP）传给平板 → 平板硬解码并渲染；触控/手写/键盘反向回传，Mac 端转成系统事件注入。同一套传输代码为将来的**局域网无线**和**任意设备互投**预留了接口。

无设备也能验证核心（三端跨语言协议一致性，含 ArkTS）：

```bash
tools/check-protocol.sh   # Swift + C++ + ArkTS 全部对照 proto/vectors.json（ArkTS 校验需 Node ≥ 22.7）
```

---

## 支持作者 ☕

软件开发不易，感谢你的支持！如果这个项目帮到了你，欢迎用支付宝请作者喝杯咖啡 ❤️

<img src="docs/assets/donate-alipay.jpg" alt="支付宝赞赏码" width="260">

---

## 许可证

[MIT](LICENSE)。

## 安全

本仓库不含任何账号凭据或签名私钥；`.gitignore` 已排除签名材料与构建产物。平板端 `build-profile.json5` 的 `signingConfigs` 为空，需用你自己的华为开发者身份签名。
