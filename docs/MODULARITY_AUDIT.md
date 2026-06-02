# Superconnect 模块化 / 解耦审计报告（v1 就绪性）

> 自动审计：19 个 agent · 1,027,177 tokens · 状态 completed

All key references check out against the source. The protocol headers, the `frameSink()` overload comment, and the `ConnectionManager` reach-in at the constructor are exactly as the findings describe. I have enough grounding to write the report.

# Superconnect 模块化 / 解耦审计报告
### 面向 v1（跨平台对称 host/receiver, #59）

---

## 1. 总体结论

Superconnect 的解耦现状可以一句话概括：**UI↔逻辑这一层（视图边界、类型化状态契约、引擎选择 factory）已经做得相当干净且对称，是真正的资产应当保留；但"方向"（dial vs listen）和"角色"（host/receiver）这两条主轴还没有真正进入契约——它们被硬编码进了引擎动词、coordinator 序列、以及 Harmony 端 `Index.ets` 的若干信号里。** 经对抗性复核，原始审计中被标为 at-risk/coupled 的多数条目得到确认，但绝大多数的"v1 前必须修"被下调为"v1 期间随 #59 一起修"——因为当前发布的是纯 receiver/host 单向构型，这些耦合是**潜伏的**（latent），只有在真正实现对端角色引擎时才会触发。唯一确认为 **coupled 且 v1 前必须做契约级重构**的是"连接方向被烤进引擎动词与 coordinator 序列"这一条——它若不先做廉价的、保持行为不变的契约重构，#59 就会被迫同时改动 transport / tunnel / coordinator 三层，正是历史上键盘回归（#80）那种跨模块爆炸半径。下面是评分卡。

| Seam（接缝） | 平台 | 评级 | v1 前必须修 |
|---|---|---|---|
| AppViewModel 作为唯一 UI↔逻辑接缝 | mac | **solid** | 否 |
| 两个 ConnectionEngine 协议各自的对称性 | cross | **mostly** | 否 |
| Host-only 旋钮泄漏进共享协议 | mac | **mostly** | 否 |
| Factory + 组合根选择（"一行翻转"） | cross | **mostly** | 否 |
| UI↔逻辑状态词表两端皆类型化（后 #80） | cross | **mostly** | 否 |
| Mac connect 调用点角色硬编码 | mac | **mostly** | 否（v1 期间） |
| Index.ets 单体（@Entry 并发关注点） | harmony | **mostly** | 否（建议提前） |
| input-capture（ImeCatcher vs InputOverlay）相对显示模式的归属 | harmony | **mostly**（由 at-risk 下调） | 否 |
| 角色协商 desiredRole/acceptedRole 写而不读 | cross | **at-risk**（由 coupled 下调） | 否（v1 期间） |
| ConnectionManager 输入方向假设（frameSink 重载） | harmony | **at-risk** | 否（v1 期间） |
| ConnectionStatus.Streaming 以入站视频为活跃信号 | harmony | **at-risk** | 否（v1 期间） |
| connStatus 同时驱动 display-mode 与 输入挂载 | harmony | **at-risk** | 否（建议提前小修） |
| 输入能力被烤在解码器首帧 Streaming 之后 | harmony | **at-risk** | 否（v1 期间） |
| **连接方向（dial vs listen）烤进引擎动词 / coordinator** | cross | **coupled** | **是（仅契约重构）** |

---

## 2. 哪些 seam 已经解耦得很好（应当保留的真实强项）

这些是架构里真正经得起对抗性审视的部分。把它们记下来，是为了在做 #59 时**不要破坏**它们。

**2.1 Mac `AppViewModel` 是唯一的 UI↔逻辑接缝（solid）**
`mac/.../AppViewModel.swift` 只向视图暴露 `Device` / `ConnectionState` / `SessionTelemetry` 这些值类型加两个 action；所有视图（`DashboardView` / `DeviceDetailView` / `ConnectionToggle` / `StatusDot` / `TransportBadge` / `AdvancedPanel` / `EmptyStateView`）**只 `import SwiftUI`**，从不引用 `SuperconnectCore` / `SuperconnectProducer` / `Transport` / `ConnectionEngine` 等 Core 类型。状态以**封闭枚举** `ConnectionState` 穿过边界并被穷举 switch。**v1 影响：Mac receiver 窗口是一棵全新的视图树，而不是对这些视图的修改——这条接缝零改动即可承接对称角色。** 这是阻止第三次输入回归最好的护栏。

**2.2 两个 ConnectionEngine 协议各自的对称性（mostly，由 at-risk 上调）**
对抗性复核推翻了原审计"两个协议各为对方角色建模、stub 无法直接填"的核心前提。证据在源码注释里：Mac `ConnectionEngine.swift:1-7` 与 Harmony `ConnectionEngine.ets:3-7` 两个协议头都明确声明自己是**方向无关的**（"what a live link DOES, regardless of direction"），抽象的是生命周期（connect/disconnect、start/stop）而非方向。四个 cell（Mac Host 真实 + Receiver stub、Harmony Receiver 真实 + Host stub）**今天都已存在并在零协议增长下编译通过**。`docs/ARCHITECTURE.md` §1/§3 已经是那个"单一来源"，记录了六个共享概念与 Role×Platform 镜像对称矩阵。残留的真实问题只有一个：两套协议的概念对称性没有任何编译器/一致性 harness 能守护——这是 Swift/ArkTS 双语项目固有的、由文档缓解的属性。

**2.3 Host-only 旋钮泄漏进共享协议（mostly）**
`ConnectionEngine.swift:14-19` 确实声明了 `setBitrate` / `setPairingToken` / `setAvoidVirtualInterfaces` 这些 host-only 动词，**但每个都在 extension 里有 no-op 默认实现（:22-30），且参数是纯标量而非 host 类型**。协议里没有出现任何 `Producer` / `VirtualDisplay` / `InputInjector` / `VideoCodec` 类型。`ReceiverConnection` stub 直接继承 no-op 默认，加 host-only 方法**不需要改 receiver**。Harmony 端则零 host-only 泄漏。这是教科书级的"用默认扩展隔离角色专属动词"。

