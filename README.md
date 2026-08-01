# superconnect

把 **HarmonyOS 或 Android 平板**变成 **Mac 的一块扩展屏**：用数据线或局域网 Wi-Fi 连上，平板就成了 Mac 的第二块显示器。当前按平台支持触控、键盘，以及 HarmonyOS 端的 M-Pencil 手写笔输入。

> 当前开发分支支持 HarmonyOS 与 Android 接收端的**有线（USB）**与**局域网 Wi-Fi**。平板可作为 Mac 副屏使用；屏幕旋转、键盘、触控手势均已可用，HarmonyOS 端支持手写笔输入。无线使用与安全边界见 [`docs/WIRELESS.md`](docs/WIRELESS.md)。

> **Windows 版本开发中**：当前代码已实现 Windows 接收 Mac 投屏的主要路径，包括 TCP、H.264/SDR 解码渲染和键鼠回传；尚未完成 Windows 实机与完整 Windows CI 验证，暂不作为可下载发行版宣传。

> 🧭 **接手/上手开发者请先读 [`docs/HANDOFF.md`](docs/HANDOFF.md)** — 项目全貌、先看哪些文档、已完成/进行中/已知问题/待办、构建部署与操作注意事项。

---

## 它能做什么

- 🖥 **扩展屏**：HarmonyOS 或 Android 平板显示 Mac 的桌面（不是镜像，是真正多出来的一块屏），最高 120Hz、HiDPI 清晰显示。
- ✍️ **M-Pencil 手写**：HarmonyOS 端支持带压感的手写与绘图。
- 👆 **触控操作**：像触控板一样——单击、拖动、双击（标题栏双击填满窗口）、双指右键、双指滚动、双指捏合缩放。
- ⌨️ **键盘**：平板的物理键盘 / 虚拟键盘直接给 Mac 打字，**支持中文输入法**。
- 🔄 **跟随旋转**：转动平板，Mac 这块副屏会自动切换横屏 / 竖屏比例。

---

## 免费与付费边界

当前产品分为免费版、¥6 应用商店版、¥66 全设备版和 ¥666 需求版。免费版是功能最简的基础版本，¥6 版本与免费版的投屏功能基本一致，主要提供更完整、更美观的 GUI 和应用商店发行体验。

免费版当前包含基础能力：

- Mac 作为画面源，HarmonyOS 或 Android 平板作为接收端；
- 有线 USB 和局域网 Wi-Fi 连接；
- 标准 TCP 投屏、扩展屏显示、触控/键盘回传，以及已实现的平台输入能力；
- 产品边界是 Mac → 接收端的基础单向投屏，不包含任意设备互投、投屏角色切换或低延迟模式。

更高级的能力通过独立授权层隔离，不改变基础协议：

| 档位 | 当前边界 |
|---|---|
| 免费版 `superconnect_free` | 功能最简的基础投屏版本，提供 Mac → HarmonyOS/Android 接收端的基本有线、Wi-Fi 和标准投屏能力。 |
| ¥6 应用商店版 `superconnect` | 与免费版功能基本一致，不额外解锁任意设备互投或低延迟能力；主要区别是 GUI 更完整、更美观，并作为应用商店上架版本发布。 |
| ¥66 全设备互联 | 解锁任意受支持设备之间的自由投屏、投屏方向切换、自定义主从角色、低延迟传输，以及后续更多设备互联能力。具体能力随版本逐步开放。 |
| ¥666 自提需求版 | 用户提出一个需求，单独进行可行性评估和优先开发；不承诺所有需求都能实现，也不是应用内运行时功能开关。 |

因此，¥6 版本的价值主要在于正式应用商店体验，而不是增加投屏功能；任意设备互投、自由投屏方向和低延迟等能力属于 ¥66 版本。具体已开放功能以对应版本的发布说明为准。

## 你需要准备

