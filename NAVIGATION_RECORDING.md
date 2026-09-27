# 路书导航记录与行程统计

本轮范围：导航自动写入迷雾足迹、本次平均速度估时、路线分色。不做运动自动暂停。

- [x] 永久足迹沿用 RecordingStore；导航会话独立保存实际轨迹、计时与已走路段。
- [x] 新导航生成新会话，只有显式恢复才接续。预览不写入真实数据。
- [x] GPS 数据过滤、断点处理、避免首页和导航重复入库。
- [x] 按本次实际距离和累计时间估算；短暂停留计时，应用退出至恢复期间不计时。
- [x] 蓝色未走路书、灰色实际覆盖路段、黄橙色本次真实轨迹；绕路不涂灰跳过路段。
- [x] 针对新建/恢复隔离、停车估时、异常定位、永久记录编写验证。
- [x] 执行可用验证，记录构建与真机验收边界。

导航开始即记录，包括前往入口阶段；正式进入路书后开始路书平均速度统计。导航结束不改变首页原有记录意图。长期足迹不因重新导航而删除，本次轨迹也不从历史足迹反向加载。

## 本轮验证（2026-09-27）

- 本轮沿用 0.4.0 版本，按同一批发布继续完善，未重复递增版本。
- Xcode 26.3 固定无模拟器入口通过：静态分析、测试目标编译、Release Archive、arm64/无签名 IPA 结构检查；产物 build 9014。
- IPA 已回传至 `.build/navigation-recording-release/FogWalk-0.4.0-build9014-532a9d9b-dirty-vm-unsigned.ipa`，本地 ZIP CRC、包内 0.4.0 / 9014 版本与 SHA-256 均复核通过：`d8df6d676ecdfaf846cdcd9755bd26a63108162618042848e5253682e8360d3a`。此为本地验证产物，未签名，需重签后安装；正式下载使用下述 GitHub Release。
- `diagnostics/NavigationJourneyChecks.swift` 与生产 `Roadbook.swift`、`RoadbookJourney.swift` 在 Mac 上编译并实际执行，5 组检查通过：均速及停留、恢复/新建隔离、偏离路径、异常定位、跳过弯道不涂灰。该检查只使用坐标 DTO 作为类型支撑，不替代 iOS 集成测试。
- 新增 `RoadbookJourneyTests.swift`：上述计算场景，以及永久 SQLite 足迹保留、重新导航清空本次状态、预览不入库、旧会话写入拒绝、首页记录意图保留。随后按用户要求在 iPhone 17 Pro / iOS 26.3 模拟器实际执行完整 XCTest：72 通过、0 失败、0 跳过；另有 3 项个人数据测试由固定脚本预先排除，不计入 72 项。新增行程测试 6 项全部通过。结果包为 `.build/Tests-20260927T090959Z.xcresult`；本地使用资源符号规避配置，云端结果须独立核对。
- GitHub Actions #18 构建、云端 XCTest 与自动发布全部通过；正式发布 [0.4.0 / build 1018](https://github.com/liuxiaogang-com/FogWalk/releases/tag/v0.4.0-build1018)，源码提交 `484a6348e99238e95ed8c87a82ae7296b48c37a8`。云端产物与本地 build 9014 分开追溯。
- 真机待验收：先关闭首页记录再导航；途中绕路和停车；结束后重开同一路书应无旧轨迹；返回首页应保留两次真实足迹；锁屏、权限变化和保存失败提示。尚未验证后台连续性、耗电与最终视觉效果。

核心计算复核命令（macOS 仓库根目录）：

```sh
xcrun swiftc FogWalk/Models/Roadbook.swift FogWalk/Models/RoadbookJourney.swift diagnostics/NavigationJourneyChecks.swift -o .build/navigation-journey-checks
.build/navigation-journey-checks
```
