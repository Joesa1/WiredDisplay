# 雷雳 Mac 内建显示器目录

状态：调研结论，未进入应用运行时。资料截至 2026-10-07。

## 先纠正范围

“2017 iMac 2.5K”不能作为适配键。Apple 将同一年、不同尺寸的机器分为不同硬件型号：

| `hw.model` | Apple 型号 | 面板物理像素 | 2x 基线逻辑像素 |
| --- | --- | --- | --- |
| `iMac18,1` | 2017 21.5 英寸非 Retina | 1920 x 1080 | 1920 x 1080 |
| `iMac18,2` | 2017 21.5 英寸 Retina 4K | 4096 x 2304 | 2048 x 1152 |
| `iMac18,3` | 2017 27 英寸 Retina 5K | 5120 x 2880 | 2560 x 1440 |

因此 `2560 x 1440` 是 5K iMac 的常见 2x 逻辑桌面，不是它的面板物理分辨率。面板发送尺寸、虚拟桌面的逻辑坐标和用户在“显示器设置”中选定的缩放模式是三项不同的值。

## 数据来源与边界

- Apple 的 [识别 iMac](https://support.apple.com/en-us/108054)、[识别 MacBook Pro](https://support.apple.com/en-us/108052) 和 [识别 MacBook Air](https://support.apple.com/en-mide/102869) 页面提供机型、`Model Identifier` 与每代技术规格入口。
- 目录只包含从 2011 年起配备 Thunderbolt 的 iMac、MacBook Air 和 MacBook Pro。较早的 Mini DisplayPort 机型不在范围内。
- 表中的“物理像素”来自 Apple 技术规格，例如 [2017 21.5 英寸 4K iMac](https://support.apple.com/en-us/112026)、[2017 27 英寸 5K iMac](https://support.apple.com/en-us/111969)、[M1 iMac](https://support.apple.com/en-us/111895)、[M5 14 英寸 MacBook Pro](https://support.apple.com/en-us/126318) 和 [M5 13 英寸 MacBook Air](https://support.apple.com/en-us/126320)。
- `baselineLogicalPixels` 是按 `nativePixels / backingScale` 推导的基线值，不是 Apple 承诺的强制模式。运行时必须读取实际 `NSScreen.frame`、`backingScaleFactor` 和 `CGDisplayPixelsWide/High`。

## 可查询目录

机器可读版本：[apple-thunderbolt-display-catalog.json](../../Resources/DeviceProfiles/apple-thunderbolt-display-catalog.json)。每行的 `models` 都是可以由本应用现有握手字段读取到的 `hw.model` 值。

### iMac

| 面板族 | `hw.model` | 物理像素 | 基线逻辑像素 |
| --- | --- | ---: | ---: |
| 21.5 英寸 FHD | `iMac12,1`, `iMac13,1`, `iMac14,1`, `iMac14,4`, `iMac16,1`, `iMac18,1` | 1920 x 1080 | 1920 x 1080 |
| 27 英寸 QHD | `iMac12,2`, `iMac13,2`, `iMac14,2` | 2560 x 1440 | 2560 x 1440 |
| 21.5 英寸 4K | `iMac16,2`, `iMac18,2`, `iMac19,2` | 4096 x 2304 | 2048 x 1152 |
| 27 英寸 5K | `iMac15,1`, `iMac17,1`, `iMac18,3`, `iMac19,1`, `iMac20,1`, `iMac20,2` | 5120 x 2880 | 2560 x 1440 |
| iMac Pro | `iMacPro1,1` | 5120 x 2880 | 2560 x 1440 |
| 24 英寸 4.5K | `iMac21,1`, `iMac21,2`, `Mac15,4`, `Mac15,5`, `Mac16,2`, `Mac16,3` | 4480 x 2520 | 2240 x 1260 |

### iMac 型号代码对照

设备列表应显示以下简要名称，而非只显示 `hw.model`。实际 UI 使用机器可读目录中的 `modelNames` 字段。

| `hw.model` | 显示名称 |
| --- | --- |
| `iMac12,1` | iMac 21.5 英寸，2011 年中 |
| `iMac12,2` | iMac 27 英寸，2011 年中 |
| `iMac13,1` | iMac 21.5 英寸，2012 年末 |
| `iMac13,2` | iMac 27 英寸，2012 年末 |
| `iMac14,1` | iMac 21.5 英寸，2013 年末 |
| `iMac14,2` | iMac 27 英寸，2013 年末 |
| `iMac14,4` | iMac 21.5 英寸，2014 年中 |
| `iMac15,1` | iMac 27 英寸 Retina 5K，2014 年末或 2015 年中 |
| `iMac16,1` | iMac 21.5 英寸，2015 年末 |
| `iMac16,2` | iMac 21.5 英寸 Retina 4K，2015 年末 |
| `iMac17,1` | iMac 27 英寸 Retina 5K，2015 年末 |
| `iMac18,1` | iMac 21.5 英寸，2017 年 |
| `iMac18,2` | iMac 21.5 英寸 Retina 4K，2017 年 |
| `iMac18,3` | iMac 27 英寸 Retina 5K，2017 年 |
| `iMac19,1` | iMac 27 英寸 Retina 5K，2019 年 |
| `iMac19,2` | iMac 21.5 英寸 Retina 4K，2019 年 |
| `iMac20,1`、`iMac20,2` | iMac 27 英寸 Retina 5K，2020 年 |
| `iMacPro1,1` | iMac Pro，2017 年 |
| `iMac21,1` | iMac 24 英寸 M1，2021 年，四接口 |
| `iMac21,2` | iMac 24 英寸 M1，2021 年，双接口 |
| `Mac15,4` | iMac 24 英寸 M3，2023 年，双雷雳端口 |
| `Mac15,5` | iMac 24 英寸 M3，2023 年，四雷雳端口 |
| `Mac16,2` | iMac 24 英寸 M4，2024 年，双雷雳端口 |
| `Mac16,3` | iMac 24 英寸 M4，2024 年，四雷雳端口 |

### MacBook Pro

| 面板族 | `hw.model` | 物理像素 | 基线逻辑像素 |
| --- | --- | ---: | ---: |
| 13 英寸非 Retina | `MacBookPro8,1`, `MacBookPro9,2` | 1280 x 800 | 1280 x 800 |
| 15 英寸非 Retina | `MacBookPro8,2`, `MacBookPro9,1` | 1440 x 900 | 1440 x 900 |
| 17 英寸非 Retina | `MacBookPro8,3` | 1920 x 1200 | 1920 x 1200 |
| 13 英寸 Retina / Touch Bar / M1 / M2 | `MacBookPro10,2`, `MacBookPro11,1`, `MacBookPro12,1`, `MacBookPro13,1`, `MacBookPro13,2`, `MacBookPro14,1`, `MacBookPro14,2`, `MacBookPro15,2`, `MacBookPro15,4`, `MacBookPro16,2`, `MacBookPro16,3`, `MacBookPro17,1`, `Mac14,7` | 2560 x 1600 | 1280 x 800 |
| 15 英寸 Retina / Touch Bar | `MacBookPro10,1`, `MacBookPro11,2`, `MacBookPro11,3`, `MacBookPro11,4`, `MacBookPro11,5`, `MacBookPro13,3`, `MacBookPro14,3`, `MacBookPro15,1`, `MacBookPro15,3` | 2880 x 1800 | 1440 x 900 |
| 16 英寸 Intel | `MacBookPro16,1`, `MacBookPro16,4` | 3072 x 1920 | 1536 x 960 |
| 14 英寸 Liquid Retina XDR | `MacBookPro18,3`, `MacBookPro18,4`, `Mac14,5`, `Mac14,9`, `Mac15,3`, `Mac15,6`, `Mac15,8`, `Mac15,10`, `Mac16,1`, `Mac16,6`, `Mac16,8`, `Mac17,2`, `Mac17,7`, `Mac17,9` | 3024 x 1964 | 1512 x 982 |
| 16 英寸 Liquid Retina XDR | `MacBookPro18,1`, `MacBookPro18,2`, `Mac14,6`, `Mac14,10`, `Mac15,7`, `Mac15,9`, `Mac15,11`, `Mac16,5`, `Mac16,7`, `Mac17,6`, `Mac17,8` | 3456 x 2234 | 1728 x 1117 |

### MacBook Air

| 面板族 | `hw.model` | 物理像素 | 基线逻辑像素 |
| --- | --- | ---: | ---: |
| 11 英寸 | `MacBookAir4,1`, `MacBookAir5,1`, `MacBookAir6,1`, `MacBookAir7,1` | 1366 x 768 | 1366 x 768 |
| 13 英寸非 Retina | `MacBookAir4,2`, `MacBookAir5,2`, `MacBookAir6,2`, `MacBookAir7,2` | 1440 x 900 | 1440 x 900 |
| 13 英寸 Retina | `MacBookAir8,1`, `MacBookAir8,2`, `MacBookAir9,1`, `MacBookAir10,1` | 2560 x 1600 | 1280 x 800 |
| 13 英寸 Liquid Retina | `Mac14,2`, `Mac15,12`, `Mac16,12`, `Mac17,3` | 2560 x 1664 | 1280 x 832 |
| 15 英寸 Liquid Retina | `Mac14,15`, `Mac15,13`, `Mac16,13`, `Mac17,4` | 2880 x 1864 | 1440 x 932 |

## 下一版适配方式

不能用“年份”或“屏幕尺寸”选择配置，也不能只以当前 iMac 24 英寸的 4480 x 2520 规则兜底。建议按以下顺序建立运行时档案：

```text
握手 PeerIdentity.model (hw.model)
            |
            v
静态目录命中 -> 面板上限、默认产品图、初始 1x/2x 建议
            |
            v
接收端运行时屏幕读数 -> 当前原生像素、point size、backing scale、用户缩放模式
            |
            v
协商传输档位 -> 编码宽高、虚拟显示逻辑坐标、鼠标坐标变换
```

具体规则：

1. `hw.model` 用于识别硬件面板上限、选择产品图和在未知运行时读数时给出安全兜底。
2. 接收端必须把实际 `CGDisplayPixelsWide/High` 与 `NSScreen.backingScaleFactor` 放进 `DisplayProfile`，覆盖静态的缩放推断。
3. 主机应以接收端报告的逻辑坐标变换鼠标，以接收端报告的编码尺寸设置视频帧；不能用固定 `4480 x 2520` 或固定 `2560 x 1440`。
4. 未命中型号时继续使用运行时读数；两者都缺失时拒绝“原生清晰”档位并提示降档，不猜测为 M1 iMac。

本次只建立目录和素材，不改 `panelProfile()`、协议或视频管线。
