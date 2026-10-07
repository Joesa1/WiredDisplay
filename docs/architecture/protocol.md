# Wire 协议

状态：代码派生基线。权威源码为 `Sources/Wire.swift`。

## 目的与版本

`Wire` 是 Thunder Display 的应用层帧协议。当前 `protocolVersion` 为 `2`，默认 TCP 端口为 `54321`。不同协议版本必须在 `hello` 阶段拒绝，不能把版本号仅当作界面提示。

## 帧格式

```text
0                   3 4                 4 + payloadLength
+---------------------+------------------+--------------------+
| payload length (BE) | packet kind (u8) | payload bytes      |
+---------------------+------------------+--------------------+
        4 bytes              1 byte             N bytes
```

`payload length` 不包含 `packet kind`。最大 payload 由 `Wire.maxPayload` 限制；接收方必须在分配 payload 前检查上限。

## 消息表

| `PacketKind` | 方向 | Payload | 合同 |
| --- | --- | --- | --- |
| `hello` | 双向 | `Hello` | 第一条业务包。携带协议、身份、配对码和 probe 标记。 |
| `profile` | 显示器 -> 主机 | `DisplayProfile` | 宣告显示器可接受的尺寸、缩放和能力。 |
| `configuration` | 主机 -> 显示器 | `VideoConfiguration` | 视频编解码、尺寸和参数；每个接收会话仅一次。 |
| `video` | 主机 -> 显示器 | 编码帧 | 只有完成视频配置后可接收，序号严格递增。 |
| `acknowledgment` | 显示器 -> 主机 | 帧确认 | 用于发送端统计确认帧率和往返画面时间。 |
| `cursor` | 双向 | `PointerUpdate` | 最佳努力；非法鼠标消息不应终止视频。 |
| `heartbeat` | 双向 | 时间/活动信息 | 对端回送，用于存活和 RTT 统计。 |
| `end` | 双向 | 可选原因 | 结束当前会话并触发标准释放。 |
| `statistics` | 显示器 -> 主机 | `StreamStatistics` | 传递当前会话指标。 |
| `audioConfiguration` | 主机 -> 显示器 | `AudioConfiguration` | 独立于视频的 PCM 音频格式。 |
| `audio` | 主机 -> 显示器 | PCM 数据 | 只有音频已配置时可入队。 |

## 数据模型与不变量

| 类型 | 关键字段 | 不变量 |
| --- | --- | --- |
| `PeerIdentity` | 设备 ID、名称、机型、系统版本、应用版本 | 连接成功后设备名称和能力由对端回读，不以首次输入名称为准。 |
| `Hello` | protocol、identity、pairingCode、probe | `probe == true` 只获得 profile，不占用活动流会话。 |
| `DisplayProfile` | 逻辑尺寸、像素尺寸、scale、可用模式 | 主机的配置不得超过接收端承诺。 |
| `VideoConfiguration` | codec、宽高、参数 | 配置一次；视频必须匹配已接受的配置。 |
| `AudioConfiguration` | sample rate、channels、格式 | 发送音频前必须先配置。 |
| `PointerUpdate` | 坐标、按钮、滚动 | 坐标按显示器 profile 映射，避免宽高比例不同导致光标变形。 |
| `FrameBudget` | 未确认帧和队列界限 | 队列到上限时优先丢弃旧帧，避免延迟线性积累。 |

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

已成功配对的设备记录保存稳定身份、可用地址和凭据；断开、重新监听或刷新页面不应重新生成本机配对码。只有“忘记设备”才删除双方后续直连所需的本地记录。

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
