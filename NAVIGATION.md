# V0.3.2 外部地图导航

日期：2026-09-04。用户要求仅支持高德与 Apple 地图，主要使用高德。

## 实现

- 推荐目的地和手动选点共用详情：两段式导航软件选择 + 一个明确的打开按钮，固定在详情底部，半屏时不用滚动寻找。
- 默认高德；使用 AppStorage `navigation-app-v1` 记忆选择，重新打开和覆盖升级继续保留。
- 高德使用官方 `iosamap://path` 路线规划接口，无新增 SDK、账户或 API Key。
- 传递目的地坐标、名称、出行方式；`t=2` 步行、`t=3` 骑行、`t=0` 驾车。
- 推荐和手动落点已经是现有地图坐标边界上的坐标，大陆按 GCJ-02 使用 `dev=0`，不再二次 WGS-84 偏移。不把 Apple 的 POI ID 当作高德 ID。
- 不传旧起点，交给所选地图使用实时位置；中文、&、#、+ 等通过 URLComponents 编码。
- `LSApplicationQueriesSchemes` 声明 `iosamap`，打开前检测；未安装、系统打开失败均显示明确错误，不悄悄换软件、不自动跳商店。
- Apple 地图保留原 MKMapItem 与步行/骑行/驾车选项。两种地图共用正在打开状态，避免重复点击。
- 外部地图自行重新规划，不传整条探索折线，所以外部路线/耗时可能不同；页面明确说明。选择高德不会更换 App 内底图或目的地搜索服务。
- 不改 Bundle ID、个人档案、记录策略与原始坐标存储。继续覆盖安装，不卸载。

## 验证

- 新增测试：高德链接参数、原样坐标与 dev=0、中文和特殊字符、三种交通方式、无效坐标拒绝、仅两个供应商。
- 完整回归 `artifacts/v032-final.xcresult`：43 项通过，0 失败、0 跳过（原 39 项 + 4 项导航测试）。底部固定操作区的最终复测 `artifacts/v032-delivery.xcresult` 同样 43 项通过，0 失败、0 跳过。
- Release 0.3.2 / 6 构建及 codesign 校验通过，确认实际安装包含 `LSApplicationQueriesSchemes: iosamap`。
- 手机已检测到高德 16.25.0；08:17 查询迷雾足迹安装版本为 0.3.2 / 6。最终布局包 08:18 同 Bundle ID 覆盖安装并正常打开探索页，不卸载，不写入/清空用户档案。
- `artifacts/v032-navigation-fixed.png` 已视觉检查：半屏详情底部同时可见两种地图选择与导航按钮。合成地点仅为 Debug 模拟器布局测试，不是真机导航目的地。
- 自动测试可证明链接生成正确，不等于已经在高德内走完全程；实际选点落地、导航执行以手机检查为准。

## 官方依据

- [高德 iOS 路线规划](https://lbs.amap.com/api/amap-mobile/guide/ios/route)：目的地、交通方式与坐标系参数。
- [高德 iOS 接入指南](https://developer.amap.com/api/amap-mobile/gettingstarted)：通过 iOS URL Scheme 调起地图。
