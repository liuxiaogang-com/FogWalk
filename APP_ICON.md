# V0.3.5 App 图标

使用用户在“撰写 Citywalk 小红书文案”任务中选定的最终透明 PNG。原文件实际路径为 `C:/Users/xiao/.codex/generated_images/01a099d7-a406-7280-8dae-dc50b887a8d9/FogWalk-icon-final-transparent.png`。

只进行了 AppIcon 资源格式转换：裁去外围透明留白、按比例缩放至 1024×1024，用深青色补齐透明处并输出无 Alpha 的 RGB PNG；原有山谷、发光道路和暖光图案不重绘。系统负责应用最终图标蒙版。源图保留在原目录。

- 源图 SHA-256：`dcc576b064ccdb36b27f4c7fdca4871a54ac9becba7dfb510075d81445cfe7cc`
- AppIcon SHA-256：`0877af09c7c21ad8d17f3627a6956c452e4a4a5293c2a21bdd24e2462785bd74`
- 资源：`FogWalk/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- Debug / Release 均使用工程已有的 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- `Contents.json` 使用 iOS universal 1024×1024 单图配置，由 Xcode 生成设备尺寸。
- `scripts/prepare-app-icon.ps1 -SourcePath <最终透明PNG>` 可复现格式转换。
- 构建脚本检查 IPA 的主图标注册、实际 AppIcon PNG 和 Assets.car；build-info.json 记录源资源哈希与编译文件名。

配置依据：[Apple 的 AppIcon 资源目录说明](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。

验证结果：V0.3.5 / build 1016 的 IPA 已包含 CFBundlePrimaryIcon / AppIcon 注册、编译的 AppIcon PNG 与 Assets.car；build-info.json 中资源哈希与上述一致。发布后的 Release 已下载比对，确认与云端打包产物完全相同。
