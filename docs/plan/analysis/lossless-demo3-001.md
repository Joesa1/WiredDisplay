# Demo 3 实时无损调研落地分析

状态：ready。

## 目标

新增一个与既有无损 RGB、Demo 1、Demo 2 并列的实验模式。它保留 BGRA8 的逐字节像素与 P3/sRGB 色彩空间标记，但不再由应用扫描整帧寻找变化范围。

## 已确认输入

`ScreenCaptureKit` 在每个屏幕样本的附件中提供 `SCStreamFrameInfoDirtyRects`。其值是系统汇总的重绘或移动矩形，坐标为像素。Demo 3 只在该附件存在且范围有效时使用其并集；附件缺失、为空或越界时退回完整帧。

## 模块与集成

| 模块 | 改动 | 集成点 |
| --- | --- | --- |
| `Wire` | 新增 `demo3` 枚举值与协议版本 5 | `VideoConfiguration` 在握手后的配置包中传递模式。 |
| `Video` | 读取 dirty rect，构造现有 LZ4 区域包；一帧在途、capture queue depth 为 1 | `ScreenCaptureKit -> ScreenSender -> CablePeer -> HardwareDecoder`。 |
| HTML | 展示并保存 Demo 3；解释它的真实边界 | WebView bridge 将模式交给 `AppDelegate`。 |
| 文档与测试 | 更新媒体/协议事实，验证像素、回退、预算和协议 | 不以本地测试替代双机验收。 |

## 约束

```text
SCStream dirty rects -> one union rect -> LZ4 exact RGB payload
          absent/invalid -> full RGB keyframe

in flight: 1
capture queue depth: 1
cursor: captured in video, no independent cursor path
color: existing P3/sRGB attachment path, no RGB<->YUV transform
```

- 这是减少应用 CPU 比较和捕获积压的实验，不承诺 60 fps 或更低端到端延迟。
- 变化矩形相距很远时，并集可能接近全屏；不在本任务引入分块协议。
- 新的 `mode` 值会被旧协议 4 接收端拒绝，因此协议升到 5，双方必须升级。
