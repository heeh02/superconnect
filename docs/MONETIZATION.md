# Superconnect — 账号 / 分档 / 付费设计（C 层）

> 状态：设计中（2026-06-02 起草）。本文是 **C = ¥6 付费版** 及其后续分档的**架构与商业规格**。
> 先有此文，再按 §6 的增量逐步实现。账号/付费是**独立授权层**，永不进传输层。

## 0. 第一原则

**授权是一个解耦的独立层（Entitlement Layer），不塞进 `Transport` / `FrameCodec` / `Session`。**
线协议保持与档位无关；付费只决定"允许哪些能力 / 走哪条路径"，由组合根注入、被协调器与 UI 查询。
这与既有的 `Role × Platform` 工厂、`ConnectionCoordinator` 多连接注册表、`RoleCapabilities`
（`mac/.../Models/Role.swift`，OptionSet `canHost`/`canReceive`）一脉相承 —— 授权门是又一个注入的 seam。

## 1. 分档（Tiers）

| 档位 | 价格 | 给什么 | 边界 / 文案 |
|---|---|---|---|
| **免费** | ¥0 | 必须华为账号登录；绑定 **1 个 Mac + 1 个 Pad**；当前方向 **Mac host → Pad receiver**；**同时在线 1 路** | 当前体验，不需承诺 |
| **支持档** | **¥6** | 功能同免费 + **Supporter 标识 / 感谢页 / 优先反馈入口** + **更低延迟视频路径**（= Phase 2：VIDEO 走 UDP/QUIC、CONTROL+INPUT 走 TCP + 自适应码率分级） | **不承诺技术支持 SLA**。低延迟是这一档的**可交付技术卖点** |
| **全设备互联** | **¥66** | 未来 entitlement 占位：**多 Pad / 多设备 / 主从自定义 / Android 平板 / 对称角色**。现可售"未来全设备互联解锁 / 早鸟" | 文案必须写明"**功能随版本逐步开放**"；entitlement 后端可回收/迁移 |
| **富哥档** | **¥666** | **1 个需求评估 + 可行时优先开发**（非"功能必交付"的 IAP） | 单独服务条款 + 后台工单；**排除违法 / 隐私 / 安全破坏 / 平台不可实现**的需求；不要只靠 App 内一个按钮 |

> 关键产品风险不是技术不可行，而是**承诺边界**：¥66 / ¥666 都涉及未来功能，必须用 entitlement 先占位、
> 文案保守、后端可回收/迁移。技术上可行。

## 2. 为什么 ¥6 的技术卖点 = 低延迟（C 与 Phase 2 合流）

免费档走现有 **TCP** 视频路径（丢包下会卡）；¥6 档解锁 **Phase 2 低延迟通道**
（VIDEO/UDP 或 QUIC + 自适应码率）。这让付费门**真的有可交付内容**，而不是单纯解锁开关。
实现时：低延迟传输由**传输工厂按 entitlement 标志选择**（与现有 role/tunnel 工厂同一模式），
`Session`/`FrameCodec` 不感知档位。

## 3. 身份升级：`peerId` → 设备密钥对

当前 `peerId`（持久化，平板 `DeviceIdentity`；Mac `Session.localPeerId`）适合 **TOFU 显示 + 路由 + 冲突去重**，
但**不能**作为付费授权凭据（明文、可重放）。付费授权需要：

- Mac / Pad **各自生成密钥对**，私钥存 **Keychain / HarmonyOS 安全存储**；后端绑定**公钥**。
- 连接时做 **challenge 签名**（防重放/冒充），授权才认这个设备。
- 授权结果下发为**短期 license token**，Pad 与 Mac **本地缓存**；允许 **7–14 天离线宽限**
  （断网时本地投屏仍可用，避免"没网就不能用"）。

## 4. 账号 + 支付落点

