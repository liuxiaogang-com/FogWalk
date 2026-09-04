# 迷雾足迹

一个使用 SwiftUI、MapKit 和 Core Location 制作的原生 iPhone 应用。它导入“一生足迹”导出的照片位置 CSV、轨迹 CSV 与 GPX，在 Apple 地图上显示可信轨迹，并用迷雾表现已探索和未探索区域。

当前功能核对、修正和验证边界以 [FUNCTIONAL_AUDIT.md](FUNCTIONAL_AUDIT.md) 为准，早期方案保留为历史记录。

V0.3.2 新增高德 / Apple 地图导航选择，默认高德并记忆选择；具体规则及验证见 [NAVIGATION.md](NAVIGATION.md)。

完整、已确认的需求与技术规则见 [PRODUCT_SPEC.md](PRODUCT_SPEC.md)。

V0.2 第一轮的范围、接续清单与验收结果见 [V02_PLAN.md](V02_PLAN.md)。V0.1 本地代码基线为 `039c12b` / `v0.1-baseline`，无远程仓库，个人数据不入 Git。

V0.2.1 已加入大数据快速启动缓存，方案、性能实测及手机安装状态见 [STARTUP_PERFORMANCE.md](STARTUP_PERFORMANCE.md)。

V0.3 双模式记录、后台与锁屏配置、运动判断及验证边界见 [RECORDING_PLAN.md](RECORDING_PLAN.md)。后台外出连续性和耗电仍需真机实测。

## 当前已实现

- 原生 iOS 26 SwiftUI 工程；
- 空库启动，App 安装包不内置任何个人 CSV、GPX 或足迹档案；
- 从系统“文件”选择器一次选择一个或多个轨迹 CSV、照片位置 CSV、GPX 或 `.fogwalk` 备份；
- 150,664 条轨迹 CSV、150,664 条 GPX 和 3,519 条照片位置 CSV 的完整解析验证；
- 按时间戳和约 10 米坐标精度去重，得到 154,183 个唯一位置；
- 导入后写入 App 的 Application Support 二进制档案，后续启动直接恢复，无需再次解析 CSV/GPX；
- 地图先显示，后续启动从校验过的紧凑缓存恢复迷雾/探索网格/四种日期轨迹；完整原档案仅在导入合并或导出时按需读取，缓存失效会自动重建；
- 从右上角数据菜单导出单个 `.fogwalk` 备份文件，可再次导入或用于换机；
- 5 分钟 / 300 米 / 100 米定位精度 / 65 m/s 推算速度的可信连接规则；
- 今日、七日、本月、一生筛选和可信距离统计；
- MapKit 自定义迷雾：0–50 米清晰、50–100 米渐变、外部暗雾；
- 中国大陆 WGS-84 到 Apple 地图坐标的显示边界校准，原始导入和导出数据保持不变；
- 单独的橙色轨迹覆盖层；
- 正常/省电两种出行记录模式；位置位移判断，以及用户主动开启的可选运动辅助；后台定位配置和 SQLite WAL 增量保存；支持原备份与新记录合并导出；
- 地图主体首页、紧凑状态与带文字的迷雾 / 轨迹 / 定位控制，“去探索”作为底部主操作；
- 全屏目的地探索地图，顶部紧凑条件、底部横向卡片、独立目的地详情，先在本 App 的迷雾中查看路线；
- 探索页默认以当前定位为中心显示约 3 公里的局部地图，GPS 暂不可用时使用最近导入位置；
- 默认开启迷雾并关闭历史轨迹线，仍可从首页手动切换；
- 首页定位按钮会回到实时位置，并恢复约 3 公里的固定缩放；
- 咖啡厅和餐饮使用结构化 POI、中文品类词与常见品牌词组合检索，仍优先选择未探索终点；
- 搜索结果最多显示 6 个地图标记；底部卡片横向滑动并露出下一项，滑卡或点击标记都会同步切换目的地与路线；
- 搜索条件本地记忆、取消和请求代次校验、换一批排重；咖啡与茶饮分开，独立咖啡馆不因非品牌而降权；
- 推荐必须取得真实道路路线并满足单程 ETA 预算；无可用路线时明确报错和重试，不推荐直线估算结果；
- 手动选点先在 App 内预览路线；详情可选择高德 / Apple 地图导航，外部地图按当前位置重新规划；
- 首页图层与回顾面板、累计迷雾与日期轨迹分离；空库允许定位后直接探索；
- 独立的地图选点模式：长按落点、解析地址、显示探索状态和直线距离，再决定是否导航；
- 25 米栅格表达 50 米探索半径，可信轨迹段插值；已探索终点硬性排除；
- MapKit 结构化 POI 与中文自然语言搜索兜底、明确命名终点、路线与真实 ETA；
- 按沿途未知、终点周边未知和时间预算综合排序，最终可打开高德或 Apple 地图导航；
- XCTest 数据、阈值、可见几何、记录持久化和地图交互测试。

## 本地运行

打开：

```text
FogWalk.xcodeproj
```

选择 `FogWalk` Scheme 和 iOS 26 模拟器运行。首次启动为空库，通过首页“导入备份”或右上角菜单导入数据。

命令行构建：

```sh
xcodebuild -project FogWalk.xcodeproj -scheme FogWalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

命令行测试：

```sh
xcodebuild test -project FogWalk.xcodeproj -scheme FogWalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO
```

## 当前边界

- 当前产品仅提供目的地探索，没有闭环入口和假环线。全路网解析与闭环规划不在当前版本内。
- 目的地模式已调用 MapKit 搜索和路线服务，但结果依赖网络和当地 Apple 地图数据。
- 导入数据使用二进制档案与衍生缓存；设备新增记录使用 SQLite WAL。跨日刷新日期筛选；不涉及当前日期范围的旧档案仍复用累计迷雾缓存。
- 真机前台定位和保存已验证；后台外出、锁屏连续性、运动辅助开关的电量差异尚待对照测试。
- App 已完成开发签名，并安装启动于用户的 iPhone 16 Pro；状态见 `PRODUCT_SPEC.md` 的最新实现记录。

## 视觉验收截图

- `artifacts/fogwalk-home-corridor.png`：首页、迷雾通道和真实轨迹。
- `artifacts/fogwalk-explore-sheet.png`：探索参数面板。
- `artifacts/fogwalk-empty-import.png`：不携带个人数据的空库导入首页。
- `artifacts/fogwalk-dark-fog-v3.png`：坐标校准后的深色地图与连续羽化迷雾。
- `artifacts/main-redesign.png`：以地图和“去探索”为核心的新首页。
- `artifacts/explore-redesign-options.png`：完整二级探索地图与可收起参数面板。
- `artifacts/explore-manual-selection.png`：不挤占推荐卡的长按地图选点模式。
- `artifacts/explore-minimal-options.png`：精简为三项下拉条件与单一主操作的探索面板。
- `artifacts/explore-current-center-fog-only.png`：当前位置局部视野与默认仅迷雾状态。
- `artifacts/explore-place-map-layout.png`：条件置顶与地点地图式结果入口布局。

V0.2 视觉检查使用 `--ui-fixture` 启动参数和合成地点，代码仅编译进 Debug 模拟器，不进入真机或 Release 包，也不读取或修改个人足迹。验收图统一以 `artifacts/v02-` 开头。