**2.4 Factory + 组合根选择（mostly）**
`ConnectionCoordinator.swift:7` 的 `RoleFactory=(Role)->ConnectionEngine`、Harmony `AppEnvironment.ets:32-34` 的 `engineForRole`——**翻转构造哪个引擎实例确实是每平台一行**。coordinator / policy / tunnels / discovery / views 都不用动。这一选择接缝在形状上是干净且对称的，值得记功。（注意：它只解决"引擎实例选择"，不解决方向/transport/manager 接线——见第 3 节。）

**2.5 UI↔逻辑状态词表两端皆类型化（mostly，后 #80 的真正修复）**
Harmony 以类型化 `ConnectionStatus` 枚举穿过 UI 边界，由类型化 `mapServerStatus` switch（`ReceiverConnection.ets:106-114`）从 `ServerStatus` 枚举产出——**边界上不再有子串匹配**。Mac 以类型化 `ConnectionState` 穿过。这两者都替换掉了导致 #80 回归的自由格式状态字符串。这是回归类问题里**真正被修好的那一半**。

---

## 3. 关键耦合风险（确认的 at-risk/coupled，按优先级排序）

### 🔴 R1 — 连接方向（dial vs listen）烤进引擎动词与 coordinator 序列
- **评级：coupled｜确认：是｜工作量：medium｜v1 前必须修：是（仅契约重构）**
- **现象**：Mac `ConnectionEngine.connect(host:port:)`（`:11`）结构上只能 dial；`SuperconnectCore/Transport.swift` 里唯一的 transport 实现是 client（grep `NWListener/listen/accept/bind` 无结构性命中）；`ConnectionCoordinator.swift:125-131` **无条件** `tunnel.open()→engine.connect(host,port)`，根本没有 listen 路径。Harmony 反过来：`transport/` 目录里只有 `TcpServerTransport.ets`（无 client），`ReceiverConnection.start()` 只会 listen。
- **根因**：方向被编码进了引擎动词本身，而非作为契约的显式一环。两个 `TunnelService` 也是方向镜像（Mac 给 dial target，Harmony 给 bindHost）。
- **v1 影响**：v1 **按平台反转方向**——Mac receiver 必须 listen/accept（平板 host 来拨它），Harmony host 必须 dial out（平板上根本没有 client transport）。所以"一行 factory 翻转"对方向是**错的**：stub 自己的注释就承认 `ReceiverConnection.swift:8-9` 需要全新的 `SuperconnectConsumer` listen/decode 库，`HostConnection.ets:6` 需要 capture/encode 管线 + TCP-client transport。
- **建议**：**现在就做廉价、行为不变的契约重构**——把 Mac 引擎动词从 `connect(host:port:)` 改成方向中立的 `start()`，把 dial-target 解析移进 host 引擎（或引擎自有的方向化策略），让 coordinator 不再硬编码拨号序列；把两个 `TunnelService` 归一为"产出 dial target（host）或 bind address（receiver）"的单一形状，方向分支放进 factory 而非生命周期。真正的 `NWListener` / `TcpClient` transport 体留给 #59。
- **为什么 v1 前必须**：这能把"重写 coordinator"降级为"填 stub + 加库"，避免 #59 同时拉扯 role/transport/protocol 三条接缝——正是历史回归的爆炸半径。重构只碰约 4 个小文件、机械可测（coordinator 已是注入式）。

---

### 🟠 R2 — ConnectionStatus.Streaming 以"入站视频帧到达"作为活跃信号
- **评级：at-risk｜确认：是｜工作量：small｜v1 前必须修：否（v1 期间）**
- **现象**：`ReceiverConnection.ets:48-49` 在 **video 回调里**（每次 `pushVideo`）发出 `Streaming`；`mapServerStatus` 永不发 `Streaming`。页面 `streaming()/windowed()/fullscreen()` 全部从 `connStatus===Streaming` 派生（`Index.ets:124-126`），**所有输入 UI 都门控在它之上**。
- **根因**："会话活跃"与"视频在流动"被压进同一个枚举值，活跃性源自单向解码路径而非角色无关的握手事件。
- **v1 影响**：跨平台已经不一致——Mac `ConnectionState` **根本没有 `.streaming`**，真实 Mac host 在 `HostConnection.swift:294` 的**首个出站编码帧**发出 `.connected`。当 Harmony host stub 变真并镜像 Mac（首个出站帧发 `Connected`、不发 `Streaming`），`streaming()` 将**永远 false**，整棵输入/overlay/fullscreen 子树永不挂载，平板-as-host UI 永久卡在 `IdleView`。
- **建议**：把"link active"与"frames flowing"解耦。引入角色无关的活跃信号（复用已有的 `Connected`），页面输入/overlay/fullscreen 改门控在显式 `live()` 谓词（receiver：Connected-or-Streaming；host：Connected）。`Streaming` 保留为 receiver-only 的显示精修。这是满足硬规则的最小改动。
- **为什么不是 v1 前**：今天 receiver 路径工作正常，破坏只在实现 host 引擎时出现——即 v1 本身。

---

### 🟠 R3 — ConnectionManager 输入方向假设（frameSink 重载）
- **评级：at-risk｜确认：是｜工作量：medium｜v1 前必须修：否（v1 期间）**
- **现象**：`ConnectionManager.ets:28` **无条件** `new FrameInputSender(engine.frameSink())`，所以输入永远经引擎 transport **流出**。`ConnectionEngine.ets:11` 注释直承 frameSink 被重载："receiver: input frames; host: video frames"。`FrameInputSender` 把字节打到 `Channel.INPUT` 和 `CONTROL{type:text}`——这是 receiver 方向（平板捕捉自己的触摸发给 Mac host）。
- **根因**：未类型化的 `(Uint8Array)=>void` 让一个 sink 在不同角色下承载不同 channel 语义；manager 把"输入向外发"烤死成全角色行为。
- **v1 影响**：Harmony host 角色下，输入**不应**发给对端——平板捕捉自己的屏幕发**视频**出去，本地输入驱动平板自身。但 manager 接线是 receiver 形状的，违背"一行翻转"宣称。
- **建议**：镜像 Mac 已发布的设计——Mac `ConnectionEngine` 协议**不暴露 frameSink**，`HostConnection` 内部经 `session.onInput→injector` 处理输入，coordinator 从不构造 input sender。Harmony 应：(a) 把 input-sender 构造移进 `ReceiverConnection`（唯一会把本地输入外发的角色），host 把本地输入路由到平板自身 OS；或 (b) 用方向命名的 channel-tagged sink（`inputSink`/`videoSink`）让错向接线变成编译错误。(a) 杠杆更高，能消除跨层 reach-in、恢复 Mac/Harmony 对称。
- **为什么不是 v1 前**：今天 `engineForRole` 硬编码 Receiver，host 永不被选；正确修法本就是构建真实 host 管线（#59）的内在部分——没有 host capture 路径就无从"把本地输入路由到平板 OS"。

