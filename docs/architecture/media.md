# 媒体与显示管线

状态：代码派生基线。

## 目的与边界

`Sources/Video.swift` 实现主机采集与编码、显示器解码与呈现、以及独立的 PCM 音频渲染。`Sources/VirtualDisplay.h` 提供创建虚拟显示器所需的 Objective-C 接口。媒体模块不拥有 TCP、配对或设备列表。

## 主机管线

```text
extension mode: virtual display ─┐
                                ├─> ScreenCaptureKit stream
mirror mode: primary display ────┘          │
                                           v
                                VideoToolbox compression session
                                           │
                          `configuration` once + `video` frames
                                           │
                                    CablePeer / Wire v2
```

`ScreenSender.start(profile:mirror:audio:)` 使用接收端 `DisplayProfile` 建立采集路径。扩展模式创建虚拟显示器；镜像模式选择主屏幕。它持有压缩会话、采集 stream、帧预算和可选音频输出，`stop()` 必须释放这些资源。

## 显示器管线

```text
CablePeer
  -> ReceiveSession validates `configuration`
  -> HardwareDecoder creates VTDecompressionSession
  -> decoded frame
  -> VideoSurface keeps and presents latest frame

audioConfiguration + audio
  -> AudioRenderer bounded playback queue
```

`ReceiveSession` 在 `App.swift` 中定义。它只接受已认证 peer 的包，记录视频序号、配置状态和最后活动时间。`HardwareDecoder` 负责 VideoToolbox 解码会话的建立、等待异步帧和释放；`VideoSurface` 只呈现最新帧，避免慢渲染堆积。

## 编码与延迟策略

| 策略 | 实现意图 | 不可夸大的结论 |
| --- | --- | --- |
| HEVC/H.264 硬件编解码 | 降低 CPU 占用和编码时间 | 不保证全部机型均使用相同硬件路径。 |
| `TCP_NODELAY` | 减少小控制包等待 | 不消除 TCP 拥塞或编码延迟。 |
| 有界帧预算 | 最多保留三个未确认帧；满额时跳过新采集帧，确认后释放不晚于该序号的预算 | 不保证无丢帧，也不为缓解网络压力丢弃已编码参考帧。 |
| 最新帧呈现 | 渲染落后时跳过旧图 | 不保证屏幕到屏幕固定毫秒数。 |
| 有界音频播放队列 | 网络短暂阻塞时防止音频无限落后 | 不等同于完整系统音频路由支持。 |

## 尺寸与光标坐标

`DisplayProfile` 传递像素尺寸与 `hiDPI` 标志；逻辑尺寸由 `hiDPI` 推导。主机的虚拟显示器、ScreenCaptureKit 输出尺寸、`VideoConfiguration` 与接收端 surface 必须遵循同一个 profile。M1 24 英寸 iMac 的推荐逻辑桌面为 `2240 x 1260`，实际编码目标可为 `4480 x 2520`；2017 2.5K iMac 推荐 `2560 x 1440`。

当前光标仅从主机向显示器同步位置与可选图像，不提供接收端向主机的鼠标、键盘或点击回传。渲染时不得按窗口像素比例拉伸光标；比例不一致时保持光标资源原始宽高比。

## 错误与清理

| 条件 | 处理责任 |
| --- | --- |
| 无屏幕录制权限 | `ScreenSender.start` 失败，`AppDelegate` 回到可恢复 UI。 |
| 虚拟显示器创建失败 | 不启动采集或媒体发送。 |
| 编码器/解码器配置失败 | 结束本次 peer，会话资源释放。 |
| 视频窗口关闭 | 接收端表示停止显示，必须恢复鼠标、渲染和息屏状态。 |
| socket 关闭 | 接收端停止 decoder/audio/surface，但 listener 保持运行。 |
| 系统睡眠 | 使当前发送/接收会话失效；唤醒按应用生命周期规则恢复。 |

## 验证

媒体修改的最低验证包括：扩展与镜像各一次、两种目标 iMac 分辨率、首帧与重连、音频开关、鼠标跨屏、窗口关闭、断线、睡眠唤醒。Intel 真机、音频质量和端到端延迟必须记录为真实测量结果，不能从代码结构推导。