| | 要求 |
|---|---|
| Mac | macOS 14 及以上，**Apple Silicon 或 Intel**（通用二进制）。Apple Silicon 已真机使用；Intel 包的架构、签名及内置 HDC 启动已验证，但尚未完成“Intel Mac + 商用 HarmonyOS 平板”组合真机测试。 |
| 接收端平板 | **HarmonyOS NEXT（API 12+）**或 **Android 7.0+（API 24+）**；需支持硬件 H.264/HEVC 解码。分辨率、刷新率与编码由握手能力协商，具体机型仍需实际验证。HarmonyOS 端的 M-Pencil 压感取决于机型与系统。 |
| 数据线 | 有线连接需要一根能传数据的 USB-C 线；HarmonyOS 使用 HDC，Android 使用 ADB。Wi-Fi 连接不需要数据线。 |
| 软件 | Mac 发行包包含 Android 有线连接所需的 `adb`，并按架构打包可用的 HarmonyOS `hdc`；Wi-Fi 连接不依赖 `adb`/`hdc`。自行构建或侧载接收端 App 时，分别准备 Android 工具链或 DevEco Studio。 |
| Windows | Windows 接收端开发中，当前目标为 Windows 11 x64；已实现 TCP + H.264/SDR 接收渲染和键鼠回传主路径，尚未完成 Windows 实机验证，暂未提供稳定发行包。 |

> 安装分两端：**Mac 端**从 Releases 下载安装包；**HarmonyOS / Android 接收端**按对应平台安装。HarmonyOS 可通过应用市场或签名 HAP 安装，Android 可安装 APK。

---

## 安装

### Mac 端（下载安装包）

