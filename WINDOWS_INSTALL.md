# Windows 构建与安装迷雾足迹

## 构建

源码是原生 iOS SwiftUI 项目，实际编译需要 macOS + Xcode。Windows 通过 GitHub Actions 触发云端构建即可，无需本地 Mac。

- 主分支源码或构建配置更新时自动运行，也可在 Actions → Build unsigned iOS IPA → Run workflow 手动触发。
- 使用 macos-26 与 Xcode 26.6，先独立构建 Release / arm64 / iPhoneOS 并上传 IPA，再启动模拟器与不依赖个人数据的 XCTest，避免模拟器冷启动拖慢打包。测试使用隔离宿主，不启动正式首页、GPS 和权限弹窗。
- 默认 `full` 模式：完整测试通过才发布 Release。手动运行可选 `build-only`：只打包并上传 Actions artifact，明确不运行测试、不发布 Release，也不替换最新已验证版本。
- 提前上传的 Actions IPA 中，`build-info.json` 的 `tests` 为 `pending`（待验证）或 `not_run`（仅打包）；完成验证的 Release 附件中为 `passed`。
- 三项依赖本地 demodata 的测试在 CI 中明确排除：完整个人数据导入、历史日期地图显示、完整个人数据启动性能。个人 CSV、GPX、备份和截图无需上传。
- 原有定位回调集成测试在模拟器未授予定位权限时会自行跳过；通过数和跳过数以每次测试日志为准。
- 每次成功构建自动发布到 [GitHub Releases](https://github.com/liuxiaogang-com/Citywalk/releases)：保存 IPA、SHA-256、build-info.json 和本安装说明。Release 资产不受 Actions artifact 保留期影响；只要仓库和 Release 未被删除，可持续下载历史版本。私有仓库下载需登录有权限的 GitHub 账号。
- Release 标签为 v版本-build构建号；重跑追加 -r重试次数，避免覆盖历史版本。标签指向 IPA 实际构建的源码提交，资产上传齐全后才发布。
- Actions 中也保留一份构建产物 30 天；诊断日志和 xcresult 保留 7 天。
- 本地 macOS 也可运行 bash scripts/ci-test.sh 和 bash scripts/ci-build-unsigned.sh；重复测试前请为原 .build/Tests.xcresult 改名，或使用干净检出目录。
- CI 无需 Apple ID、签名证书、描述文件或仓库签名密钥。
- GitHub 私有仓库的 Actions 使用账户可用配额，具体额度和计费以账户 Billing 页面为准。

## Windows 安装到 iPhone

可以通过 Windows 侧载。未签名 IPA 无法直接安装，须由侧载工具用你自己的 Apple ID 生成开发签名并安装。

1. iPhone 系统至少 iOS 26.0；这是当前工程的最低版本。
2. 从 [Sideloadly 官网](https://sideloadly.io/) 安装 Windows 版本，依照官网指引准备 Apple 设备驱动/iTunes 等依赖。
3. 用 USB 连接并解锁 iPhone，在手机上信任此电脑。
4. 在 Sideloadly 选择手机，拖入本次下载的 .ipa，使用你自己的 Apple ID，点击 Start，按提示完成认证。
5. 按 iOS 提示信任开发者；必要时到设置 → 隐私与安全性打开开发者模式并重启。
6. 启动迷雾足迹，按需要授予精准定位、后台定位权限，导入自己的 .fogwalk 备份。

免费 Apple ID 的开发签名通常 7 天到期，需要重新签名/刷新。后续更新保持相同 Apple ID 和应用标识。详见 [Sideloadly FAQ](https://sideloadly.io/faq)。

如果手机上已有旧 Mac 签名安装的版本，请先从旧 App 导出 .fogwalk 备份；不同签名团队可能无法直接覆盖安装。不要在未备份前删除旧 App。

## 验证边界

云端构建、测试和 IPA 结构验证不等于真机验收。Windows 签名安装是否成功须连接实际手机后确认；后台/锁屏记录、定位权限及耗电仍需真机测试。

迁移代码已有 GPS 恢复后状态文案可能仍停留在等待 GPS 的已知问题，详情见 SIMULATED_LOCATION_TEST.md；此次构建工作不改变应用业务行为。
