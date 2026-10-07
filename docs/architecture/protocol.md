# Wire 协议

状态：代码派生基线。权威源码为 `Sources/Wire.swift`。

## 目的与版本

`Wire` 是 Thunder Display 的应用层帧协议。当前开发版 `protocolVersion` 为 `3`，默认 TCP 端口为 `54321`。不同协议版本必须在 `hello` 阶段拒绝。0.7.0 两端都必须升级，不能连接协议 2 的 0.6.5。

协议 3 为 `DisplayProfile` 增加 `wideGamut`，为 `VideoConfiguration` 增加必需的 `mode`、`colorSpace`。`lowLatency` 使用 sRGB / 8-bit，`fidelity` 使用 HEVC Main10 / 10-bit，`lossless` 使用无视频编码的 BGRA8，后两档按接收屏幕色域选 sRGB 或 Display P3。三档均为 SDR、sRGB 传递函数；YUV 档明确使用 BT.709 矩阵。Display P3 原色与 BT.709 矩阵是不同字段。

`video` 在压缩档仍为 BE64 序号加编码数据；在无损档为 BE64 序号加逐行紧密排列的 BGRA8（不含行 padding），长度必须严格等于 `8 + width * height * 4`。无损配置不带 parameter sets，也不创建视频解码器。最大包长为 64 MiB，覆盖最大支持的 5120×2880 BGRA8；JSON 仍限制 256 KiB。无损帧预算为一帧，其他档位为三帧，ACK 仍表示接收端提交显示。

## 帧格式

```text
0                   3 4                 4 + N
+---------------------+------------------+--------------------+
| length = 1 + N (BE) | packet kind (u8) | payload bytes      |
+---------------------+------------------+--------------------+
        4 bytes              1 byte             N bytes
```

`length` 包含 `packet kind`。帧总长度必须在 `1...Wire.maximumPacket`；接收方必须在分配 payload 前检查上限。JSON 控制消息还受 `Wire.decode` 的 `256 KiB` 限制，媒体帧不走该 JSON 解码边界。

## 消息表

| `PacketKind` | 方向 | Payload | 合同 |
| --- | --- | --- | --- |
| `hello` | 主机 -> 显示器 | `Hello` | 第一条业务包。携带版本、`code`、可选身份、应用版本、地址、反向码、probe 与息屏请求。 |
| `profile` | 显示器 -> 主机 | `DisplayProfile` | 宣告可接受的像素尺寸、HiDPI、HEVC 和显示器身份。 |
| `configuration` | 主机 -> 显示器 | `VideoConfiguration` | 视频编解码、尺寸和参数；每个接收会话仅一次。 |
| `video` | 主机 -> 显示器 | 编码帧 | 只有完成视频配置后可接收，序号严格递增。 |
| `acknowledgment` | 显示器 -> 主机 | 帧确认 | 用于发送端统计确认帧率和往返画面时间。 |
| `cursor` | 主机 -> 显示器 | `PointerUpdate` | 仅发送主机光标的展示状态；非法消息不终止视频。 |
| `heartbeat` | 主机 -> 显示器 -> 主机 | 空 payload | 主机发起，显示器回送，用于会话存活。 |
| `end` | 双向 | 可选原因 | 结束当前会话并触发标准释放。 |
| `statistics` | 主机 -> 显示器 | `StreamStatistics` | 主机计算并把当前会话指标交给显示器工作台展示。 |
| `audioConfiguration` | 主机 -> 显示器 | `AudioConfiguration` | 独立于视频的 PCM 音频格式。 |
| `audio` | 主机 -> 显示器 | PCM 数据 | 只有音频已配置时可入队。 |

## 数据模型与不变量

| 类型 | 关键字段 | 不变量 |
| --- | --- | --- |
| `PeerIdentity` | `id`、`name`、`model`、`systemVersion` | 连接成功后设备名称和能力由对端回读，不以首次输入名称为准。 |
| `Hello` | `version`、`code`、`appVersion`、`identity`、`address`、`receiverCode`、`probe`、`preventDisplaySleep` | `probe == true` 只获得 profile，不占用活动流会话。 |
| `DisplayProfile` | `width`、`height`、`hiDPI`、`hevc`、`appVersion`、`identity`、`receiverCode` | 逻辑尺寸由 `hiDPI` 推导；主机配置不得超过接收端承诺。 |
| `VideoConfiguration` | `width`、`height`、`hevc`、`parameterSets` | 配置一次；视频必须匹配已接受的配置。 |
| `AudioConfiguration` | sample rate、channels、格式 | 发送音频前必须先配置。 |
| `PointerUpdate` | `x`、`y`、`visible`、热点、尺寸与可选 PNG | 仅表达光标位置和图像，不表达点击、键盘或滚动。 |
| `FrameBudget` | 未确认帧与序号 | 最多保留三个未确认帧；满额时跳过新采集帧，不丢弃已编码参考帧。 |

## 认证与会话流

```text
1. receiver listens and has a stable local pairing credential
2. sender sends `hello`
3. receiver checks protocol and pairing credential
4. receiver returns `profile`
5. sender creates capture / virtual display and sends `configuration`
6. media, cursor, heartbeat, acknowledgment and statistics flow
7. `end`, socket close or fatal validation failure tears down only this session
```

当前实现将设备页面记录保存在 WebView `localStorage`，并将本机配对码及按地址索引的凭据保存在 `UserDefaults`。断开、重新监听或刷新页面不应重新生成本机配对码。删除页面设备尚未同步清理原生凭据，此差距见 `device-state-001`。

## 错误与兼容性

| 条件 | 必须行为 |
| --- | --- |
| 首包不是 `hello` | 拒绝候选连接。 |
| 协议版本不匹配 | 以明确错误结束，不尝试部分兼容。 |
| 配对码错误 | 拒绝且不提升为活动 peer。 |
| 重复/未配置/超 profile 视频 | 结束当前会话，不影响监听器。 |
| 无效 `cursor` | 忽略该消息，保持视频会话。 |
| 旧会话迟到回调 | 通过会话代际令牌丢弃，不得覆盖当前设备状态。 |

## 修改协议的门槛

协议字段、枚举数值、端口、编码语义或配对持久化任一改变时，必须：

1. 先更新本文件和 `Wire.protocolVersion` 的兼容策略；
2. 增加 `TransportCheck` 的编解码和错误边界用例；
3. 构建 arm64/x86_64；
4. 在两台同版本 Mac 上做第一次配对、已配对重连、断开、睡眠恢复和互换角色验证；
5. 更新发布说明中的最低兼容版本。