---

### 🟠 R4 — 输入能力被烤在解码器首帧 Streaming 信号之后
- **评级：at-risk｜确认：是｜工作量：small｜v1 前必须修：否（v1 期间）**
- **现象**：全树 grep 确认 `ConnectionStatus.Streaming` **仅在一处发出**——`ReceiverConnection.ets:49` 的 `onVideo` 回调每帧。键盘挂载（`Index.ets:196`）、触摸挂载（`:201`）、fullscreen 资格（`:126`）全部传递性门控在"一个视频帧到达"。
- **根因**：**一个模块的状态（解码器首帧）静默控制另一个模块的能力（输入）**——正是用户硬规则禁止的反模式，与 #80 同族。
- **v1 影响**：host 角色无入站视频，`streaming()` 永远 false，整棵输入子树永不挂载。实现 `HostConnection.ets` 的人**绝不能把 `streaming()` 当作"会话活跃"**。
- **建议**：引入显式 `inputActive()`（link-active + role）谓词门控键盘/触摸/fullscreen，与视频帧派生的 `Streaming` 解耦；receiver 仍可要求 Streaming（零行为变化），host 从其自身生命周期状态解析。这是 #59 内自然且基本必需的工作项。

> R2 与 R4 本质同源（Streaming=首帧入站视频被用作主门控），应在 #59 里**一次性**用同一个 `live()/inputActive()` 谓词解决。

---

### 🟠 R5 — connStatus 同时驱动 display-mode（exitFullscreen 副作用）与 输入/overlay 挂载
- **评级：at-risk｜确认：是｜工作量：small｜v1 前必须修：否（建议提前小修）**
- **现象**：`Index.ets:91-97` 的 `onStatus` 既 `this.connStatus = s`，又在同一回调里 `if (s !== Streaming && fullscreen) exitFullscreen()`。一个信号驱动 display-mode 退出 + windowed/fullscreen 布局 + （传递性）每棵输入子树。
- **根因**：`onStatus` 把"连接状态变化"与"窗口该退出全屏"混为一谈；自动退出在**每个**非-Streaming 值上触发，而非仅终态。
- **v1 影响**：Wi-Fi 漫游时一个瞬态 `ClientGone→Listening` 抖动会把用户**当场踢出全屏**（今天就会）。host 角色经同一 `onStatus` 路由后，任何 Connected-before-Streaming 的再握手都会拽人出全屏。
- **建议**：拆分关注点——`onStatus` **只**更新 `connStatus`；"是否自动退全屏"改由**终态**显式谓词（`Failed`/`Idle`）派生，而非 `s !== Streaming`。这是廉价的预防性小修，**建议在 host 引擎工作之前/随之落地**（它已经在今天的 Wi-Fi 漫游上误动作）。把输入门控改到显式角色谓词那部分留给 #59。

---

### 🟡 R6 — 角色协商 desiredRole/supportedRoles/acceptedRole：写而不读
- **评级：at-risk（由 coupled 下调）｜确认：是｜工作量：medium｜v1 前必须修：否（v1 期间）**
- **现象**：Mac `Session.swift:94-95` 硬编码 `supportedRoles:["host"]/desiredRole:"host"`；`:156` 把 `acceptedRole` 解析进 `peerAcceptedRole`（`:20`），**全代码库零读者**。Harmony `Session.ets:256-257` 硬编码 `['receiver']/'receiver'`，`onHello` 从不读 `msg.desiredRole`。调用点是 `AppViewModel.swift:120` 的 `.host` 字面量，`AppEnvironment.swift:20` 的 `engineFor:{ _ in HostConnection() }` 丢弃 Role 参数。
- **根因**：协商是个**门面**——发起方默认 host、应答方默认 receiver；`'host'/'receiver'/'mac'/'pad'` 是各端独立硬编码的裸字符串，**无 enum↔wire 编解码、无 `proto/vectors.json` 覆盖**。这是与 #80 同级的最高 stringly-typed 风险类。
- **为何由 coupled 下调为 at-risk**：(1) 原审计"两端 factory 都丢 Role"是 **Mac-only** 高估——Harmony `engineForRole` **确实**按类型枚举分派（`AppEnvironment.ets:33`）。(2) 今天没有任何东西被实际破坏——协商值是惰性死值，不驱动任何关注点；不存在一次编辑就能触发的活跃跨模块耦合（不同于 #80）。这是潜伏的 stringly-typed 分歧风险，恰是 at-risk。
- **建议**：在 #59 里引入**单一类型化 Role↔wire-string 编解码**两端镜像（同 `ReceiverConnection.ets:106` 修复 #80 的类型化 switch 模式），向 `proto/vectors.json` 加握手角色 golden vector 让 conformance harness 守护大小写/拼写漂移，闭环（应答方读 `desiredRole`、对 `RoleCapabilities` 校验、回绑定 `acceptedRole`、两端经 factory 用协商角色选引擎，Mac 先让 `engineFor` 像 Harmony 那样真正分派）。**唯一值得现在做的零成本防御**：删除或标注死的 `peerAcceptedRole` 解析，免得未来读者信任一个对端从未有意设置的值。

---

### 🟡 R7 — Mac connect 调用点角色硬编码（mostly）
- **评级：mostly｜工作量：localized｜v1 前必须修：否（v1 期间）**
- **现象/根因**：`AppViewModel.toggleConnection(for:)` 用字面量 `.host` 调 `coordinator.connect(device, as: .host)`（`:120`）；UI 没有方向选择器，不读设备 capabilities。
- **v1 影响**：因为接缝已经是**类型化 `Role` 参数**（非字符串），这是局部改动：给 `toggleConnection` 加 Role + 在 `ConnectionToggle` 加门控在 `Device.capabilities` 的方向控件。接缝形状正确，只是值被硬编码。
- **建议**：`Role` 端到端保持枚举、视图里永不出现字符串；视图模型暴露 `availableRoles(for:)`（从 `Device.capabilities` 派生）让 UI 只提供有效方向。

---

