# 真机联调 Runbook（有线 / USB）

> 目标：把 `harmony/` 构建成 `.hap` 装到华为平板，用 USB 把 Mac 投屏过去并验证触控回注。
> 一次跑通后即同时验证三个此前未确认的风险点（见 §6）。
>
> ⚠️ 本文档的鸿蒙侧步骤在编写时**联网核验受限**，依据的是工具链既有知识 + 本仓库脚本。
> DevEco/系统的**菜单文案**可能因版本略有差异——以设备上的实际项为准。命令与目录结构是可靠的。

环境（实测）：macOS 26.5 / Apple Silicon；平板 = HarmonyOS NEXT（USB 枚举为 HiSilicon "HDC Device"）。

---

## 0. 总览（5 步）
1. 平板：开启开发者模式 + USB 调试，首次连接授权。
2. Mac：安装 `hdc`（HarmonyOS 命令行工具），加入 PATH。
3. DevEco：用**Native C++ 模板**建壳工程 → 放入本仓库源码 → 自动签名 → Run 安装到平板。
4. Mac：授予"屏幕录制 + 辅助功能"权限给终端，建立 `hdc fport` 隧道。
5. Mac：`swift run superconnect-mac --produce`，验证投屏与触控。

随时先跑 `tools/preflight.sh` 自检 Mac 侧前置条件。

---

## 1. 平板：开发者模式 + USB 调试
1. **设置 → 关于平板** → 连点"版本号"7 次，提示"已进入开发者模式"（可能要输锁屏密码）。
2. **设置 → 系统和更新 → 开发者选项** → 打开顶部"开发者选项"，再开"USB 调试"。（找不到就在设置里搜"开发者"。）
3. 用**数据线**连 Mac，平板弹"是否允许 USB 调试？"→ 勾"始终允许"→ 确定。
   - 没弹窗：开发者选项里"撤销 USB 调试授权"后重插。

> 纯鸿蒙只能装**已签名 .hap**（无 APK 路径）；安装/运行侧载 .hap 需要开发者模式开启。

---

## 2. Mac：安装 hdc（不是 adb，也**不是 OpenHarmony 的 hdc**）

> ⚠️ **HarmonyOS ≠ OpenHarmony（已实测确认）**：MatePad Pro 13.2 跑的是华为**商用 HarmonyOS (NEXT)**，其设备端 hdc daemon 随华为系统镜像发布，只与**华为版 hdc** 配对。
> 从 OpenHarmony 公共镜像（repo.huaweicloud.com）下载的 `hdc` 是**开源 OpenHarmony** 版（`oh-uni-package.json` 标 `version 5.1.0.107`，README 自称"OpenHarmony 设备连接器"，面向 OpenHarmony 设备/模拟器）。
> 实测：OpenHarmony `hdc 3.1.0e` 的 `USBHost loopfind` **找不到**该商用设备（idVendor 0x12D1 华为、"HDC Device" 接口在位），也不弹授权框。**结论：商用 HarmonyOS 设备必须用华为版 hdc。**
> 而且即便连上，**构建/签名 .hap 也必须用华为 HarmonyOS SDK**（OpenHarmony SDK 产不出可装到零售机的已签名 .hap）。所以整条链路都走华为工具栈。

