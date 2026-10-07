# 当前状态分析

状态：代码派生基线，2026-10-07。

## 目标

把当前单体 Swift App、嵌入式工作台、Wire v2 和发布流程拆成可维护的文档边界，并指出未来交付必须穿透的真实集成路径。

## 模块分解

| 模块 | 输入 | 输出 | 依赖 | 当前风险 |
| --- | --- | --- | --- | --- |
| 应用编排 | UI action、系统睡眠、传输回调 | 会话、窗口、状态、恢复 | 所有运行时模块 | `AppDelegate` 责任集中，状态错误容易跨设备泄漏。 |
| 传输 | bridge 地址、TCP、Bonjour | 有边界的 Wire frame | Network.framework、SystemConfiguration | 系统报告依赖文本解析，部分本地化输出不能稳定识别。 |
| 协议 | JSON 控制 payload、编码媒体 | 认证、profile、配置、媒体消息 | TCP transport | 协议 2 与遗留脚本不一致。 |
| 媒体 | profile、屏幕/音频样本 | 编码帧、解码图像、播放音频 | ScreenCaptureKit、VideoToolbox、CoreGraphics | 真机机型、分辨率、睡眠与 Intel 仍需验收。 |
| 工作台 | 原生状态快照、用户点击 | bridge action、局部视图状态 | WebKit、`localStorage`、`UserDefaults` | 双存储和样例设备可造成展示状态与真实状态分离。 |
| 构建发布 | 源码、SDK、版本号 | 两种架构 ZIP、哈希 | Xcode CLI、codesign | 没有 CI、公证或资产发布自动化。 |

## 集成路径枚举

| 路径 | 真实连接 | 验证目标 |
| --- | --- | --- |
| UI -> Native -> host session | HTML `session` -> `AppDelegate.startConnection` -> `CablePeer` -> `ScreenSender` | 点击连接必须建立 TCP、配对、开始采集并回写首帧状态。 |
| UI -> Native -> display session | HTML `session(display)` -> `AppDelegate.receive` -> `CableListener` -> `ReceiveSession` | 显示器页面必须展示稳定 bridge/配对码并保持监听。 |
| Host -> Display handshake | `CablePeer` -> `hello` -> `ReceiveSession` -> `profile` | 错码、协议错、probe、已配对重连分别可解释。 |
| Host -> Display media | `ScreenSender` -> Wire configuration/video/audio -> decoder/surface/renderer | 扩展、镜像、音频、低延迟帧预算各自真实生效。 |
| Receiver -> Host feedback | `acknowledgment` 与 heartbeat echo -> `AppDelegate` | 确认帧释放预算并计算确认时间；旧会话不得污染当前状态。 |
| Host -> Display metrics | `ScreenSender` 的 `statistics` -> `ReceiveSession` -> WebView | 指标只归属当前活动设备，不跨设备串数据。 |
| System -> lifecycle | sleep/wake -> `AppDelegate` -> end/reconnect -> UI/menu | 旧回调不污染新会话，手动断开不自动复连。 |
| Source -> release | `Info.plist` + `build.sh` -> arch ZIP + GitHub release | tag、版本、架构资产和哈希一致。 |

## 已知差距

| 差距 | 影响 | 计划位置 |
| --- | --- | --- |
| `ReceiverCheck.py` 仍使用 protocol 1 | 现有黑盒接收测试不能验证当前版本 | `validation-001` 候选任务。 |
| `localStorage` 与 `UserDefaults` 分别保存设备相关状态 | 删除、换机或重新配对后可能出现 UI 与连接状态不同步 | `device-state-001` 候选任务。 |
| 部分偏好尚未进入原生会话路径 | 页面看似可配置，实际行为不完整 | `ui-bridge-001` 候选任务。 |
| 没有当前版本完整双机验收记录 | 无法证明发布包在不同芯片、两种 iMac 配置上可用 | `hardware-e2e-001` 候选任务。 |
| 系统报告解析受系统语言影响 | 线缆状态可能显示未知 | `transport-report-001` 候选任务。 |

## 结论

接下来的功能任务不得直接从页面视觉出发。它们必须先选择上述一条完整集成路径，并在任务中同时列出代码、设计文档和真实/自动化验证。这样才能避免“页面有按钮、但按钮没有进入实际显示会话”的回归。
