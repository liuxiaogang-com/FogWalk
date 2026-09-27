# Citywalk/FogWalk agent instructions

本文件适用于整个仓库。

## 版本管理（后续开发必须执行）

版本号以 `FogWalk.xcodeproj/project.pbxproj` 中的 `MARKETING_VERSION` 为准，不得长期沿用固定版本，也不得只改 IPA 文件名或 README。使用 `scripts/ci-version.py` 统一更新 App 和测试目标的所有配置。

1. 开始一批功能或修复工作时，先运行 `python3 scripts/ci-version.py check`，并查看 `CHANGELOG.md`，确认当前版本是否已为这批工作递增。Windows 使用可用的 Python 3 解释器执行同一脚本；不要假定 `python` 已在 PATH 中。
2. 准备交付新版本安装包或推送会触发发布的代码前，必须按本批变更升级版本：修复问题用 `python3 scripts/ci-version.py patch`，新增功能用 `python3 scripts/ci-version.py minor`，明确的重大版本升级用 `python3 scripts/ci-version.py major`。常规修复和功能升级属于开发收尾工作，应主动执行，不要等用户再次提醒。
3. 每批发布只递增一次。同一待发布版本的继续开发、验证修复、重新打包或 CI 重跑，不重复递增；纯文档修改无需升级 App 版本。不能仅因开始新会话就升级，也不能只增加 build 编号代替新版本升级。
4. 同步维护 `CHANGELOG.md`，写明该版本实际变更；发布前标注“待发布”，确认 Release 成功后再记录发布日期。历史版本记录保留，不做全仓库版本字符串替换。
5. 递增后再次运行 `check`。它只检查配置一致性，不会自动递增，也不能替代构建测试。CI 和虚拟机打包分别生成构建号，IPA 与 Release 使用实际包内版本；出包后核对 IPA 的 Info.plist、构建元数据和文件名，发布后核对 Release 标签与标题。
6. 推送前遵循固定本地验证流程。版本更新不代表已经打包、测试或发布成功，也不构成提交、推送或发布授权；未经用户要求，不提交、不推送。

示例：`0.4.0 → 0.4.1` 为修复，`0.4.0 → 0.5.0` 为新增功能，`→ 1.0.0` 为明确的重大版本。每次以工程和更新记录的当前状态为准，不把示例当作固定目标版本。此流程对应 `ops-005`（发版前递增版本、产物携带版本号）。

## macOS 虚拟机流程入口

凡是涉及 iOS 编译、Xcode 校验、无签名 IPA、Windows 到 Mac 同步、Simulator、XCTest，或者新会话/上下文压缩后继续相关工作，必须先完整阅读 [`MACOS_VM_WORKFLOW.md`](MACOS_VM_WORKFLOW.md)，再执行命令。

核心约束：

- Windows 当前仓库是代码真源；macOS `/Users/xiao/Developer/Citywalk-ssh` 是本地构建副本。
- 操作前先查看 Windows 与 Mac 两边的 Git 状态，保留并避开用户的无关修改。
- 默认通过 SFTP 增量同步，禁止把 `.git`、`.build`、DerivedData 或密钥同步过去，禁止使用会删除目标文件的镜像参数。
- 日常验证默认运行 `scripts/vm-validate-unsigned.sh`，不要启动模拟器。
- Xcode 26.3 虚拟机必须保留 `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO` 规避项，除非新的实测证明已经不需要。
- 只有用户明确要求运行 App、执行 XCTest、截图或模拟定位时才启动模拟器；启动完成以 `simctl bootstatus ... -b` 的 `Finished` 为准。
- 严格区分测试目标编译、XCTest 实际执行、无签名 Archive、外部重签安装和 GitHub CI；不要扩大验证结论。
- 不把密码或其他凭据写入仓库、脚本、日志或命令行参数；连接凭据由用户提供或交互输入。
- 未经用户要求，不提交、不推送、不覆盖或格式化无关文件。

工程级执行避坑遵循 `ops-004`（推送前使用固定本地验证入口）和 `ops-022`（明确本地构建与 CI 的一致项和差异项）。
