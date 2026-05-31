# Superconnect 线协议（Wire Protocol）v1

> 本文件是**双端唯一事实源**。macOS 端（Swift）、HarmonyOS 端（ArkTS / 后续 C++）的实现都必须符合本规范。
> 修改协议须：①改本文件 ②改 `proto/vectors.json` 黄金向量 ③两端实现与测试同步更新。

## 0. 设计目标
- 传输无关：协议只要求底层提供**一条 可靠 / 有序 / 双向 的字节流**（一个 TCP 连接即可）。
- 有线（`hdc fport` 经 USB）与无线（局域网 TCP）**用完全相同的协议与代码**，只有"连谁"不同。
- 在一条连接上**多路复用**多个逻辑通道（视频 / 输入 / 控制 …），各通道独立背压与丢弃策略。

## 1. 帧格式（Frame）
每条消息是一帧。固定 6 字节头 + 变长负载：

```
 0        1        2        3        4        5        6 ............ 6+len
+--------+--------+--------+--------+--------+--------+-------------------+
|channel | flags  |          length (u32, little-endian)               |   payload (length bytes)
+--------+--------+--------+--------+--------+--------+-------------------+
| u8     | u8     | byte0    byte1    byte2    byte3 |                   |
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `channel` | u8 | 逻辑通道 ID（见 §2） |
| `flags` | u8 | 位标志（见 §3） |
| `length` | u32 LE | `payload` 字节数 |
| `payload` | bytes | 负载，长度 = `length` |

- 字节序：`length` 为**小端**。
- `MAX_FRAME_PAYLOAD = 16 MiB`（16777216）。超过即协议错误，应断开。
- 头长 `FRAME_HEADER_SIZE = 6`。

## 2. 通道（channel）
| 值 | 名称 | 方向 | 说明 |
|---|---|---|---|
| 0 | `CONTROL` | 双向 | 握手、能力协商、心跳、时钟同步、关闭。Phase 0 已用。 |
| 1 | `VIDEO` | Mac→Pad | 编码后视频（Annex-B NAL）。Phase 1。 |
| 2 | `INPUT` | Pad→Mac | 触控 / 笔 / 键盘事件。Phase 2。 |
| 3 | `AUDIO` | 预留 | Phase 5。 |
| 4 | `STATS` | 双向 | 预留：码率/时延遥测。 |

## 3. 标志位（flags）
| 位 | 含义 | 适用通道 |
|---|---|---|
| bit0 `0x01` | `KEYFRAME`：该视频帧含 IDR/关键帧 | VIDEO |
| bit1 `0x02` | `CODEC_CONFIG`：该帧含参数集（SPS/PPS/VPS） | VIDEO |
| 其它 | 预留，发送置 0，接收忽略 | — |

## 4. CONTROL 通道（Phase 0）
CONTROL 负载为 **UTF-8 编码的 JSON**，含 `type` 字段。Phase 0 必须实现下列消息。

### 4.1 握手
连接建立后，**客户端（Mac）先发** `hello`，**服务端（Pad）回** `hello_ack`。

```jsonc
// Mac → Pad
{ "type": "hello", "role": "mac", "protocolVersion": 1, "app": "superconnect",
  "caps": { "codecs": ["h264"], "maxWidth": 3840, "maxHeight": 2160, "hidpi": true } }

// Pad → Mac
{ "type": "hello_ack", "role": "pad", "protocolVersion": 1,
  "caps": { "codecs": ["h264", "hevc"], "screenWidth": 2560, "screenHeight": 1600,
            "scale": 2.0, "pen": true } }
```
- 若 `protocolVersion` 不一致：回 `{ "type":"error", "code":"version_mismatch", "message":"..." }` 后关闭。

### 4.2 心跳 / 往返时延（RTT）
```jsonc
{ "type": "ping", "seq": 1, "t0": 123456789 }   // 发起方单调时钟 ns
{ "type": "pong", "seq": 1, "t0": 123456789, "t1": 987654321 } // 回 t0 原值 + 自己的单调钟 t1
```
- 发起方收到 `pong` 后：`rtt = now() - t0`。

### 4.3 时钟同步（Phase 1+，Phase 0 仅占位）
NTP 式：`ping(t0)` → 对端记 `t1`(收到)、`t2`(回发) → `pong(t0,t1,t2)` → 发起方记 `t3`。
`offset ≈ ((t1 - t0) + (t2 - t3)) / 2`，`rtt ≈ (t3 - t0) - (t2 - t1)`。用于给视频帧/输入事件打统一时间戳。

### 4.4 关闭
```jsonc
{ "type": "bye" }
```

### 4.5 视频参数（Mac→Pad，Phase 1）
首帧编码后，Mac 告知平板实际编码分辨率（来自真实采集帧尺寸），平板据此 `setVideoSize` 并启动解码：
```jsonc
{ "type": "video_config", "codec": "h264", "width": 2560, "height": 1600 }
```

## 5. INPUT 通道（Phase 2/3，已实现）
固定 **44 字节**小端记录（便于 Swift/ArkTS/C++ 完全一致；黄金向量见 `vectors.json` `inputVectors`）：

```
type:u8 | tool:u8 | buttons:u8 | flags:u8
timestampMs:u64
x:f32 | y:f32            // 归一化 [0,1]，相对虚拟屏
pressure:f32            // [0,1]（设备原始值可能更大，注入端归一化）
tiltX:f32 | tiltY:f32   // 手写笔倾角，度 [-90,90]
scrollX:f32 | scrollY:f32
keyCode:u16 | reserved:u16
```
- `type`: 0=touchDown 1=touchMove 2=touchUp 3=hover 4=keyDown 5=keyUp 6=scroll
- `tool`: 0=finger 1=pen 2=eraser 3=mouse
- `buttons`: 位掩码（bit0=主键/左键，bit1=次键）
- 坐标归一化；Mac 侧映射到虚拟屏全局像素坐标后注入。**笔(tool=pen)** 携带 `pressure`/`tiltX`/`tiltY`，Mac 用 `CGEvent` 的 tablet 子类型注入压感（专业 app 后续走 DriverKit 虚拟数字化板）。
- Phase 3 后续可在 `flags` 标记"含历史采样点"，记录后追加高频采样数组（`GetHistory*`）。

## 6. VIDEO 通道（Phase 1，已实现）
- 负载为 **Annex-B**（`00 00 00 01` 起始码）NAL，**一帧一个访问单元**。
- 关键帧置 `KEYFRAME`(bit0)。**参数集（H.264 SPS/PPS）内联在关键帧的 Annex-B 负载最前面**（编码器实现），接收端整段喂解码器即可。
- `CODEC_CONFIG`(bit1) 与"负载前置 `ptsMonotonic:u64`"为**预留**，Phase 1 暂未启用（两端一致：均不发送/不解析）。后续若需独立参数集帧或显式 PTS，再同步两端与本文件。

## 7. 背压与丢弃
- VIDEO：发送侧"最新帧邮箱"（容量 1），新帧覆盖未发出的旧帧；编码器据覆盖频率自适应降码率。
- INPUT：有界 FIFO，**绝不丢点击/按键**；鼠标移动可合并。
- 写操作在独立线程/队列，socket 写满**不得阻塞**采集或输入采集线程。

## 8. 一致性测试
`proto/vectors.json` 给出确定性"黄金帧"。任一实现的 `encode(channel,flags,payload)` 必须**逐字节**等于 `frameHex`，`decode(frameHex)` 必须还原出相同三元组。Swift 测试与 C++ 主机测试都对其断言（见各自 README）。
