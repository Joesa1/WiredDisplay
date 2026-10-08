# 媒体与显示管线

状态：代码派生基线。

## 0.7.0 传输模式

三档共用接收面板尺寸、HiDPI 和可选 4K 兼容缩放；分辨率和传输模式独立选择。WebView 按设备保存选择，原生连接时读取，连接/会话期间禁止改档，自动重连沿用当前会话选择。

| 模式 | 采集与传输 | 呈现与边界 |
| --- | --- | --- |
| 低延迟 SDR | 8-bit NV12，HEVC Main 或 H.264 High；速度优先，40–150 Mbit/s 目标码率按像素数计算 | sRGB，有损，60fps 上限 |
| 色彩保真 | 10-bit x420，硬件 HEVC Main10；40–300 Mbit/s 目标码率按像素数计算 | 保留 10-bit 解码输出，sRGB/Display P3 SDR；仍为有损 4:2:0，不支持时报错 |
| 无损 RGB | BGRA8 逐像素原样传输，不经视频编解码；一帧在途 | 原始采集像素到接收缓冲逐字节一致；8-bit 采集仍可能有色带，不是 HDR 或物理面板一致性承诺 |

接收侧沿用 AVSampleBufferDisplayLayer，通过明确的 CVPixelBuffer 色彩附件交给系统色彩管理，不另建 Metal 渲染器。协议中的色彩空间描述流内容，不替换物理显示器 ICC。链路繁忙时跳过新采集帧，界面报告实际确认帧率。

面板适配复用 `apple-thunderbolt-display-catalog.json`，只对内建屏按型号读取物理像素，避免系统超采样模式被误当物理面板；外接屏和未知型号沿用运行时几何。运行时 backingScaleFactor 决定 HiDPI。删除了将所有高分辨率 Retina 都改成 4480×2520，以及将部分笔记本面板改成 2560×1440 的硬编码。未知面板的运行时模式仍可能是缩放尺寸，不声称已识别物理原生像素。

BGRA8 在 4480×2520@60 的理论载荷约 21.68 Gb/s（5120×2880@60 为 28.31 Gb/s），尚未计 TCP 与复制成本；不承诺这些尺寸稳定 60fps。色块根因需用同一桌面、同一亮度下三档 A/B 实测区分，照片不能证明根因。

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
                                    CablePeer / Wire v4
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

`DisplayProfile` 传递像素尺寸与 `hiDPI` 标志；逻辑尺寸由 `hiDPI` 推导。虚拟显示器、采集输出、视频配置和接收 surface 必须遵循同一个 profile。M1 24 英寸 iMac 为 `4480 x 2520`；2017 27 英寸 5K iMac 为 `5120 x 2880`，其 `2560 x 1440` 是 2x 逻辑尺寸。

所有模式保持 ScreenCaptureKit showsCursor = true，系统光标随视频传输，不启用独立光标通道。

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

## 0.7.1 comparison demos

Demo 1 adds a changed bounding rectangle and native LZ4; Demo 2 adds only native LZ4. Both pipeline at most two frames, keeping the existing lossless mode at one frame as the baseline. Frame reservation precedes packing/compression; skipped captures do not change the region baseline. No resolution/color/bit-depth changes or lossy fallback. A full-screen bounding box sends a full frame; smaller rectangles are compressed without also compressing the full frame. This avoids duplicate compression cost but does not promise the smallest possible packet. Bounding-box comparison scans pixels and can save little for distant changes; tiled updates are deferred until measurements justify the complexity. CPU and memory costs may increase; two-Mac latency/FPS/bandwidth measurements are required.
