# DriverKit 虚拟数字化板（远期专业路线）

> 当前 v0 已不依赖 DriverKit：平板通过 ArkUI 采集 M-Pencil **压感(0–1) + 倾角**，
> Mac 端用 `CGEvent` tablet point 并补齐 tablet **proximity** enter/leave 事件后，
> 已能让主流绘写应用进入手写笔模式并读取压力。DriverKit 因此不是当前必需项。
>
> 本文保留为远期专业路线：如果将来需要更高精度、系统级虚拟数位板身份，或某些专业 app
> 对合成 tablet event 仍不兼容，可再实现 DriverKit 虚拟 HID 数字化板。

## 若将来要做什么
1. **DriverKit dext**（C++，`IOUserHIDDevice` 子类）：
   - 提供一个 HID Report Descriptor，使用 **Digitizer/Stylus（usage page 0x0D）**：X、Y、Tip Pressure、In-Range(proximity)、Tilt X/Y、Eraser。
   - 接收来自宿主 app 的笔数据，组装 HID input report 上报。
2. **宿主 app（.app bundle）**：用 `OSSystemExtensionRequest` 激活 dext；把 `superconnect-mac` 收到的 **笔** INPUT 事件转成 HID report 写给 dext（手指仍走 `CGEvent`）。笔落笔/抬笔发 in-range 进/出。
3. **InputInjector 改造**：`tool==pen` → 走 dext（HID report，带 pressure/tilt/in-range）；`tool==finger` → 保持 `CGEvent` 导航。

## 先决条件（这部分是真正的门槛，且多为 GUI/账号/审批）
- **Apple 开发者账号开通 DriverKit 能力**：向 Apple 申请 `com.apple.developer.driverkit` 及 `…driverkit.family.hid.device / transport.hid / hid.virtual.device / hid.eventservice` 等 entitlement（**需 Apple 审批，非即时**）。
- **Xcode 工程**：SwiftPM **不能**构建 dext；需要在 Xcode 里建 **System Extension (DriverKit)** target + 一个宿主 .app（现有 `superconnect-mac` 是 SwiftPM CLI，要么改造为 .app，要么新建一个壳 app 承载 dext 与激活逻辑）。
- **本机开发**：`systemextensionsctl developer on`；Apple Silicon 可能需在"恢复模式"降低系统扩展安全策略；安装时需在 **系统设置 → 登录项与扩展** 手动批准。
- **签名**：dext 与宿主 app 用带 DriverKit 能力的证书/描述文件签名。

## 参考实现
- `Karabiner-DriverKit-VirtualHIDDevice`（pqrs-org）：成熟的 DriverKit 虚拟 HID 模板（键鼠），含 entitlements/激活/守护进程结构。**但它只有键鼠，数字化板的 report descriptor 需自己写。**
- HIDDriverKit：`IOUserHIDDevice` / `IOUserHIDEventService`。

## 工作量与风险
- 中-大型，且关键路径依赖 **Apple 审批 + 你的账号能力 + GUI 签名/批准**，无法纯 CLI 自动完成。
- 建议在你准备好（账号开通 DriverKit 能力）后，作为一个独立里程碑推进；届时我可：搭好 Xcode 工程骨架、写 dext + report descriptor + 宿主激活 + InputInjector 路由，你负责账号/签名/系统批准。

## 当前替代方案
- 现有路径：ArkUI pressure/tilt/history → INPUT → `CGEvent` tablet point + tablet proximity。当前项目以此为 v0 的真实压感方案。
- 可选调优：如需更强轻重对比，可在 Mac 注入前对 pressure 做 gamma 曲线拉伸。