### 🟡 R8 — Index.ets 单体（mostly）
- **评级：mostly｜工作量：small-medium｜v1 前必须修：否（强烈建议提前）**
- **现象**：`Index.ets` ~320 行，作为 @Entry 集中了 connStatus / displayMode / 绘制模式 / surface 尺寸 / 悬浮球几何 / 面板可见性 / input-disabled / 分辨率·codec 镜像 / 无线开关·IP / 配对对话框 / 监听端口 / 已配对列表 / exit-fullscreen watcher。**但重逻辑已抽走**（`WindowController` 拥窗口副作用、`ConnectionManager` 拥生命周期、`AppEnvironment` 是组合根，各视觉块独立组件），所以它是 coordinator/view-state binder 而非逻辑单体。
- **v1 影响**：它是 v1 平板-host 必改的**单一地点**——receiver 形状（status→displayMode 副作用、streaming()-门控输入、ConnectionManager 无条件造 outbound sender）都烤在这里。关注点越集中，v1 编辑越大、把输入重新耦合到显示的概率越高（历史失败模式）。
- **建议**：v1 前抽出一个小 view-state 对象（镜像 Mac `AppViewModel` 的 `PresentationModel`），拥 `connStatus/displayMode` 并暴露**派生、互相独立**的谓词（`linkActive`、`inputEnabled`、`displayMode`），让页面只渲染、status→displayMode 耦合集中在一处可测的地方。继续用 per-chunk 组件拆分。

---

### ⚪ R9 — ImeCatcher vs InputOverlay 相对显示模式的归属（mostly，由 at-risk 下调）
- **评级：mostly（下调）｜确认：否｜工作量：trivial｜v1 前必须修：否**
- **下调理由**：事实准确（ImeCatcher 门控 `streaming()`、InputOverlay 门控 `fullscreen()`），但 at-risk 评级不成立。(1) **windowed 不转发输入是显式产品规格**，非耦合——`DisplayMode.ets:2`、`WindowedView.ets:5` 都明说 windowed 是被动预览（~72% 居中预览框，其自身双击手势=进全屏，在那里捕捉触摸是不自洽的）。(2) **不对称实为功能对称**：ImeCatcher 在 windowed 是 `.focusable(false)`，同样不捕捉键盘——两条路径在 windowed 都惰性；唯一差别是机制（mount-vs-focus），由 ArkUI 对条件挂载 `TextInput` 的 late-mount 聚焦失败（#53）所迫。(3) "瞬态状态抖动"攻击向量**已在根上消除**（commit `74a7b0e` 用类型化 `ServerStatus` 枚举 + switch 替换子串映射、并移除多余 emission）——要复现"display-mode bounce"得重新引入一个结构上已移除的 bug。
- **唯一建议**：在 `Index.ets:201` 的 InputOverlay/fullscreen() 门控上加一条 inline "why" 注释（镜像 `ImeCatcher.ets:8-16`），说明触摸捕捉**有意**限定在 fullscreen、键盘的 mount-on-streaming() 不对称仅为绕开 #53 聚焦 quirk——免得未来开发者"好心"把两条路径耦合起来。**不要**把 InputOverlay 拆成 mount-vs-capture（会让预览框捕捉触摸、与其双击手势冲突）。

---

## 4. 进入 v1 前的优先级清单

### 必须在 v1 前做（pre-#59 gate）
1. **[R1] Mac 引擎/tunnel 契约的方向化重构**（medium，行为不变）：`connect(host:port:)` → 中立 `start()`；dial-target 解析移进 host 引擎；两个 `TunnelService` 归一；方向分支进 factory。**这是唯一真正阻塞的项**——它把 #59 从"三层同改"降为"填 stub + 加库"。
2. **[R8] 抽出 Harmony `PresentationModel`**（small-medium，强烈建议）：把 `connStatus/displayMode` 与派生谓词移出 `Index.ets`，为后续所有 Harmony 角色改动提供单一、可测的接缝。降低 v1 编辑撞坏输入门控的概率。
3. **[R5] `onStatus` 副作用拆分 + 终态化自动退全屏**（small，预防性）：让 `onStatus` 只更新 `connStatus`，自动退全屏改由 `Failed/Idle` 终态谓词驱动。**它今天就在 Wi-Fi 漫游上误动作**，且为 host 路由扫清结构隐患。
4. **[R6 零成本部分] 删除/标注死的 `peerAcceptedRole` 解析**（trivial）：免得未来读者信任一个从未被有意设置的值。

### v1 期间做（#59 的内在范围，不要提前也不要遗漏）
5. **[R2+R4] 用单一 `live()/inputActive()` 谓词替换 `streaming()` 主门控**（small）：把"link active"与"frames flowing"解耦；receiver 保持现行为，host 从自身生命周期解析。
6. **[R3] 输入方向归角色内部所有**（medium）：把 input-sender 构造移进 `ReceiverConnection`（或改 channel-tagged typed sink），host 把本地输入路由到平板 OS——镜像 Mac 的 `session.onInput→injector` 设计。
7. **[R6 闭环部分] 类型化 Role↔wire 编解码 + golden vectors + 协商闭环**（medium）：两端镜像、`proto/vectors.json` 守护、Mac `engineFor` 真正按 Role 分派。
8. **[R7] Mac UI 角色选择**（localized）：`toggleConnection` 加类型化 `Role` 参数 + `availableRoles(for:)`。
9. **新 transport 体**（#59 实际重量）：Mac `SuperconnectConsumer`（NWListener/accept/decode）、Harmony `TcpClientTransport`、两端 capture/encode 或 decode/display 管线。

### Nice-to-have（文档/防御，低风险）
10. **[R9] InputOverlay 门控加 "why" 注释**（trivial），记录有意的键盘/触摸不对称。
11. **[R2.3 / 强项] 文档化**：在 `ConnectionStatus` 枚举上注明 `Streaming` 特指"入站视频在流动"；在 `ARCHITECTURE.md §1` 表格加一行显式列出 `ConnectionEngine` 动词集，让未来漂移可对照评审。
12. **[host-only 旋钮纪律]** 把 no-op-default 规则写在协议旁；考虑把 host-only 旋钮收进一个 `HostTuning` capability，coordinator 仅在 `role==.host` 时调用，移除其隐含 host 假设。

---

## 5. 复发防护（防止第三次输入风格回归的横切原则）