华为版 `hdc` 随 **DevEco Studio** 或 **Command Line Tools for HarmonyOS** 一起提供，从 [developer.huawei.com 下载](https://developer.huawei.com/consumer/cn/download/)（需**免费华为开发者账号登录**——这一步只能你本人在浏览器完成，无免登录官方源）。两种选择：
- **DevEco Studio**（推荐）：IDE + SDK + hdc + 自动签名 UI，建/装/调一站式。
- **Command Line Tools for HarmonyOS**（更轻）：含 hdc + hvigor（CLI 构建）+ ohpm，无 IDE。
```bash
# 安装后，定位 hdc：
find "$HOME/command-line-tools" "$HOME/Library/Huawei" /Applications/DevEco-Studio.app -name hdc -type f 2>/dev/null
# 把它所在的 .../openharmony/toolchains 目录加入 PATH（zsh）：
echo 'export PATH="$HOME/command-line-tools/sdk/default/openharmony/toolchains:$PATH"' >> ~/.zshrc
source ~/.zshrc
hdc -v && tools/check-device.sh   # 应列出设备，而非 [Empty]
```
> `hdc ≠ adb`：本设备是 HarmonyOS，`adb` 永远看不到它。所有脚本也支持 `HDC=/full/path/to/hdc tools/xxx.sh` 显式指定。

---

## 3. DevEco：构建 / 签名 / 安装 .hap

**为什么不直接 `hap` 这个目录**：本仓库**故意不含** `build-profile.json5 / oh-package.json5 / hvigor/ / resources/base/media/`（这些与 DevEco 版本强相关）。正确做法是让 DevEco 生成工程壳，再把我们的源码放进去。

1. **建壳工程**：DevEco → New → Create Project → **Native C++** 模板（它已内置"Add C++ to Module"接线 + 默认图标）。
   - Bundle name：`com.superconnect.pad`；Language：ArkTS；Stage 模型；**API 12（HarmonyOS 5.0）**（设备是 5.0.1/5.1 就选对应 API）；Device type 勾 **Tablet**（可同时留 Default）。
2. **放入源码（替换）**：把生成工程里的
   - `entry/src/main/ets/` 整个替换为本仓库 `harmony/entry/src/main/ets/`
   - `entry/src/main/cpp/` 整个替换为本仓库 `harmony/entry/src/main/cpp/`
   - 复制 `resources/base/element/{string.json,color.json}`、`resources/base/profile/main_pages.json`
   - ⚠️ **保留 DevEco 生成的 `resources/base/media/`（startIcon 等）**——本仓库没有它，整树覆盖会导致 `$media:startIcon` 解析失败、构建报错。只替换 `ets/`、`cpp/` 和上面列的 element/profile 文件，**不要整树替换 `resources/`**。
3. **合并配置（不要覆盖生成的构建文件）**：
   - `entry/src/main/module.json5`：加入 `ohos.permission.INTERNET` 的 `requestPermissions` 块。
   - `AppScope/app.json5`：`bundleName=com.superconnect.pad`、`label=$string:app_name`。
   - `entry/build-profile.json5`：确认 `buildOption.externalNativeOptions` 指向 `./src/main/cpp/CMakeLists.txt`，`abiFilters: ["arm64-v8a"]`（Native C++ 模板已生成；若用了 Empty Ability 模板，右键 entry → **Add C++ to Module** 生成该块）。
   - `entry/oh-package.json5`：加入原生类型依赖，让 ArkTS 能 `import sc from 'libsuperconnect.so'`：
     ```json5
     "dependencies": { "libsuperconnect.so": "file:./src/main/cpp/types/libsuperconnect" }
     ```
     然后点 **Sync Now**。
4. **命名链一致**（仓库内已对齐，勿改）：CMake `add_library(superconnect ...)` → `libsuperconnect.so`；`napi nm_modname="superconnect"`；ArkTS `XComponent({libraryname:'superconnect'})` + `import 'libsuperconnect.so'`。三处基名都必须是 `superconnect`。
5. **自动签名**（真机必需）：
   - DevEco 登录**华为开发者账号**（普通消费者 ID 可能需先注册成开发者）。
   - **先连上平板**（这样能读到 UDID），再到 Project Structure → Signing Configs 勾 **Automatically generate signature**。DevEco 会自动生成 debug 证书/profile 并把设备 UDID 注册进去（单 profile 上限 100 台）。
6. **构建并安装**：选 `entry` + 平板，点 **Run ▶**（自动签名→`hdc install`→启动）。
   - 手动：Build → Build Hap(s) → 产物 `entry/build/default/outputs/default/entry-default-signed.hap`，再
     ```bash
     tools/install-hap.sh harmony/entry/build/default/outputs/default/entry-default-signed.hap
     hdc shell aa start -a EntryAbility -b com.superconnect.pad
     ```
7. **看日志**：`hdc hilog`（或 DevEco 的 HiLog 面板）。应见 `client connected` / `XComponent surface loaded`。原生 C++ 日志走 `libhilog_ndk.z.so`，同一流里。

成功标志：平板显示 `status: listening 127.0.0.1:8888`。

---

## 4. Mac：权限 + 隧道 + 运行
1. **授权**（投屏需"屏幕录制"，触控注入需"辅助功能"）：
   ```bash
   tools/grant-permissions.sh         # 打开两个系统设置面板
   ```
   - 在"屏幕与系统录音"和"辅助功能"里勾选**你运行命令的那个终端 App**（Terminal/iTerm/VS Code）——TCC 把 `swift run` 归属到父终端，不是某个 "superconnect" 条目。
   - **改完务必 Cmd+Q 退出并重开终端**（权限在进程启动时缓存）。仍不行：`tccutil reset ScreenCapture && tccutil reset Accessibility` 后重跑触发重新弹窗。
2. **隧道 + 运行**（平板 app 已在前台监听后）：
   ```bash
   tools/preflight.sh                 # 自检
   tools/dev-up.sh                    # = hdc fport tcp:8888 + swift run ... --produce
   # 或手动：
   tools/fport.sh                     # hdc fport tcp:8888 tcp:8888 ; hdc fport ls
   swift run --package-path mac superconnect-mac --produce
   ```
   预期 Mac 输出：
   ```
   (produce) connecting to 127.0.0.1:8888 …
   handshake OK. peer caps: [...]
   virtual display <id> at (...)
   encoding 1280×800 → sending video_config
   streaming ~N fps
   ```

> `hdc fport` 隧道**不跨重插**——每次重插 USB 后重跑 `tools/fport.sh`。它是 `fport`（Mac→设备），不是 `rport`。

---

## 5. 看到画面 / 触控
- 虚拟扩展屏默认在主屏**左侧**（坐标约 `(-1280,0)`）且初始为空。把一个窗口**拖到左边**那块屏，平板上就会显示该窗口（投屏验证）。
- 也可在"系统设置 → 显示器"里把排列/镜像调成你想要的方式。
- 在平板上用手指/笔触摸 → Mac 上对应位置的光标移动/点击/拖拽（触控回注验证，需"辅助功能"已授权）。

---

## 6. 三个风险点 → 如何判定通过
| 风险 | 通过判据 |
|---|---|
| **A. `hdc fport` 能否到侧载 app** | Mac 打印 `handshake OK`（或 ping 模式有 RTT）。研究结论：fport 在 OS 层连设备 `127.0.0.1:8888`，**不**依赖 app 的 debuggable 标志，只要 app 前台在监听即可（中等可信，已待此步实证）。 |
| **B. `OH_VideoDecoder` 真机解码渲染** | 拖窗口到扩展屏后，平板 XComponent 上**出现画面**；hilog 有 `decoder armed W×H`、无解码错误。 |
| **C. 触控回注** | 触摸平板 → Mac 光标/点击响应（授予"辅助功能"后）。 |

---

## 7. 故障排查

**鸿蒙 / DevEco**
| 现象 | 原因 | 处理 |
|---|---|---|
| 构建报 `$media:startIcon` 未找到 | 整树覆盖 `resources/` 删掉了模板图标 | 恢复生成的 `resources/base/media/`；只替换 `ets/`、`cpp/` 与指定 element/profile |
| ArkTS 找不到 `libsuperconnect.so` | 未加 `file:` 依赖或未 Sync | 在 `entry/oh-package.json5` 加依赖并 Sync Now |
| Surface 加载但原生回调不触发 | `libraryname`/`nm_modname`/.so 基名不一致，或未编译原生 | 三者都为 `superconnect`；确认 `externalNativeOptions.path`，检查产物 `.../libs/arm64-v8a/libsuperconnect.so` |
| `hdc install` 报签名错误 | 未签名 / profile 不含设备 UDID | 连着设备开自动签名（或在 AGC 注册 UDID），重建后 `hdc install -r` |
| CMake 找不到 `OH_VideoDecoder` 符号 | SDK API < 12 或未装 NDK | SDK Manager 装 API≥12 + Native；调高 `compileSdkVersion` |
| 平板背景后断流 | NEXT 冻结后台 app | 保持 app 前台；用 `window.setWindowKeepScreenOn(true)` 防息屏（Phase 1 待加） |

**macOS / hdc**
| 现象 | 原因 | 处理 |
|---|---|---|
| `hdc: command not found` / 脚本退出 127 | 未装/未入 PATH | 装命令行工具，`find ~ -name hdc`，加 PATH 或 `HDC=...` |
| `hdc list targets` 为 `[Empty]` | 未授权 / 未开 USB 调试 / 充电线 / hdc 服务陈旧 | 换数据线、开调试、点允许；`hdc kill` 后重试 |
| 一直 `TIMEOUT` / 连不上 | 未 fport / 端口不符 / app 没监听 | `hdc fport ls` 确认；平板显示 listening；`--port` 一致 |
| 有 `handshake OK` 但无 `encoding/streaming` | 录屏权限缺失或 SSH/headless 启动 | 授予终端"屏幕录制"并重开终端；在登录的图形会话里跑（非 SSH） |
| 投屏正常但触控无效 | 缺"辅助功能"权限 | 授予终端并重开；必要时 `tccutil reset Accessibility` |
| 权限显示已开但仍被拒 | TCC 进程启动时缓存 / 授错了终端 | 授权你实际用的那个终端，Cmd+Q 重开；必要时 `tccutil reset` 后重跑 |

---

## 8. 已知后续（不影响联调，列出以免踩坑）
- 投屏分辨率当前为 1280×800（虚拟屏背景分辨率），HiDPI 2× 背景待校准（Phase 3）。
- 防息屏 `setWindowKeepScreenOn(true)` 待加（保持前台时屏幕会自动变暗）。
- ArkTS 严格模式可能对 `@ohos.net.socket` 类型名/动态 JSON 提示告警——按你 SDK 的 `.d.ts` 微调，协议字节序由 `proto/vectors.json` 保证不变。
