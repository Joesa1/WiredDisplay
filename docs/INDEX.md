# Thunder Display 文档索引

状态：开发基线 `0.7.6`（`CFBundleVersion 25`，未发布）；下载指引保留公开版 `0.6.5`，整理于 2026-10-09。

本目录是 Thunder Display 的技术与交付文档入口。`README.md` 面向安装和使用；这里定义当前实现的模块边界、协议约束、界面行为、构建和验证规则。代码或产品行为变更时，必须在同一提交更新对应文档。

| 区域 | 说明 | 入口 |
| --- | --- | --- |
| 架构 | 应用、传输、协议和媒体管线 | [architecture](architecture/README.md) |
| 界面 | 原生窗口与 HTML 工作台的布局和交互约定 | [ui](ui/README.md) |
| 运维 | 构建、打包、版本和验证口径 | [operations](operations/README.md) |
| 交付计划 | 现状分析、任务和待办 | [plan](plan/README.md) |
| 调研 | 尚未进入运行时的硬件目录与产品素材 | [research](research/README.md) |
| 历史验证 | 不再作为当前版本结论，只保留当时证据 | [0.2.0 记录](validation-0.2.0.md)、[睡眠与菜单栏记录](sleep-menubar-validation.md) |

## 文档边界

- 本目录只描述 `WiredDisplay/` 的可执行实现。
- 当前工作区可能另有跨项目会话资料，但它不属于本仓库，不能作为本项目文档的链接依赖。发布或独立 clone 中以本目录为准。
- `Resources/mvp-ui-prototype.html` 是运行时加载的界面资源。原型的展示文案不构成实现事实；本目录的界面和协议文档才是维护依据。

## 当前版本事实

- 同一个 `.app` 同时承载主机与显示器角色。
- 雷雳网桥上的 TCP 是视频、音频、鼠标和统计数据的唯一传输路径；Bonjour 只用于发现。
- 当前通信协议为 `Wire.protocolVersion == 5`，协议 1/2/3/4 不能互连；保留三档并新增 LZ4 整帧/区域无损实验模式。
- 本地构建可生成 arm64 与 x86_64 两个安装包；真实双机雷雳 E2E 验证仍是发布门槛，不能由本地编译替代。

## 维护规则

1. 修改 `Sources/Wire.swift`，先更新 [protocol](architecture/protocol.md)。
2. 修改 `Sources/Cable.swift`、`Sources/App.swift` 的建连/恢复逻辑，更新 [transport](architecture/transport.md) 和 [architecture](architecture/README.md)。
3. 修改 `Sources/Video.swift` 或 `VirtualDisplay.h`，更新 [media](architecture/media.md)。
4. 修改 HTML、`WKWebView` bridge 或页面状态，更新 [ui](ui/README.md)。
5. 修改构建、签名、版本或发布包，更新 [build and release](operations/build-release.md)。
6. 新的真实设备结论写入 [validation](operations/validation.md)，并标明设备、版本、线材、步骤和结果。

## Touch Bar 开发功能

新增 [手机 Touch Bar](architecture/touch-bar.md)：通过独立局域网 HTTP 服务访问控制面板，入口位于工具区。雷雳仍是视频／音频传输路径；手机控制服务不承担屏幕视频传输。此功能在 PR 分支中开发，不代表当前公开安装包已经包含。