前两次输入回归（#53 聚焦 quirk、#80 状态字符串误映射→输入门控）有共同 DNA：**一个模块的信号/状态越过类型边界，去控制另一个模块的能力。** 下面三条原则直接针对这个 DNA。

**5.1 类型化的模块间契约（typed inter-module contracts）——绝不靠"约定字符串"跨边界**
- #80 的根因是自由格式状态字符串；修复是类型化 `ConnectionStatus`/`ConnectionState` 枚举。**这条已经在 UI 边界做对了，要扩展到所有剩余边界。**
- 最大未类型化残留：(a) 角色 wire-string（`'host'/'receiver'/'mac'/'pad'` 各端硬编码，R6）；(b) `frameSink():(Uint8Array)=>void` 一个 sink 在不同角色承载不同 channel 语义（R3）。
- **规则**：任何跨模块/跨 wire 的值都要有单一类型化编解码两端镜像，并在 `proto/vectors.json` 里有 golden vector 让 conformance harness 守护。错值应是编译错误或 vector 失败，而不是静默的跨模块破坏。

**5.2 单一用途信号（single-purpose signals）——一个信号只表达一件事**
- 当前两个最危险的重载：(a) `Streaming` 同时表达"会话活跃"与"视频在流动"（R2/R4）；(b) `onStatus` 同时驱动连接状态、display-mode 退出、输入挂载（R5）。这正是 #80 的"一个状态转移驱动 display+input 门控"形状，只是现在是类型化枚举（更安全，但重载本身仍在）。
- **规则**：派生谓词（`linkActive` / `inputEnabled` / `displayMode` / `videoFlowing`）必须**互相独立**、各有单一来源。`DisplayMode` 要与 `ConnectionStatus` 完全正交（`DisplayMode.ets:1` 注释已这么宣称——要让代码兑现）。增加 host 角色状态时，**加显式枚举 case**，绝不复用 `Streaming/Connected` 赋予新含义。

**5.3 能力归属独立（independent capability ownership）——能力 X 不被模块 Y 的状态门控**
- 反模式：输入能力（一个模块）被解码器首帧（另一个模块）门控（R4）；触摸捕捉挂载被 display-mode 门控（R9 的残留对称性问题）。
- **规则**：每个能力（输入捕捉、显示模式、视频流、链路活跃）由其**自身**的、角色感知的谓词拥有，且该谓词不传递性依赖另一能力的内部数据流。键盘与触摸两半必须门控在**同一个**独立谓词上，让它们永不再次分叉。Mac 端的纪律——**视图永不 `import` Core/Producer、host-only 动词进 extension 默认**——是这条原则的活样板，应在 Harmony 端镜像（先给 Harmony `ConnectionEngine.ets` 上 host-only 方法之前补齐默认扩展模式）。

**一句话护栏**：做 #59 时，把"引擎选择（一行）"和"角色启用（新 transport + consumer + manager 重接线）"在文档和心智里**分开计帐**——`AppEnvironment` 注释里的"一行翻转"对引擎实例选择结构上为真，但对启用一个能工作的角色实质性不完整。这个清醒认识本身，就是防止第三次回归的第一道防线。

---

涉及的关键文件（均为仓库内相对根 `/Users/geminihe/Desktop/superconnect`）：
- `mac/Sources/superconnect-app/Services/Connection/ConnectionEngine.swift`、`ConnectionCoordinator.swift`
- `mac/Sources/superconnect-app/Services/Connection/role/`（`HostConnection.swift` `:294`、`ReceiverConnection.swift` `:7-9`）
- `mac/Sources/superconnect-app/ViewModels/AppViewModel.swift`（`:120`）、`App/AppEnvironment.swift`（`:20`）、`Net/Session.swift`（`:94-95,156`）
- `mac/Sources/SuperconnectCore/Transport.swift`、`Models/ConnectionState.swift`
- `harmony/entry/src/main/ets/services/connection/ConnectionEngine.ets`（`:11`）、`role/ReceiverConnection.ets`（`:48-49,106-114`）、`role/HostConnection.ets`（`:12,17`）
- `harmony/entry/src/main/ets/services/ConnectionManager.ets`（`:25,28`）、`app/AppEnvironment.ets`（`:32-35`）、`net/Session.ets`（`:256-257`）
- `harmony/entry/src/main/ets/pages/Index.ets`（`:91-97,124-126,196,201-203`）、`components/ImeCatcher.ets`、`InputOverlay`、`WindowedView.ets`、`models/ConnectionStatus.ets`、`models/DisplayMode.ets`
- `docs/ARCHITECTURE.md`（§1、§3）、`proto/vectors.json`、`tools/arkts-conformance.mjs`


---

## 附录 A · 解耦记分卡（结构化）

