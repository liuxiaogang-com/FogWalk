# iOS 构建耗时与失败排查

日期：2026-09-13。下面是单次云端实测，不代表每次运行都能保证相同耗时。

## 为什么之前等待很久

- [34744840068](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34744840068)：测试步骤 8 分 17 秒；编译结束到用例启动约 5 分 12 秒，实际用例约 19 秒。失败位于地图测试，没有进入真机归档。
- 新增屏幕位置诊断后，[34745606449](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34745606449) 确认失败箭头的屏幕点为 `(-675.5, -356.7)`，地图范围为 `(0, 0, 393, 778)`，属于屏幕外正常回收，增加等待无法解决。测试复用了探索目的地全览参数，不能代表真实首页，已分离该场景。随后 [34746380422](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34746380422) 的初始距离断言进一步确认：首次布局前镜头请求为 4,000 米，实际却被压为约 46.15 米。
- 这次尝试把模拟器冷启动与真机归档重叠，归档反而耗时 5 分 18 秒；日志显示命令初始化和构建准备也显著变慢，因此未保留这种执行顺序。

## 当前流程

1. 独立归档并验证未签名真机 IPA，立即上传 Actions artifact。
2. `full` 模式随后启动模拟器，同时构建测试宿主；等待模拟器就绪后执行 XCTest。
3. 测试宿主使用空白窗口；每个地图测试创建自己的地图，不启动正式首页、定位和权限提示。只在 Debug / simulator / TestAction 生效。
4. 测试通过后，发布有 `tests: passed` 的 Release；失败不会发布。
5. 手动 `build-only` 仅打包、验证 IPA 结构并上传 Actions artifact，跳过测试与 Release，不替换已验证版本。

提前上传的 Actions 包标记 `tests: pending` 或 `not_run`，不等同于经过测试的 Release。三项个人数据测试仍预先排除，定位权限测试仍按既有条件跳过；没有忽略其他测试失败。

## 地图回归修正

首页测试不再携带探索目的地、路线和自动全览参数。首页初始镜头使用明确距离，并由普通 UIView 容器暂存请求，在内嵌地图首次完成有效布局后应用；布局前的方向/位置更新读取暂存镜头，避免复制已被钳制的距离。遵循 [Apple MKMapView 文档](https://developer.apple.com/documentation/mapkit/mkmapview)，不继承 MKMapView。测试检查初始距离、箭头在屏幕内、手机方向随缩放/拖动持续更新、北方朝向、居中保留缩放和覆盖层复用。标记等待按视图实际出现判断，失败保留截图及坐标诊断。

## 本轮验证

- 完整验证：[34746760137](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34746760137)，源码 `ddc875b429b53651ff68adcca175c3aec5c39a78`。归档 47 秒，任务启动到 IPA 上传完成 53 秒，整个任务 6 分 40 秒（不含排队）；实际用例约 9 秒。47 项通过、1 项按既有定位权限条件跳过、0 失败，另预先排除 3 项个人数据测试。
- 正式 Release：[v0.3.4-build1014](https://github.com/liuxiaogang-com/Citywalk/releases/tag/v0.3.4-build1014)。本地 `../构建产物/34746760137` 已验证 SHA-256、ZIP CRC、arm64/iPhoneOS、未签名、可执行权限和构建来源。SHA-256：`a76cbbbc3ceea93d804a4d875f3ea38741ca74305890157dad40f7eced94c718`。
- 快速模式：[34747098674](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34747098674)。整项任务 52 秒（不含排队），归档 40 秒；模拟器、XCTest、Release 发布全部按配置跳过。build 1015 已从 Actions 下载并校验，metadata 明确为 `build-only` / `not_run`；目录单独标记 `34747098674-build-only`。
- 快速模式结束后，最新 Release 仍为通过完整验证的 build 1014。本次交付安装优先使用 build 1014。
- 完整测试仍需额外等待，时间主要花在模拟器冷启动和测试宿主编译/启动；没有承诺完整验证也能在 1 分钟内结束。Windows 不能本地执行 Xcode，真机侧载、罗盘和实际行走仍需手机验收。

手动快速打包：Actions → Build unsigned iOS IPA → Run workflow → `validation_mode=build-only`。CLI 可用 `gh workflow run ios-unsigned.yml --repo liuxiaogang-com/Citywalk --ref main -f validation_mode=build-only`。默认推送仍走 `full`。

## V0.3.5 发布接口恢复记录

[34748575715](https://github.com/liuxiaogang-com/Citywalk/actions/runs/34748575715) 的编译和测试通过（49 通过、1 跳过、另排除 3 项私人数据测试），最终创建 Release 的请求返回 HTTP 500。无需因此重新构建 App：从 Actions 下载原 IPA，核对源码、测试日志和 SHA-256 后，可恢复发布步骤。

本次恢复过程：确认版本 Release 尚不存在，建立指向已验证源码 1779a6ec52852cc98c84b139bb4ecae48fbc772f 的标签；REST 创建草稿时仅传 tag_name/name/body/draft/prerelease，上传四个附件并校验摘要。带 make_latest 的发布请求仍异常，仅 PATCH draft=false 成功；说明单独更新成功，GitHub latest 查询也确认新版本已成为最新 Release。未覆盖任何历史附件。发布前后 SHA-256 均为 9e5681088f1b09aa724573447147382b2a0b2564af7aebcfdb7c685a304cba29。

这是本次接口恢复的实测路径，不推断 GitHub 全站故障；历史 Actions 仍显示发布失败，实际完成的版本为 [v0.3.5-build1016](https://github.com/liuxiaogang-com/Citywalk/releases/tag/v0.3.5-build1016)。任何写请求返回不确定结果后，应先读取远端状态，再决定是否补做，避免重复创建或覆盖。
