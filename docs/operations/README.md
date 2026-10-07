# 构建与验证

状态：代码派生基线。

本范围负责可复现构建、版本一致性、安装包内容和验证口径；它不定义 Wire 消息或页面交互。协议改动参见 [../architecture/protocol.md](../architecture/protocol.md)，会话和媒体改动参见 [../architecture/README.md](../architecture/README.md)。

| 主题 | 单一事实来源 |
| --- | --- |
| 版本、最低系统、权限声明 | `Info.plist` |
| 编译、打包、ad-hoc 签名 | `build.sh` |
| 当前协议与端口 | `Sources/Wire.swift`、[protocol](../architecture/protocol.md) |
| 自动化测试边界 | `Tests/TransportCheck.swift` 与 [validation.md](validation.md) |
| 真实设备结论 | [validation.md](validation.md) 的验收记录 |

## 发布门槛

```text
source + docs change
  -> version consistency check
  -> arm64 build + x86_64 build
  -> transport checks
  -> package/signature/hash check
  -> two-Mac acceptance on the claimed feature set
  -> Git tag + GitHub release assets
```

任一双机功能未验证时，发布说明必须写“待真实设备验证”，不能标注为已支持。GitHub tag 本身不等于 GitHub Release；发布页必须含两种架构的 ZIP 与 `SHA256SUMS.txt`。

详见 [build-release.md](build-release.md) 和 [validation.md](validation.md)。