- **seam**: ConnectionEngine protocol — symmetry of the two protocols themselves · **platform**: cross · **decoupling**: at-risk
- **seam**: Direction of connection (dial vs listen) baked into the engine verb · **platform**: cross · **decoupling**: coupled
- **seam**: Host-only concerns leaking into the SHARED engine protocol · **platform**: mac · **decoupling**: mostly
- **seam**: Role negotiation (desiredRole/supportedRoles/acceptedRole) — written but never read · **platform**: cross · **decoupling**: coupled
- **seam**: ConnectionManager input direction assumption (frameSink overload) · **platform**: harmony · **decoupling**: at-risk
- **seam**: ConnectionStatus.Streaming gated on inbound video (receiver-only liveness signal) · **platform**: harmony · **decoupling**: at-risk
- **seam**: Factory + composition-root selection (the claimed one-line swap) · **platform**: cross · **decoupling**: mostly
- **seam**: Mac: AppViewModel as the sole UI↔logic seam · **platform**: mac · **decoupling**: solid
- **seam**: Mac: role is hardcoded at the only connect call site (UI→logic role contract) · **platform**: mac · **decoupling**: mostly
- **seam**: HarmonyOS: connStatus overloaded to drive BOTH display-mode AND input gating · **platform**: harmony · **decoupling**: at-risk
- **seam**: HarmonyOS: input-capture (ImeCatcher vs InputOverlay) ownership relative to display-mode · **platform**: harmony · **decoupling**: at-risk
- **seam**: HarmonyOS: input capability gated behind the video decoder's state (Streaming = first frame) · **platform**: harmony · **decoupling**: at-risk
- **seam**: HarmonyOS: Index.ets monolith — concern count in a single @Entry component · **platform**: harmony · **decoupling**: mostly
- **seam**: Cross-platform: UI↔logic status vocabulary is typed on both ends (post-#80) · **platform**: cross · **decoupling**: mostly

## 附录 B · 已确认的耦合风险（结构化）

1. **seam**: Direction of connection (dial vs listen) baked into the engine verb / coordinator sequence · **confirmed**: True · **adjustedRating**: coupled · **v1Blocking**: True · **effort**: medium · **bestRecommendation**: Make direction explicit in the Mac engine/tunnel contract by mirroring what Harmony already does. Replace the Mac `ConnectionEngine.connect(host:port:)` verb with a direction-neutral `start()` and move dial-target resolution INTO the host engine (or a direction-typed strategy the engine owns), so the coordinator stops hard-coding `tunnel.open()→engine.connect(host,port)` (ConnectionCoordinator.swift:125-131). Generalize the two TunnelService protocols to a single shape that yields either a dial target (host) or a bind address (receiver), and branch on Role in the factory — not in the lifecycle. This converts the future receiver from "rewrite the coordinator" into "fill the stub + add the SuperconnectConsumer listen lib," and likewise the Harmony host into "fill the stub + add a TcpClientTransport." Do the contract refactor now (cheap, no behavior change); defer the actual NWListener/TcpClient transport bodies to #59. · **reasoning**: Every cited line checks out against the code. Mac ConnectionEngine.swift:11 is `connect(host:port:)`; SuperconnectCore/Transport.swift's only impl (TcpTransport) is dial-only — grep for NWListener/listen/accept/bind returns no structural match (the lone hit is a `peerAcceptedRole` substring false-positive). ConnectionCoordinator.swift:125-131 unconditionally does `tunnel.open()` → `engine.connect(dial.host, dial.port)`; there is NO listen code path, so the coordinator itself assumes dial-out. Harmony's transport/ dir contains ONLY TcpServerTransport.ets (no client), and ReceiverConnection.start() (42-63) listens via server.listen(). The two TunnelService protocols are direction mirror-images: Mac returns (host,port) to dial; Harmony returns bindHost() to bind. The "one-line factory flip" claim (AppEnvironment.swift:20, AppEnvironment.ets:10 comments) is contradicted by the stubs' OWN comments: ReceiverConnection.swift:8-9 needs "a new SuperconnectConsumer library" with a listen/decode path, and HostConnection.ets:6 needs "a capture/encode pipeline + a TCP-client transport." So enabling symmetric roles is genuinely NEW transport code on both sides plus a direction-aware coordinator — not a stub fill-in behind one factory line. I tried to downgrade via the strongest counter-argument: Harmony's ConnectionEngine.ets uses a direction-NEUTRAL start() (no host/port), so maybe the seam is fine. But that cuts the other way — the Mac engine contract is ALREADY divergent from Harmony on exactly this axis, proving the asymmetry is real and the better (neutral) design already exists on one side. The "coupled" rating holds. Given the project's hard rule that one module's change must not break another, leaving direction hard-coded in the coordinator means #59 will force edits across transport, tunnel, AND coordinator simultaneously — precisely the cross-module blast radius that caused the prior keyboard regressions. The contract refactor is cheap and behavior-preserving; doing it before #59 lands is what keeps the role/transport/protocol seams from being stressed all at once. I keep v1Blocking=true but only for the contract/seam refactor — the heavy transport bodies (NWListener, TcpClient) are #59's actual scope and need not precede it. Effort is medium: the refactor touches ~4 small files but is mechanical and testable with fakes (the coordinator is already injection-based).
2. **seam**: Role negotiation (desiredRole/supportedRoles/acceptedRole) — written but never read · **confirmed**: True · **adjustedRating**: at-risk · **v1Blocking**: False · **effort**: medium · **reasoning**: Every factual claim verified against source. Mac Session.swift:94-95 hardcodes supportedRoles:["host"]/desiredRole:"host"; line 156 parses acceptedRole into peerAcceptedRole (line 20) which has ZERO source readers (only the decl, the assignment, and dSYM artifacts match). Harmony Session.ets:256-257 hardcodes supportedRoles:['receiver']/acceptedRole:'receiver' and onHello never reads msg.desiredRole (it's only a type-decl field on line 51; onHello reads msg.role solely for a log string). Mac call site is the .host literal at AppViewModel.swift:120 and AppEnvironment.swift:20's engineFor:{ _ in HostConnection() } drops its Role param. So role negotiation today is genuinely a facade: initiator assumes host, responder assumes receiver, and the wire strings ('host'/'receiver'/'pad'/'mac') are bare literals each side hardcodes independently with NO enum-wire codec and NO coverage in proto/vectors.json (which holds only frame-encoding + input-record vectors). That is the same stringly-typed risk class as regression #80.

TWO corrections that justify downgrading coupled->at-risk: (1) The finding's claim that engineFor ignores Role is Mac-ONLY. Harmony's engineForRole DOES dispatch on a typed enum (AppEnvironment.ets:33: role === Role.Host ? new HostConnection() : receiver), so the cross-platform 'both factories drop Role' framing is overstated. (2) Nothing is actively broken today — the negotiated values are inert/dead, not driving any concern. There is no live cross-module coupling that one edit could trip (unlike #80, where a status string actually flowed into UI gating). This is latent divergence risk in a stringly-typed contract, which is precisely 'at-risk', not 'coupled'.

NOT v1-blocking: Task #59 is pending and long-term, and explicitly lists 'the v2 handshake (#50, peerId + role negotiation)' as a prerequisite it builds upon. Role negotiation is groundwork for v1, not a precondition of it; everything shipping today (through Inc6/BLE/conflict work) is host-only by design and unaffected. The loop must be closed AS PART of v1's symmetric-role work, not before it. · **bestRecommendation**: When v1 symmetric roles are implemented (#59): introduce a single typed Role<->wire-string codec mirrored on both ends (the same pattern as the ServerStatus->ConnectionStatus typed switch at ReceiverConnection.ets:106 that fixed #80), add handshake-role golden vectors to proto/vectors.json so the conformance harness guards against casing/typo drift, and close the loop so the responder reads desiredRole, validates it against its RoleCapabilities, returns a binding acceptedRole, and BOTH ends select the engine from the negotiated role via the factory (Mac must first make engineFor actually dispatch on Role like Harmony already does). Until #59 starts, the only zero-effort defensive fix worth taking now is deleting or marking the dead peerAcceptedRole parse so a future reader can't trust a value the other side never meaningfully sets.
3. **seam**: ConnectionManager input direction assumption (frameSink overload) · **confirmed**: True · **adjustedRating**: at-risk · **v1Blocking**: False · **effort**: medium · **bestRecommendation**: Mirror the Mac's already-shipped design: make input direction an INTERNAL responsibility of the engine, not something ConnectionManager assembles from a raw byte sink. The Mac ConnectionEngine protocol (mac/.../Connection/ConnectionEngine.swift) deliberately exposes NO frameSink — HostConnection handles input via session.onInput→injector internally, and the coordinator never builds an input sender. Harmony diverged: ConnectionManager.ets:28 reaches into engine.frameSink() to build FrameInputSender, baking the receiver direction (local input → out to peer) into the role-agnostic manager. Concretely, when the real Harmony host pipeline lands (#59), do NOT build the outbound InputSender from frameSink() unconditionally. Either (a) move the input-sender construction inside ReceiverConnection (the only role that sends local input out) and have HostConnection route local input to the tablet's own OS, exposing input via a role-internal seam rather than the manager; or (b) replace the untyped frameSink():(Uint8Array)=>void with direction-named, channel-tagged sinks (inputSink for receiver, videoSink for host) so a wrong-direction wiring is a compile error rather than a silent mis-send. Option (a) is the higher-leverage fix because it eliminates the cross-layer reach-in entirely and restores the Mac/Harmony symmetry the architecture claims. · **reasoning**: Every cited fact checks out against the code: ConnectionManager.ets:28 unconditionally does `new FrameInputSender(engine.frameSink())`; ConnectionEngine.ets:11 comment literally states the sink means "receiver: input frames; host: video frames"; FrameInputSender frames onto Channel.INPUT (line 24) and CONTROL{type:text} (line 31); HostConnection.ets:17 returns a no-op sink; AppEnvironment.ets:12-13 and HostConnection.ets:7 both claim host enablement is a one-line factory flip with "no other layer changes." The Mac mirror is the decisive evidence that the finding's architectural read is correct: Mac's ConnectionEngine protocol exposes no frameSink and keeps input ownership inside HostConnection (onInput→injector), with host-only concerns isolated behind no-op protocol-extension defaults — so the Mac genuinely IS close to a one-line factory flip, while Harmony is NOT, because its manager is receiver-shaped via the reach-in. The frameSink overload is exactly the "stringly-typed-by-convention inter-module contract" and "one signal driving two concerns" pattern the user's hard rule targets, and it is in a seam (host/receiver/transport) that v1 (#59) will stress directly. So the seam is real, not a false alarm — rating stays at-risk. I DID NOT escalate to "coupled" and I did NOT keep it as a v1 precondition for two reasons grounded in the code: (1) present-day mis-send risk is zero — engineForRole(Role.Receiver) is hardwired at AppEnvironment.ets:35 so host is never selected, and even if it were, HostConnection.frameSink is a no-op; the input handlers (Index.ets:103-105 → KeyboardHandler/InputRouter) only fire on the tablet's own local touch/pen/key events, so nothing auto-pumps wrong-direction frames. (2) The correct fix is intrinsically part of building the real host pipeline (#59 host engine), not a standalone refactor that must precede it — you cannot meaningfully "route local input to the tablet's OS" until the host capture path exists. Hence v1Blocking=false: it must be addressed DURING v1 host work, but is not a precondition to starting it. Effort is medium: option (a) relocates input-sender construction out of ConnectionManager into the receiver role and threads the sender to the page through a role-aware seam (the page currently calls mgr.sender() directly), which is a contained but multi-file change touching ConnectionManager, the engine interface, ReceiverConnection, and Index.ets wiring.
4. **seam**: ConnectionStatus.Streaming gated on inbound video (receiver-only liveness signal) · **confirmed**: True · **adjustedRating**: at-risk · **v1Blocking**: False · **effort**: small · **reasoning**: Verified line-by-line and the finding holds. ReceiverConnection.ets:48-49 emits ConnectionStatus.Streaming inside the VIDEO callback (on each pushVideo) — liveness is sourced from the inbound decode path. mapServerStatus (106-114) tops out at Connected/Listening and never emits Streaming (comment line 105 confirms this is intentional). The page derives streaming()/windowed()/fullscreen() from connStatus===Streaming (Index.ets:124-126), and ALL input UI is gated on it: ImeCatcher/keyboard (196), InputOverlay/touch + FloatingBall (201-220, via fullscreen()), WindowedView (228); !streaming() pins the page to IdleView (236). So 'a video frame arrived' is the de-facto 'session is live' predicate.

Cross-platform evidence makes this concrete, not hypothetical. The two platforms ALREADY disagree on what 'live' means: Mac ConnectionState (Models/ConnectionState.swift) has NO .streaming case at all — the real Mac HOST tops out at .connected, emitted from onEncoded on the first OUTBOUND encoded frame (HostConnection.swift:294), not from any inbound data. Harmony's host is currently a stub (HostConnection.ets) that only emits .Failed (line 12), and its own comment says implementing it is the v1 path. When that stub becomes real and mirrors the Mac host (emit Connected on first outbound frame, no Streaming), streaming() stays false forever, !streaming() stays true, and the input/overlay/fullscreen subtree never mounts — the tablet-as-host UI is permanently stuck on IdleView. This is a textbook instance of the user's HARD rule violation class: a capability (input) gated behind one direction's data flow, and one signal (Streaming) conflated with two concerns (link-active vs frames-inbound). It is the same family as the #80 regression (status channel mis-driving input gating).

Not downgrading: the evidence is direct and the symmetric-roles work (#59, confirmed pending) is exactly what stresses this seam. But the rating is at-risk, not coupled, because today's shipping receiver path works correctly — the break only manifests when the host engine is implemented, which is v1 itself.

Not v1-blocking in the 'fix before starting v1' sense: the defect lives inside the v1 host-engine work, not in code that must be hardened beforehand. You cannot ship tablet-as-host without resolving it, so it is IN scope for #59, but there is nothing to fix pre-emptively on the current receiver-only build. · **bestRecommendation**: Decouple 'link active' from 'frames flowing'. Introduce a role-agnostic liveness signal raised from the session/handshake (ConnectionStatus.Connected already exists and is what the Mac host uses on first outbound frame), and re-gate the page's input/overlay/fullscreen mounting on an explicit 'session active for this role' predicate — for the receiver: Connected-or-Streaming; for the host: Connected (first outbound frame). Keep Streaming as a receiver-only refinement (frames inbound) used for display polish, not as the gate that mounts the entire input subtree. Concretely: change Index.ets streaming()/windowed()/fullscreen() to test a live() predicate that is true for both Connected and Streaming, so the host engine (which mirrors Mac by emitting Connected, not Streaming) mounts input correctly. This is the smallest change that satisfies the HARD rule without touching the engine-by-engine status emission semantics.
5. **seam**: HarmonyOS Index.ets: connStatus overloaded to drive BOTH display-mode (exitFullscreen side-effect) AND input/overlay/keyboard mounting · **confirmed**: True · **adjustedRating**: at-risk · **v1Blocking**: False · **effort**: small · **bestRecommendation**: Split the two concerns inside onStatus, and make auto-exit fire only on TERMINAL states. Change Index.ets:91-97 so onStatus does ONLY `this.connStatus = s`, and derive fullscreen auto-exit from an explicit predicate over terminal states (e.g. `s === Failed || s === Idle`) instead of `s !== Streaming`. This both stops the Wi-Fi-roam ClientGone->Listening blip from yanking the user out of fullscreen (real today) and removes the structural overload before v1's HostConnection routes through the same callback. Defer recommendation #2 (gate input on an explicit `link-active AND role==receiver` predicate rather than `streaming()`) to the actual v1 host-engine task (#59) — it cannot be done meaningfully until HostConnection exists and a Role signal reaches the page, and the page-level `streaming()` gate is correct for the only role shipping today. · **reasoning**: Every cited fact checks out against the code. Index.ets:91-97 confirms onStatus both sets connStatus and calls exitFullscreen() on ANY `s !== Streaming` while fullscreen. Index.ets:124-126 confirms streaming()/windowed()/fullscreen() all key off connStatus, and the ImeCatcher (line 196, gated on streaming()) + InputOverlay/FloatingBall (lines 201-203, gated on fullscreen()) confirm input/overlay are transitively gated on the one connStatus signal. So one signal genuinely drives display-mode exit + layout + input availability — a real instance of the user's hard rule against one-signal-two-concerns, and structurally the same family as regression #80 (verified via task #80: a status transition driving display+input gating). The finding is honest that the typed enum + typed mapServerStatus switch (ReceiverConnection.ets:106-114) already closed the *stringly-typed mis-map* sub-class from #80; what remains is the overload itself, which is accurate.

v1 routing is confirmed real, not speculative: ConnectionManager.ets:25 pipes EVERY engine's onStatus straight to the page callback, HostConnection.ets:12 emits Failed through that identical path, and Streaming is only ever emitted on a received video frame (ReceiverConnection.ets:49) — which a host never produces. So a future host role would (a) never mount the input/overlay subtree (streaming() stays false) and (b) have any non-Streaming status auto-exit fullscreen. Both are genuine structural consequences.

I downgrade the finding's implicit urgency on ONE point: v1Blocking is false. HostConnection is a stub returning Failed and engineForRole is hardcoded to Receiver (AppEnvironment.ets:35), so today the only live symptom is the transient-disconnect fullscreen-exit blip — a minor UX bug, not a keyboard-kill. The keyboard/host-mounts-nothing failure only materializes when someone implements HostConnection and flips the factory, i.e. DURING task #59, not before it. So the recommended split is a small, cheap pre-emptive fix that should land before/with the host engine work, but it does not block the current branch. Rating stays at-risk (not downgraded to mostly/solid): the overload is a confirmed live coupling that already misbehaves on Wi-Fi roam and sits directly on the v1 stress path the user flagged. Rating is not upgraded to coupled because the dangerous mis-map vector is already typed-closed and no module is currently broken.
6. **seam**: HarmonyOS input capability gated behind the decoder's first-frame Streaming signal · **confirmed**: True · **adjustedRating**: at-risk · **v1Blocking**: False · **effort**: small · **bestRecommendation**: Introduce an explicit link-active + role predicate (e.g. inputActive()) that gates ImeCatcher/keyboard, InputOverlay/touch, and fullscreen eligibility — decoupled from the video-frame-derived Streaming. Keep Streaming purely for the 'video flowing' indicator. For the receiver role this predicate can still require Streaming (preserving today's behavior with zero behavior change); for the host role it resolves from the host engine's own lifecycle status, so the capture-side input tree can mount without any inbound video frame. This is the natural, and arguably required, work item inside #59 (symmetric host/receiver) rather than a separate fix. · **reasoning**: Every cited line verified against source. streaming() === ConnectionStatus.Streaming (Index.ets:124). A grep across the whole ets/ tree confirms ConnectionStatus.Streaming is EMITTED in exactly one place — ReceiverConnection.ets:49, inside the onVideo callback on each decoded frame; the typed mapServerStatus (106-114) never returns it and the comment at line 105 says so explicitly. Keyboard mounts on `if (this.streaming())` (196); touch (InputOverlay, 201) and the FloatingBall/overlay subtree mount on `if (this.fullscreen())`, and fullscreen() === streaming() && Fullscreen (126). So all input/overlay mounting is transitively gated on 'a video frame arrived'. HostConnection.ets is a stub that emits ConnectionStatus.Failed on start (line 12) and never emits Streaming, so under a host role streaming() is permanently false and the entire input subtree never mounts — the v1Impact claim is correct. The recurring-pattern premise also checks out: the two cited regressions are real (commit 74a7b0e 'keyboard+touch dead after single-active rejection (status coupling)' and #53), and this is the same anti-pattern the user's hard rule forbids — one module's state (decoder first-frame) silently controlling another module's capability (input). Rating held at at-risk (not coupled): today the receiver is the only wired role (AppEnvironment.ets:35 hard-codes Role.Receiver, engineForRole branch never takes Host), so there is no LIVE breakage — the coupling is latent, surfacing only when the symmetric host role of #59 is implemented. Not v1-blocking as a prerequisite, because #59 (the host role) is still pending and HostConnection is a stub; the fix is work performed AS PART OF #59, not a gate in front of it. Whoever implements HostConnection must not treat streaming() as 'session is live' — that is the trap, and it should be neutralized in the same change that wires the host engine.