- **Pad 端**：接入 **Huawei Account Kit** 登录 + **Huawei IAP** 付费（商品/订单/订阅管理）。
- **Mac 端**：**不**做华为原生登录。**Pad 登录后作为授权入口**，Mac 通过现有 `peerId` 配对到 Pad；
  后端把 `accountId + macInstallKey + padInstallKey` 绑定。
- **后端**：绑定账号↔设备公钥、签发/校验/回收 license token、记录 entitlement。
  （v0.3 是否需要后端见 §6 —— 可先做**设备本地**最小账号绑定，付费档再上后端。）

## 5. 解耦架构（代码 seam，待实现）

新增独立模块（Mac 与 Pad 镜像），**默认 = 免费档 = 今日行为**，引入时**零行为变化**，
enforcement 按产品决定再逐项打开（避免悄悄削减现有 #51 多连接能力）：

```
Entitlements (model)      tier + 能力位(maxConcurrent, allowedDirections, lowLatency, multiDevice…)
EntitlementProvider       协议；实现：LocalFreeProvider(默认) → 后端/IAP 支撑的 Provider(后续)
        │ 注入于 AppEnvironment（与 tunnelFor/engineFor/policy 同层）
        ▼
被查询：ConnectionCoordinator（并发上限 / 允许方向 / 选低延迟路径）
        传输工厂（按 lowLatency 选 UDP/QUIC vs TCP）
        UI（Supporter 标识 / 付费墙提示）
绝不进：Transport / FrameCodec / Session（线协议与档位无关）
```

## 6. 商业层落地顺序（增量）

| 版本 | 内容 | 我能直接做 / 卡在你 |
|---|---|---|
| **v0.2** ✅ | 有线 + 无线 + 单连接仲裁 + 多卡合并（已验收） | done |
| **v0.3** | 华为账号登录 + 免费档绑定 1 Mac/1 Pad；**只做授权，不做付费**；引入 §5 entitlement seam（非强制） | Pad 账号登录卡在**华为开发者后台配置**（创建 App / Account Kit）。Mac 侧 seam + 配对绑定我可做 |
| **v0.4** | Huawei IAP + ¥6/¥66 entitlement；**¥6 解锁低延迟路径（Phase 2 传输）** | IAP 卡在**华为后台建商品（product id）**；Phase 2 传输 + entitlement 工厂我可做 |
| **v1** | 对称角色 / Android 平板 / 多设备互联，消费 ¥66 能力 | 见 docs/MODULARITY_AUDIT.md #59 |
| **后续** | ¥666 单独 ToS + 后台工单 | 产品/法务，非 App 内按钮 |

## 7. 定位与安全（来自 v0.2 复盘）

- **无线仅限可信家庭/办公 Wi‑Fi**：当前明文 TCP + TOFU 只挡未授权连接，挡不住局域网嗅探重放
  （docs/WIRELESS.md §安全）。**不要建议用户在公共 Wi‑Fi 开无线模式。** TLS + key-based TOFU 属本层（C/Phase 2）。
- **有线复杂环境**：多设备/坞站/DevEco 抢 hdc 会瞬断但不冲突端口；已知边界 = 有线远端口仍硬编码 `8888`
  （`WiredDiscovery.swift`），若 Pad 实际回退到 `8889` 则 Mac 有线连不上。**待办（v0.2 收尾，独立于 C）**：
  有线不静默回退远端口、`8888` 占用直接提示；`hdc fport` 失败自动重试 3 次换本地端口（TOCTOU）。

## 8. 需要你拍板的点

1. **后端**：v0.3 先做**设备本地**账号绑定（无服务器），还是直接上一个最小后端（账号↔公钥↔license）？
2. **华为后台**：何时由你创建 App + 开通 Account Kit / IAP 并产出 product id（v0.3/v0.4 的硬前置）。
3. **免费档是否真的限 1 路**：现有代码已支持多 Pad（#51）。免费限 1 路是**削减现有能力**，确认要这样收口再加 enforcement。
