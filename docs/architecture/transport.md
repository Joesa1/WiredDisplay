# 雷雳传输

状态：代码派生基线。

## 目的

`Sources/Cable.swift` 负责在 macOS 雷雳网桥上选择路径、建立 TCP、收发有边界的数据包、监听入站连接，以及通过 Bonjour 发现兼容实例。它不负责配对语义、媒体编码或界面状态。

## 类型与入口

| 类型 | 输入 | 输出/责任 |
| --- | --- | --- |
| `CableAddress` | 接口名、IPv4、接口索引 | 对一个 `bridgeN` 路径的可连接描述。 |
| `ThunderboltInspector` | 系统网络与接口信息 | 返回雷雳网桥地址和系统报告。 |
| `CablePeer` | 对端 IP、`CableAddress` | 一个可停止的 `NWConnection`，带协议帧收发与状态回调。 |
| `CableListener` | 端口、`CableAddress` | 在 `Wire.port` 监听候选 peer，并发布 Bonjour 服务。 |
| `CableDiscovery` | Bonjour 查询 | 仅返回 `protocol` 字段与本地版本匹配的发现结果。 |

## 建连与监听

```text
Host                                       Display
────                                       ───────
ThunderboltInspector.select bridgeN        ThunderboltInspector.select bridgeN
CablePeer.connect(ip, bridgeN) ─────TCP──> CableListener.start(port, bridgeN)
NWConnection.ready                         accept candidate CablePeer
Wire frames                                validate first packet in AppDelegate
```

`CablePeer.connect` 将连接约束到已选择的 `CableAddress`。默认路径监听器未必能列出 `bridgeN`，因此不能用“默认路由未出现雷雳网桥”推断线缆不可用。媒体连接禁止 Wi-Fi 与蜂窝作为替代路径。

## 帧边界

Wire 头部定义在 `Wire.header`：4 字节大端 `length`，随后 1 字节 `PacketKind`，再跟 payload。`length` 包含 `PacketKind` 的 1 字节与 payload 的 N 字节，即 `1 + N`。`CablePeer` 负责把 TCP 任意分段重新组装为完整帧，也允许一次 receive 中含多个帧。

| 条件 | 行为 |
| --- | --- |
| 长度为 0 或超出 `Wire.maximumPacket` | 终止 peer，报告无效帧。 |
| 包类型字节无法映射到 `PacketKind` | 终止 peer，报告无效帧。 |
| TCP `.waiting`、`.failed`、`.cancelled` | 完成当前 peer；由 `AppDelegate` 决定是否恢复。 |
| `sendPointer` | 鼠标流量可合并/替换，以免其积压视频。 |
| `stop()` 多次调用 | 必须幂等，不可多次触发有效会话清理。 |

## 发现约定

监听端发布 `_wireddisplay._tcp`，TXT 至少包含：

| 字段 | 值 | 用途 |
| --- | --- | --- |
| `protocol` | `Wire.protocolVersion` | 过滤不兼容应用。 |
| `version` | 应用版本 | 供发现结果展示，不单独决定协议兼容性。 |
| `ip` | 当前雷雳网桥地址 | 供发现结果填充候选端点。 |
| `interface` | 当前 `bridgeN` 名称 | 诊断当前发现记录来自哪个网桥。 |

发现不替代首次配对：它可以填充候选设备，但连接仍要走 `hello`。固定 IP 用于让已保存记录在 Bonjour 暂时不可见时仍可直连。设备名称与稳定身份来自握手中的 `PeerIdentity`，不是 Bonjour TXT 的权威来源。

## 错误边界

传输层输出网络状态与帧错误，不自行修改 UI，也不判断配对码是否正确。错误展示、重试、设备置灰和保存状态属于 `AppDelegate` 与工作台的职责。

## 验证

`Tests/TransportCheck.swift` 覆盖分片/合帧、超大帧拒绝、断开重连和关闭幂等性。真实验证还必须覆盖：两台 Mac 的 bridge 地址、监听可达性、自动/固定 IP、线缆热插拔、睡眠恢复和 Bonjour 不可用时的直接 IP 连接。
