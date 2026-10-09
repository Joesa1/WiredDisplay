# Duet 模式落地分析

状态：ready。日期：2026-10-09。

## 结论

新增一个名为“Duet 模式”的**色彩优先、低延迟硬件视频模式**。名称只表示借鉴已验证的产品架构原则；不复制 Duet 的代码、私有协议、传输格式或资源。

它不是现有“无损 RGB”的轻量化改名：无损 RGB 保留 BGRA8 原始字节，满屏运动时 4K60 的净载荷约为 15.93 Gbit/s、5K60 约为 28.31 Gbit/s，复制、压缩、TCP、显示和控制流量都尚未计入。Duet 模式改为硬件 HEVC Main10，以明确色彩元数据和高码率换取肉眼色彩稳定性，以受限的采集、编码、传输与呈现队列换取新鲜度。

## 已确认依据

本仓库的只读本地应用调研在 [Duet Local Transport Analysis](../../research/duet-local-transport-analysis.md) 保存。可确认的观察包括：VideoToolbox H.264/H.265、实时编码开关、关闭帧重排、码率/关键帧/色彩元数据属性、ScreenCaptureKit/IOSurface/Metal、帧队列和丢帧统计。不能确认其私有包格式、每次会话使用的色度抽样/位深、带宽自适应公式或是否对雷雳链路使用 UDP。

## 产品合同

| 项目 | Duet 模式 | 不做的事 |
| --- | --- | --- |
| 编码 | 仅硬件 HEVC Main10；不支持时明确失败 | 不静默降级到 8-bit 或 raw RGB。 |
| 色彩 | 10-bit x420，sRGB/Display P3 原色、传递函数和 BT.709 矩阵显式贯通 | 不宣称 4:4:4、HDR、ICC 一致或字节级 RGB 无损。 |
| 新鲜度 | 两帧有界在途、一个捕获 surface；接收端从已解码帧中呈现最新可显示帧，预算满时跳过新采集样本 | 不承诺固定 60 fps 或固定毫秒延迟，也不声称网络中永远只保留最新帧。 |
| 码率 | 与色彩保真分开配置，采用较高但有上限的 HEVC 目标码率 | 不以名义雷雳带宽作为可达帧率承诺。 |
| 光标 | 保留 `ScreenCaptureKit.showsCursor`，光标随画面采集 | 不新增独立鼠标传输或接收端向主机注入事件。 |
| 传输 | 复用已验证的 Thunderbolt Bridge TCP 会话 | 不在本任务更换为 UDP、mTLS 或私有协议。 |

```text
virtual display / mirror
          |
          v
ScreenCaptureKit (queueDepth = 1, cursor included)
          |
          v
HEVC Main10 hardware encoder
  realtime / no frame reorder / bounded rate
          |
          v
2 bounded in-flight frames -> existing TCP -> hardware decoder -> newest decoded frame present
```

两帧而不是一帧是刻意选择：一帧会把可达帧率直接限制在一次显示确认往返之下；两帧仍有严格上限，又能避免常见的 16–33 ms 确认时间把流量压成低帧率。满额时丢弃新采集样本而不堆积旧画面。

## 变更边界

```text
Host controls
  Transmission mode [Low latency / Fidelity / Lossless RGB / Demo 1 / Demo 2 /
                     Demo 3 / Duet mode]
  Resolution        [Native panel / 4K compatible]

Active Duet mode
  HEVC Main10 · sRGB or Display P3 · high bitrate · bounded freshness
```

- 在 `TransmissionMode` 增加 `duet`，每台设备继续保存选择。
- `VideoConfiguration` 和协议文档把它定义为 HEVC Main10；协议升到 6，旧版本明确拒绝而非猜测互通。
- `ScreenSender` 对该模式使用 10-bit 采集、硬件 Main10、实时、无帧重排、一秒关键帧、两帧预算和 `queueDepth = 1`。
- `HardwareDecoder` 输出 10-bit x420 并重新附加传输色彩元数据。
- 统计编码显示为 `HEVC 10-bit · <color space> · Duet mode`。
- 在实际承载该策略的 Swift 源文件放置英文 docstring，包含调研证据、结论、边界和研究文档路径，防止后续重复进行无依据的逆向推断。

## 验收

自动化：协议/配置合法性、`TransmissionMode` 预算、HEVC Main10 硬件编码解码、色彩附件、HTML 持久化选择、所有既有 transport/video/demo 检查、arm64/x86_64 构建和包内版本核对。

真实双机：两台均升级至协议 6 后，分别测试静态桌面、文字滚动、4K 全屏视频、光标跨屏、扩展/镜像、断开重连。记录编码、实际确认帧率、往返确认时间、色彩测试图和主观鼠标跟手；不能从本地构建推导这些结论。
