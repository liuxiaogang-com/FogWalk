# macOS 虚拟机验证、测试与无签名构建流程

最后实测：2026-09-14。

## 结论

Citywalk/FogWalk 当前采用下面的开发链路：

1. Windows 仓库是代码真源，在 Windows 上编辑和保留 Git 历史。
2. 通过 SSH/SFTP 将本次变更增量同步到 macOS 虚拟机的本地磁盘。
3. 日常校验使用无模拟器脚本，完成静态分析、测试目标编译、Release Archive 和无签名 arm64 IPA 打包。
4. 只有明确需要执行 XCTest 或运行 App 时才启动模拟器；不要把模拟器加入每次构建的默认流程。

这条无模拟器链路已经实测跑通，不需要登录 Apple 账号，也不需要启动 iOS Simulator。首次完整运行约 44 秒；保留 DerivedData 后，普通增量构建通常会更快。清理缓存、升级 Xcode 或大量修改资源后，下一次可能重新变慢。

## 固定环境和路径

| 项目 | 当前值 |
| --- | --- |
| Windows 代码真源 | `D:\02_Dev\最终迁移包-2026-09-04\02-Citywalk-已提交Git-完整项目\Citywalk\project` |
| macOS 虚拟机 | `192.168.159.135` |
| macOS 用户 | `xiao` |
| macOS 本地工作副本 | `/Users/xiao/Developer/Citywalk-ssh` |
| 连接方式 | SSH 执行命令，SFTP 增量传输文件 |
| macOS | 15.7.9 / x86_64（2026-09-13 实测） |
| Xcode | 26.3，Build 17C529（2026-09-13 实测） |
| iPhoneOS SDK | 用 `xcrun --sdk iphoneos --show-sdk-version` 现场确认 |
| Simulator Runtime | iOS 26.3（26.3.1 - 23D8133，2026-09-13 实测） |
| 项目最低系统 | iOS 26.0 |

连接密码不写入仓库、脚本或命令历史。需要连接时由用户提供或在 SSH/SFTP 提示符中输入。虚拟机、Xcode 和 SDK 版本可能变化，新会话不要只相信上表，先运行现场检查。

## 新会话开始时的只读检查

先确认 Windows 工作树，避免覆盖用户已有修改：

```powershell
Set-Location -LiteralPath 'D:\02_Dev\最终迁移包-2026-09-04\02-Citywalk-已提交Git-完整项目\Citywalk\project'
git status --short
```

再确认虚拟机连通性、工具链和 Mac 工作副本状态：

```powershell
ssh xiao@192.168.159.135 'xcodebuild -version; xcrun --sdk iphoneos --show-sdk-version; git -C /Users/xiao/Developer/Citywalk-ssh status --short'
```

如果 SSH 不通，先检查虚拟机是否开机、IP 是否改变、SSH 共享是否开启。不要因为网络失败就改写构建配置。

## 日常快速流程：不启动模拟器

### 1. 增量同步

同步前分别查看 Windows 和 Mac 两边的 `git status --short`。Windows 仓库是当前代码真源，只上传本轮确认要同步的文件并保留相对目录。

- 使用 SFTP 传输；不要直接在 SMB 共享目录中运行 Git 或 Xcode 构建。
- 不同步 `.git/`、`.build/`、DerivedData、临时日志和本机密钥。
- 不使用带删除目标文件效果的镜像参数。
- 遇到 Windows 与 Mac 同一文件都有独立修改时先停下比较，不要自动覆盖。
- Windows 删除了源文件时，先核实目标和 Git 状态，再在 Mac 精确删除对应文件。

macOS 构建脚本必须同步到：

```text
/Users/xiao/Developer/Citywalk-ssh/scripts/vm-validate-unsigned.sh
```

并确保可执行：

```powershell
ssh xiao@192.168.159.135 'chmod +x /Users/xiao/Developer/Citywalk-ssh/scripts/vm-validate-unsigned.sh'
```

### 2. 执行固定验证脚本

```powershell
ssh xiao@192.168.159.135 'cd /Users/xiao/Developer/Citywalk-ssh && bash scripts/vm-validate-unsigned.sh'
```

脚本依次执行：

