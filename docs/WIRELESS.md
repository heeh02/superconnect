# 无线连接（Wi‑Fi LAN） — v0.2.1

把平板作为 Mac 的**无线**扩展屏，无需数据线。无线是一个**独立模块**，与有线（USB/hdc）路径完全解耦：
关掉无线时，有线行为与 v0.2.0 **逐字节一致**。

> **蓝牙不传视频。** 视频只走 Wi‑Fi。蓝牙仅在未来用于发现/配对/令牌交换，**永远不**承载视频或输入流。

## 使用（先开平板，再从 Mac 连）

1. **平板**：打开 Superconnect → 在首页或「控制面板 › 无线连接」打开**无线模式 (Wi‑Fi)**。
   - 打开后平板监听 `0.0.0.0:8888` 并通过 mDNS 广播自己（`_superconnect._tcp`）。
   - 首页显示平板的 **Wi‑Fi 地址**（如 `192.168.1.23 : 8888`），供手动连接备用。
   - 关闭无线模式 → 平板退回 `127.0.0.1`（仅 USB），不在局域网暴露。
2. **Mac**：打开 Superconnect。
   - **自动发现**：同一 Wi‑Fi 下的平板会出现在设备列表（无线徽标）。点连接即可。
   - **手动兜底**（某些网络屏蔽 mDNS）：在设备栏底部「平板 IP（无线）」输入框填入平板显示的地址
     （`ip` 或 `ip:port`）→ 添加 → 连接。右键该无线设备可「移除」。
3. **首次配对（TOFU，仅无线）**：陌生 Mac 首次无线连接时，**平板**弹出「允许此设备无线连接？」
   - 点**允许** → 记住该 Mac（`peerId`），以后自动连接，不再提示。
   - 点**拒绝** → 本次拒绝；Mac 显示「平板未授权本机连接」，**不重试**。
   - 有线（USB/hdc）连接来自 `127.0.0.1`，**始终免配对**，与 v0.2.0 一致。
   - 在平板「控制面板 › 已配对设备」可**移除**已信任的 Mac（移除后需重新配对）。

## 安全模型

- 平板开启无线后监听 `0.0.0.0`，因此用 **TOFU 配对门**防止陌生设备连入：
  - `localhost`（hdc/USB，恒为 `127.0.0.1`）→ 直接放行。
  - 已信任 `peerId` → 直接放行（持久化于 `preferences`）。
  - 其他局域网设备 → 弹窗等用户**允许**后才发 `hello_ack`；拒绝则发 `{type:error, message:"pairing_rejected"}` 且不回 ack。
  - 同一会话内被拒的 `peerId` 进入临时拒绝集（不再骚扰弹窗）；60s 无人应答自动拒绝；弹窗进行中的新陌生设备会被**直接拒绝**（不顶替弹窗，防止冒名顶替用户的点按）。允许/拒绝以弹窗的 promptId 绑定，过期点按无效；只有发起连接的那条会话（按 clientId）才能取消自己的弹窗。
- Mac 侧：收到 `pairing_rejected` 视为**致命**，停止并提示，**不进入 1.5s 重连风暴**。
- 关闭无线模式即彻底关闭局域网入口（回到 `127.0.0.1`）。

> **Beta 安全限制（已知，Phase 2 修复）**：本期传输是**明文 TCP**（无 TLS），信任以 Mac 的 `peerId` 作为凭据。
> TOFU 能挡住**未授权**的陌生设备（必须有人在平板上点允许），但**不能**防御能嗅探局域网流量的攻击者——
> 其可截获某台已信任 Mac 的 `peerId` 并重放冒充。真正的加固（TLS + 基于公钥的 TOFU，或配对时建立共享密钥的
> 挑战应答）属于 **Phase 2**（低延迟传输通道一并引入）。在受信任的家庭/办公 Wi‑Fi 下使用；不要在公共/不可信网络上开启无线模式。

## 实现（模块边界）

**Mac（`mac/Sources/superconnect-app/Services/Discovery/Wireless/`）**
- `WirelessDiscovery.swift` — `NWBrowser` 浏览 `_superconnect._tcp`，把每个服务解析成 `host:port`（一次性 `NWConnection`），
  发布 `.wireless` 设备。
- `ManualDiscovery.swift` — 用户手动输入的 IP 列表（`UserDefaults` 持久化），发布 `.wireless` 设备。
- 两者都走**既有**连接路径：`DirectTunnel` → `TcpTransport` → `HostConnection`（无新连接代码）。
- `App/AppEnvironment.swift` 注册这两个发现源（一处组合根改动）。`Info.plist` 加
  `NSLocalNetworkUsageDescription` + `NSBonjourServices`（macOS 15+ 局域网/Bonjour 所需）。

**平板（`harmony/entry/src/main/ets/services/wireless/`）**
- `WirelessService.ets` — 无线开关 + 绑定地址（`127.0.0.1` ↔ `0.0.0.0`）+ Wi‑Fi IP + **TOFU 配对门** + mDNS 协调。
- `PairingStore.ets` — 已信任 Mac `peerId` 列表（`@ohos.data.preferences` 持久化）。
- `MdnsAdvertiser.ets` — `addLocalService`/`removeLocalService`（**仅在监听成功后**广播）。
- 附加缝（有线默认值不变）：`TcpServerTransport` 增 `bindAddress`/`stop()`/`onListening` + 用 `getRemoteAddress`
  标记 localhost；`Session` 增可选 `pairingGate`（无门 ⇒ 放行 ⇒ 有线不变）；`ReceiverConnection` 透传上述回调。

**Intel Mac**：`Resources/hdc/<arch>/` 双目录打包就绪——拿到 x86_64 版 hdc 直接丢进 `hdc/x86_64/` 即可；
在此之前 Intel 用系统 hdc 或走**无线模式**（免 hdc）。

## 范围

- **本期（Phase 1）**：Wi‑Fi TCP，复用现有协议（`TcpTransport` + `Session` + `FrameCodec`，**线协议零改动**，仅新增
  `error.message` 附加字段）。
- **下期（Phase 2，未做）**：低延迟视频通道（VIDEO 走 UDP/QUIC、CONTROL+INPUT 走 TCP）、自适应码率分级。
