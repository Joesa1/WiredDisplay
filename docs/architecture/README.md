# 架构

状态：代码派生基线。

## 目的与边界

Thunder Display 将一台 Mac 的桌面画面经雷雳网桥传到另一台 Mac。这里描述应用内的运行时责任；不定义 macOS 本身如何枚举雷雳控制器，也不声称能识别线材代际、主动/被动属性。

```text
             Host Mac                                  Display Mac
┌────────────────────────────────────┐     TCP     ┌────────────────────────────────────┐
│ AppDelegate                         │────────────>│ AppDelegate                         │
│  ├─ ScreenSender                    │ Wire v2     │  ├─ ReceiveSession                  │
│  │   └─ ScreenCaptureKit            │             │  │   ├─ HardwareDecoder              │
│  │       + VideoToolbox encoder     │             │  │   └─ AudioRenderer                 │
│  └─ CablePeer                       │             │  ├─ CableListener                   │
└────────────────────────────────────┘             │  └─ VideoSurface                    │
                                                    └────────────────────────────────────┘

 Host -> Display: configuration, video, audio, cursor, statistics, heartbeat
 Display -> Host: profile, acknowledgment, heartbeat

            CableAddress / ThunderboltInspector select `bridgeN` on both sides
```

## 模块索引

| 模块 | 源码 | 所有者 | 文档 |
| --- | --- | --- | --- |
| 应用编排 | `Sources/App.swift` | `AppDelegate` | 本页 |
| 雷雳传输 | `Sources/Cable.swift` | `CablePeer`、`CableListener`、`CableDiscovery` | [transport.md](transport.md) |
| Wire 协议 | `Sources/Wire.swift` | `Wire` 与数据模型 | [protocol.md](protocol.md) |
| 媒体与显示 | `Sources/Video.swift`、`Sources/VirtualDisplay.h` | `ScreenSender`、解码器和渲染面 | [media.md](media.md) |
| 工作台界面 | `Resources/mvp-ui-prototype.html`、`App.swift` | Web 页面与 `WKWebView` bridge | [../ui/README.md](../ui/README.md) |

## 主要概念

| 术语 | 定义 |
| --- | --- |
| 主机 | 创建虚拟显示器或采集主屏幕，并发送媒体的 Mac。 |
| 显示器 | 监听 TCP、提供 `DisplayProfile`、解码并全屏呈现画面的 Mac。 |
| 候选连接 | 由监听器接受、但尚未完成 `hello` 身份验证的 `CablePeer`。 |
| 活动会话 | 已通过配对且已提升为当前 `peer` 的连接；同一接收端只允许一个。 |
| 代际令牌 | `AppDelegate` 为异步回调使用的会话身份，用来丢弃旧会话的迟到回调。 |

## 所有权与生命周期

`AppDelegate` 是应用级可变状态的唯一协调者：它创建主窗口、监听器、发现器、活动 peer、发送器、接收会话、菜单栏状态及睡眠恢复状态。`ReceiveSession` 只在接收端有效，并持有解码器与音频渲染器；`ScreenSender` 只在主机端有效。

```text
launch
  -> inspect Thunderbolt Bridge
  -> choose role/page

display role
  -> CableListener.start
  -> candidate `hello`
  -> validate protocol + pairing
  -> return `DisplayProfile`
  -> accept configuration
  -> receive media / cursor / heartbeat
  -> peer close or end
  -> release receiver resources; listener stays available

host role
  -> choose saved peer or first-time endpoint
  -> CablePeer.connect on selected bridge
  -> `hello` + profile exchange
  -> create virtual display or select mirror capture
  -> ScreenSender.start
  -> send configuration and media
  -> stop / error / sleep
  -> release capture, encoder and peer
```

主动断开必须取消自动恢复。睡眠使旧会话失效；唤醒后只有睡眠前存在监听、连接或连接请求时，才恢复相应角色。接收端关闭活动 peer 后继续监听，主机端则在偏好允许时有限期自动重连。

## 跨模块调用链

| 调用链 | 合同 |
| --- | --- |
| `AppDelegate -> ThunderboltInspector -> CableAddress` | 选择可用雷雳网桥地址；Wi-Fi 和蜂窝路径不是媒体回退。 |
| `AppDelegate -> CableListener/CablePeer` | 建立或接受 TCP，并把帧交给 Wire 层回调。 |
| `AppDelegate -> ScreenSender` | 在已获取显示器 profile 后开始扩展或镜像采集。 |
| `CablePeer -> ReceiveSession` | 仅已认证会话可交付协议包。 |
| `ReceiveSession -> HardwareDecoder/AudioRenderer/VideoSurface` | 视频必须先配置；音频有独立配置；渲染只呈现最新可用帧。 |
| `AppDelegate <-> WKWebView` | 页面动作传入原生层，原生状态以脚本快照返回页面。 |

## 跨模块约束

- `Wire.protocolVersion` 不匹配时不得尝试降级或部分连接。
- 只有 `hello` 验证成功的 peer 可以接收或发送流数据。
- 视频配置只接受一次；未经配置的视频、重复配置和超出 profile 的尺寸必须拒绝。
- 旧 peer 的关闭、失败或首帧回调不得改变新会话状态。
- UI 显示的活动设备、指标和连接状态必须来自当前 `sessionID`，不得复用已断开设备数据。
- 本地编译成功不是媒体、音频、睡眠恢复或 Intel 运行时成功的证据。

## 设计决定

| 决定 | 原因 | 影响 |
| --- | --- | --- |
| TCP 直接跑在雷雳网桥 | 简化端到端可靠性和配对流程 | 拥塞时必须限制队列，不能无限缓存。 |
| 固定 IPv4 是推荐设置，不是协议要求 | 稳定已保存设备的端点 | 自动分配地址仍可用，但地址变化需要重新发现或更新记录。 |
| 发现与建连分离 | Bonjour 不可靠时仍可直接按 IP 连接 | 手动首次配对必须保持可用。 |
| 单应用双角色 | 降低部署复杂度 | 角色切换必须明确释放当前会话。 |
| HTML 工作台嵌入原生应用 | 快速迭代复杂控制面 | bridge 的动作名与状态字段属于受控 API，不能随页面文案任意更名。 |

## 手机 Touch Bar 控制通道

[Touch Bar](touch-bar.md) 在应用内提供独立的局域网 HTTP 控制服务，由 `AppDelegate` 持有，默认关闭。它不复用 `Wire` 协议、不改变雷雳媒体路径，也不依赖显示器连接。手机通过配对码获取访问令牌，原生层执行白名单控制指令。功能配置、状态来源及权限限制见专门合同。
