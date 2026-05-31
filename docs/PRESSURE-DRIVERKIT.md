# 真实压感路线图：DriverKit 虚拟数字化板（Phase 3b）

> 现状：平板已能采集 M-Pencil 的 **压感(0–1) + 倾角**，并区分笔/手指；Mac 端笔走 `CGEvent` 的 tablet 子类型注入。
> 问题：**Notability/Procreate 类专业 app 通常只认"真实 HID 数字化板"的压感**，会忽略合成的 `CGEvent` 压力 → 线宽不随力度变化。
> 解法：在 Mac 上用 **DriverKit 系统扩展(dext)** 注册一个**虚拟数字化板 HID 设备**，让 macOS 自己生成真正的 `NSTabletPoint` 压感事件，专业 app 即原生识别。（即 Astropad 的做法。）

## 要做什么
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

## 不上 DriverKit 的替代
- 现有 `CGEvent` tablet 子类型：部分 app 可能认压感（值得逐个实测）。
- 也可做一个**自绘画布**（平板或 Mac 端我们自己渲染笔迹，压感随便用），但那就不是"在任意 Mac app 里用笔"了。