1. 到 **[Releases](https://github.com/heeh02/superconnect/releases)** 下载最新的 macOS ZIP。Apple Silicon 选 `macos-free.app.zip`；Intel 选 `macos-intel-x86_64.app.zip`。
2. 双击 ZIP 解压得到 `.app`，再把它移入**应用程序（Applications）**。
3. **首次打开**：在「应用程序」里右键该 App → **打开**，再点一次**打开**即可。
   - 应用是自签名、未经 Apple 公证，所以系统会拦一次；之后就能直接双击打开。
   - 也可终端一行解除拦截：`xattr -dr com.apple.quarantine /Applications/superconnect.app`
4. 首次运行按提示授予 **屏幕录制** + **辅助功能** 两个权限（系统设置 → 隐私与安全性），授权一次即可。

> 想自己从源码构建：`cd mac && ./build-app.sh`（先 `xcode-select --install`）。

### 平板端（HarmonyOS / Android）

- **HarmonyOS**：可从应用市场安装已发布版本，或用 **DevEco Studio** 打开 `harmony/` 构建签名 HAP。侧载测试需要开启开发者模式，并使用你自己的 HarmonyOS 应用签名。步骤见 [`harmony/README.md`](harmony/README.md)。
- **Android**：可从 Releases 下载 APK，或用 Android Studio 打开 `android/` 构建 `free` 版本。Android 7.0 及以上可用；步骤见 [`android/README.md`](android/README.md)。

> 侧载安装是否需要开发者模式取决于平台和安装渠道：HarmonyOS 的签名 HAP 侧载需要开发者模式；Android 安装 APK 还需遵循设备自身的安装与安全设置。USB 有线投屏另需开启对应平台的 USB 调试并确认设备授权。

### 连接（即插即用）

有线和无线是两条独立路径：

- **HarmonyOS 有线**：Mac 使用 `hdc` 转发；平板开启开发者模式 + USB 调试，首次连接时确认信任电脑。
- **Android 有线**：Mac 使用 `adb` 转发；平板开启 USB 调试，首次连接时确认 RSA 授权。
- **HarmonyOS / Android Wi-Fi**：Mac 与平板接入同一局域网，在接收端开启无线模式；不依赖 `hdc` 或 `adb`，设备通过局域网发现或手动 IP 连接。

打开平板端 superconnect，再打开 Mac 上的 superconnect，选择设备并点**开始连接**。

连接时若接收端尚未打开、USB 短暂重枚举或转发暂不可用，Mac 会保留设备卡片并显示**等待设备**，按上限 10 秒的退避自动恢复；点击等待中的连接按钮可主动取消。其他 USB/ADB/HDC 设备的插拔不会复用当前连接的本地端口。实现边界与真机检查表见 [`docs/CONNECTION-RELIABILITY.md`](docs/CONNECTION-RELIABILITY.md)。

---

## 使用

1. **HarmonyOS 或 Android 平板**上打开 superconnect，让它停在前台（这个 App 本身就是 Mac 的屏幕）。
2. 用**数据线**连接 Mac 和平板。
3. **Mac** 上打开 superconnect，点 **「开始连接」**（它会自动找到平板并建立连接）。
4. 平板上出现 Mac 桌面 → **双击屏幕进入全屏**。
5. 把窗口拖到这块副屏上用，或在「系统设置 → 显示器」里调整它的排列位置。
6. **退出全屏**：从平板顶部下拉**通知栏**，点 superconnect 的退出。

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

- **Mac 上点「开始连接」找不到平板**：有线 HarmonyOS 检查 `hdc` 授权和 USB 调试，有线 Android 检查 `adb` 授权和 USB 调试；Wi-Fi 检查双方是否在同一局域网，必要时使用接收端显示的 IP 手动连接。发行包已包含对应的 Android `adb` 与 HarmonyOS `hdc`；具体机型仍需结合设备型号和系统版本排查。
- **投屏后 Mac 自己的屏幕变大、可用空间变少**：已修复——连接时会锁住你内置屏的分辨率，断开后自动还原。若仍出现，断开重连一次。
- **平板端尚未打开 / USB 短暂断开**：Mac 会显示**等待设备**并自动重建转发，不会因为一次发现列表抖动就删除连接。确认平板端 App 已打开；长时间无法恢复时再检查线材、USB 调试授权与 `hdc`。
- **双击标题栏没有"填满"**：取决于系统设置 **系统设置 → 桌面与程序坞 → 连按窗口标题栏时** 选了 **"缩放"**（默认就是）。选成"最小化"则会最小化。
- **平板旋转后比例不对**：本版本旋转时会重建副屏以匹配新方向，稍等约 1 秒即跟随。

---

## 了解原理 / 参与开发

技术细节都在 `docs/`，这里只放使用说明：

- 🏛 架构 → [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · 🗺 路线图 → [`docs/ROADMAP.md`](docs/ROADMAP.md) · 📊 现状 → [`docs/PROJECT-STATUS.md`](docs/PROJECT-STATUS.md) · 🔧 连接可靠性 → [`docs/CONNECTION-RELIABILITY.md`](docs/CONNECTION-RELIABILITY.md)
- 🔌 线协议 → [`proto/protocol.md`](proto/protocol.md) · 🔬 调研 → [`docs/DESIGN.md`](docs/DESIGN.md) · 📱 HarmonyOS 端 → [`harmony/README.md`](harmony/README.md) · Android 端 → [`android/README.md`](android/README.md) · Windows 端 → [`windows/README.md`](windows/README.md)

一句话原理：Mac 用 `CGVirtualDisplay` 造一块扩展屏 → `ScreenCaptureKit` 采集 → `VideoToolbox` 编码 → 经 HarmonyOS `hdc`、Android `adb` 转发或局域网 Wi-Fi 传给接收端 → 接收端硬解码并渲染；触控/手写/键盘反向回传，Mac 端转成系统事件注入。当前 HarmonyOS 与 Android 已支持有线和 Wi-Fi；Windows 接收端正在开发，任意设备互投仍是后续能力。

### Windows 开发状态

Windows 当前优先开发为**接收端**：接收 Mac 的扩展屏画面，并将 Windows 键盘、鼠标回传给 Mac。代码已经覆盖 WinSock TCP、SC-AUTH-v1、Media Foundation H.264/SDR 解码、D3D11 渲染和 Raw Input，但还没有在本地 Windows 设备上完成端到端验证。

当前不把 Windows 版本描述为稳定发行版：mDNS 自动发现、UDP-v2、HEVC/HDR、Windows 作为投屏源，以及安装包和签名仍在后续开发。详细构建条件、验证命令和待办见 [`windows/README.md`](windows/README.md)。

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

本仓库不含任何账号凭据或签名私钥；`.gitignore` 已排除签名材料与构建产物。HarmonyOS 端 `build-profile.json5` 的 `signingConfigs` 为空，侧载构建时需使用你自己的 HarmonyOS 开发者签名。
