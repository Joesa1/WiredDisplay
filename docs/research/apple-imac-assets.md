# Apple iMac 产品素材

状态：已下载官方识别页引用的原始图，未被应用加载。资料截至 2026-10-07。

素材目录：[Resources/DeviceAssets/Apple/iMac](../../Resources/DeviceAssets/Apple/iMac/)。型号到文件的机器可读映射在 [asset-manifest.json](../../Resources/DeviceAssets/Apple/iMac/asset-manifest.json) 的 `preferredViews`。

可直接浏览全部型号视图：[gallery.html](../../Resources/DeviceAssets/Apple/iMac/gallery.html)。

Apple 芯片 iMac 的设备视图统一使用 2024 年款两张透明产品图：`iMac21,2`、`Mac15,4`、`Mac16,2` 使用双接口图；`iMac21,1`、`Mac15,5`、`Mac16,3` 使用四接口图。

## 已下载内容

- 覆盖 2011 年起所有支持 Thunderbolt 的 iMac 型号组，包括 iMac Pro 与 2021、2023、2024 的 24 英寸 iMac。
- 优先素材来自各机型的 Apple 技术规格页，例如 [2017 21.5 英寸 iMac](https://support.apple.com/zh-cn/111921) 和 [2017 21.5 英寸 Retina 4K iMac](https://support.apple.com/zh-cn/112026)。
- 技术规格页缺少产品图时，才回退到 Apple [识别 iMac](https://support.apple.com/en-us/108054) 页所引用的官方产品图。目前已确认 2011 年机型规格页展示的是端口图，2019 年 27 英寸及 2024 年 24 英寸规格页展示的是能效标签；这些都不能作为设备视图。
- `technical-specs/` 有 18 张可用的规格页产品图；其中带 alpha 的 PNG 可直接作为无背景产品图候选。`official/` 保留 23 张识别页原图以补足缺图机型。
- `transparent/` 有 25 张按 `hw.model` 命名的最终设备视图，均为透明 PNG；它们由 [prepare_imac_transparent_views.py](../../tools/prepare_imac_transparent_views.py) 从上述原件可重复生成。

## 选择规则

未来 UI 按 `PeerIdentity.model` 查询 manifest：

```text
iMac18,1 -> technical-specs/111921_imac21inch2017.png
iMac18,2 -> technical-specs/112026_Imac21inch4k2017.png
iMac18,3 -> technical-specs/111969_imac27inch2017.png
Mac16,3  -> official/imac-24in-2024-four-ports-colors.png
```

`iMac15,1` 同时覆盖 2014 年末和 2015 年中的 27 英寸 5K iMac；`hw.model` 不能区分这两个发行批次。因此 manifest 为它指定一张稳定的默认图，同时保留另一张官方原图供未来以序列号或机型年份补充识别时使用。

## 进入产品前的限制

官方原图适合作为调研与内部验证素材。将其复制到公开发布包前，需要单独确认素材授权与分发规则；此目录不把它们声明为本项目自有图标或矢量资产。