1. `xcodebuild analyze`；
2. `xcodebuild build-for-testing`，只编译测试宿主和测试包；
3. Release 无签名 Archive；
4. 打包 unsigned IPA；
5. 校验 arm64、`Assets.car`、AppIcon、无 `_CodeSignature`、无 `embedded.mobileprovision`；
6. 生成 SHA-256 和构建信息 JSON。

脚本复用下面的缓存目录，不要在每次构建前删除：

```text
/Users/xiao/Developer/Citywalk-ssh/.build/vm/DerivedData
```

Mac 端产物位于：

```text
/Users/xiao/Developer/Citywalk-ssh/.build/vm/unsigned/
```

将 `.ipa`、`.ipa.sha256` 和 `.build-info.json` 一起用 SFTP 下载到 Windows：

```text
D:\文件共享\project\Citywalk\.build\vm-unsigned\
```

下载后用 Windows PowerShell 复核：

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath 'D:\文件共享\project\Citywalk\.build\vm-unsigned\具体文件名.ipa'
```

### 3. 如何表述验证结果

- `analyze` 通过：静态分析通过。
- `build-for-testing` 通过：测试目标编译通过，不等于测试已经执行。
- `archive` 通过：无签名真机 arm64 Release 构建通过。
- 无模拟器或真机时，不能声称 XCTest 已全部运行通过。
- 无签名 IPA 不能直接作为正常 App Store/开发签名包使用；安装到手机前仍需外部工具重签名。
- GitHub Actions 是独立的最终 CI 证据；虚拟机本地成功不能冒充远端 CI 已成功。

## 已知的 Xcode 26.3 虚拟机规避项

### 资源编译器

这台虚拟机中，Xcode 26.3 同时启动资源符号生成和资源目录编译时，`AssetCatalogSimulatorAgent` 可能在握手阶段卡死。项目当前没有使用生成的 Swift Asset Symbols，因此虚拟机脚本固定传入：

```text
ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO
```

这不会跳过资源目录本身：`Assets.car` 和 AppIcon 仍由当前 Xcode 完整编译。不要直接删除这个参数，也不要把旧的、未带该参数的构建脚本当作虚拟机默认入口。

该项是虚拟机专用规避；除非验证 GitHub CI 也有同一问题，否则不要擅自改变远端 CI 行为。

### MapKit 并发兼容

`FogWalk/Views/ExploreSheet.swift` 使用 `@preconcurrency import MapKit` 兼容当前 Xcode/Swift 的并发检查。没有新的编译证据时不要随意还原为普通 `import MapKit`。

## 按需流程：启动模拟器和执行 XCTest

模拟器不是日常构建前置条件。只有需要实际执行 XCTest、运行 App、截图或模拟定位时才使用本节。

### 启动设备

Mac 工作副本中已有选择 iOS 26 或更高版本 iPhone 的脚本：

```powershell
ssh xiao@192.168.159.135 'cd /Users/xiao/Developer/Citywalk-ssh && bash scripts/ci-prepare-simulator.sh'
```

脚本把 UUID 写入 `.build/test-simulator-id`。随后打开图形界面并等待系统真正启动：

```powershell
ssh xiao@192.168.159.135 'cd /Users/xiao/Developer/Citywalk-ssh && device_id=$(cat .build/test-simulator-id) && open -a Simulator --args -CurrentDeviceUDID "$device_id" && xcrun simctl bootstatus "$device_id" -b'
```

2026-09-13 的实测设备为 `iPhone 17 Pro`，UUID 为 `0D5E3F9E-8AF4-47A0-AED1-4257C56CCA0D`。从关机请求到 `bootstatus` 报告 `Finished` 约 36 秒，随后 `simctl io` 成功取得 iOS 主屏幕截图。UUID 在重新创建设备后会变化，自动化时优先读取 `.build/test-simulator-id`，不要永久依赖该 UUID。

### 执行测试

模拟器已完成启动后，可运行：

```powershell
ssh xiao@192.168.159.135 'cd /Users/xiao/Developer/Citywalk-ssh && bash scripts/ci-test.sh'
```

`ci-test.sh` 会构建测试宿主并执行 XCTest，同时明确跳过三个依赖私有演示数据或重型基准的测试。报告结果时必须分别列出 executed、skipped、failed，不能把跳过项表述为已通过。

脚本首次使用 `.build/Tests.xcresult`；如果该路径已经存在，会自动创建带 UTC 时间戳的新结果包，避免后续复测因为覆盖既有证据而失败。

模拟器在虚拟机中可能因首次挂载 Runtime、缓存失效、宿主负载或重启而明显变慢。只要状态继续变化，应耐心等待并阶段性查询：

```powershell
ssh xiao@192.168.159.135 'xcrun simctl list devices; xcrun simctl bootstatus booted'
```

需要关闭时再执行：

```powershell
ssh xiao@192.168.159.135 'xcrun simctl shutdown all; osascript -e "tell application \"Simulator\" to quit"'
```

不要在用户要求保持模拟器开启时运行关闭命令。

## 故障定位顺序

1. 先检查 SSH、Mac 磁盘空间、`xcodebuild -version`、iPhoneOS SDK 和 Simulator Runtime。
2. 再检查两边 Git 状态和实际同步文件，排除 Mac 工作副本仍是旧代码。
3. 资源阶段卡住时，确认日志中是否出现 `AssetCatalogSimulatorAgent`，并确认虚拟机脚本仍传入 `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO`。
4. 模拟器显示 `Booted` 但尚不能使用时，以 `xcrun simctl bootstatus <UUID> -b` 的 `Finished` 为准。
5. 只有确认缓存损坏后，才精确清理 `/Users/xiao/Developer/Citywalk-ssh/.build/vm/DerivedData`；不要删除仓库、用户目录或整个 `.build`。
6. 保留失败日志并区分：源码错误、资源编译器问题、模拟器问题、签名问题和网络同步问题。

## 当前已验证证据

- 无模拟器完整流程：`ANALYZE SUCCEEDED`、`TEST BUILD SUCCEEDED`、`ARCHIVE SUCCEEDED`。
- 完整流程实测耗时约 44 秒。
- 当前 Xcode 编译了完整 `Assets.car` 和 AppIcon。
- 已生成并校验无签名 arm64 IPA。
- 2026-09-14 的 V0.3.5 本地复测在 iPhone 17 Pro / iOS Simulator 26.3.1 上真实执行 54 项 XCTest，54 通过、0 跳过、0 失败；结果包为 `.build/Tests-20260913T161632Z.xcresult`。固定脚本另明确排除 3 项依赖私有演示数据或重型基准的测试，这 3 项不计入 54 项。
- 原先存在竞争的 `RecordingTests.testLocationCallbacksPersistForForegroundAndBackgroundContexts` 已通过向 `LocationManager` 注入隔离的测试传感器修正，本次完整复测通过；生产默认仍使用真实 `CLLocationManager`。
- 2026-09-13 模拟器从关机到系统启动完成约 36 秒，iOS 26.3 主屏幕截图成功。
- 2026-09-13 在 iPhone 17 Pro / iOS Simulator 26.3.1 上真实执行 XCTest：首次完整 `.xcresult` 为 `Passed`，共 50 项，其中 49 通过、1 跳过、0 失败；冷构建加执行的脚本总耗时约 42 秒。
- 首次唯一运行时跳过项是 `RecordingTests.testLocationCallbacksPersistForForegroundAndBackgroundContexts`，原因是尚未给模拟器测试宿主授予定位权限。随后只给该测试模拟器中的 `com.citywalk.FogWalkDemo` 授予 `location-always`，单独重跑该项为 1 通过、0 失败。
- 授权后曾有一次完整复测为 49 通过、0 跳过、1 失败；当时系统 Core Location 默认位置与测试手工注入发生竞争。这是修正前的历史证据，不能代表当前状态。
- `ci-test.sh` 还通过 `-skip-testing` 显式排除了 3 项私有演示数据或重型基准测试；这 3 项不包含在上述 50 项中，不能表述为已经执行通过。
- 本次 Mac 端证据：首次结果 `.build/Tests.xcresult`、授权后单项结果 `.build/Tests-location-permission.xcresult`、授权后完整复测 `.build/Tests-location-granted-full.xcresult`、完整复测日志 `.build/test-location-granted-full.log`；模拟器测试缓存为 `.build/SimulatorDerivedData`。
- 本次模拟器截图的 Windows 临时位置：`.build/vm-simulator/iPhone-17-Pro-boot.png`。

后续每次都应以当次日志、构建信息和哈希为准，不沿用本节的旧产物结论。
