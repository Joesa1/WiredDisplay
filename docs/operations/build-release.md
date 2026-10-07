# 构建与发布

状态：当前 `build.sh` 基线。

## 输入与产物

`./build.sh` 用当前 macOS SDK 分别编译 `arm64-apple-macos12.3` 和 `x86_64-apple-macos12.3`，并输出：

| 产物 | 用途 |
| --- | --- |
| `dist/ThunderDisplay-arm64.zip` | Apple 芯片 Mac 安装包。 |
| `dist/ThunderDisplay-x86_64.zip` | Intel Mac 安装包。 |
| `dist/SHA256SUMS.txt` | 两个 ZIP 的 SHA-256 清单。 |
| `dist/Thunder Display.app` | 仅本地检查副本；脚本最后循环写入 x86_64，不能当作“通用 app”发布。 |

每个 app 包含可执行文件、`Info.plist`、`mvp-ui-prototype.html`、两套 PNG 图标、`AppIcon.icns` 与 `LICENSE-TargetBridge.txt`。

## 签名边界

构建默认使用 ad-hoc 签名。设置 `WIRED_SIGN_IDENTITY` 可替换为本机可用的 Apple 签名身份。脚本会运行 `codesign --verify --deep --strict`，但当前没有 notarization、stapling、CI 或自动 GitHub Release 流程。

因此，任何“可在另一台未开发 Mac 直接安装”的发布都必须由发布者额外确认 Gatekeeper、签名/公证需求与发布资产完整性。

## 版本一致性

发布者在打 tag 前必须检查：

| 位置 | 必须一致的内容 |
| --- | --- |
| `Info.plist` | `CFBundleShortVersionString`、`CFBundleVersion` |
| `README.md` | 当前下载链接和兼容协议说明 |
| `docs/INDEX.md` | 当前整理基线，如本次为架构或交付更新 |
| Release 标题与 tag | 与 `CFBundleShortVersionString` 对应，例如 `v0.6.3` |
| Release assets | arm64 ZIP、x86_64 ZIP、`SHA256SUMS.txt` |

`Wire.protocolVersion` 和 app 版本不是同一个维度：只有协议变更才必须阻止旧版互连；只改变 app 版本时是否兼容由协议和功能门槛决定。

## 发布步骤

```sh
./build.sh
shasum -a 256 -c dist/SHA256SUMS.txt
codesign --verify --deep --strict "dist/Thunder Display.app"
```

随后按 [validation.md](validation.md) 完成与本次变更相称的验证，创建 tag，并上传三个发布资产。不要只创建 tag：没有资产的 tag 会让用户只能下载源码，无法区分 arm64 与 x86_64。

## 恢复与回滚

- 已发布资产错误：创建新的补丁版本和新 Release，不替换用户已经安装的 ZIP。
- 仅 Release 页面漏传资产：补传同一个已验证 tag 的缺失资产，并核对 SHA-256。
- 协议不兼容：提高 `Wire.protocolVersion`，在 Release 说明中明确最低互连版本；不要静默接受不完整旧握手。
