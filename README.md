# 迷雾足迹 · FogWalk

**有时候，出门只差一个理由。**

把熟悉的城市变成一张等待探索的地图：走过的路逐渐点亮，没去过的地方留在迷雾里。不知道去哪，就发现一个新目的地；心里已有方向，就边走边探索；收藏了喜欢的路线，也可以导入路书跟着走。

## 你可以用它做什么

- **用足迹点亮城市**：记录步行、骑行等出行轨迹，逐步揭开沿途迷雾，按今日、七日、本月或一生回顾走过的路。支持正常 / 省电记录模式。
- **发现还没去过的地方**：选择出行方式、单程时间和地点类型，寻找公园、咖啡厅等未探索目的地，推荐时也考虑沿途未知区域。可预览道路路线，再使用高德或 Apple 地图导航。
- **有目的地，也有自由探索的空间**：在首页搜索地点，查看目标方位和路线参考，沿途自己决定怎么走。目标移出屏幕后仍有方向与直线距离提示；这里提供的是方向指引，不是逐路口导航。地图还可跟随手机朝向，方便对照眼前的路。
- **把收藏的路书走一遍**：导入行者等工具导出的 GPX 路书，预览全程并沿路径导航，查看剩余距离，接收转弯语音与偏离提醒。环线路书支持自选入口，到达后沿原路线顺序绕行一圈。转弯提示按 GPX 路径形状推算，不含道路通行校验。
- **让旧足迹接上新旅程**：导入“一生足迹”导出的轨迹 CSV、照片位置 CSV 和 GPX 历史轨迹，使用 `.fogwalk` 备份与恢复足迹。路书单独保存，导入待走路线不会提前点亮迷雾。

足迹数据保存在本机，安装包不包含个人数据；地点搜索和道路路线规划需要网络。

## 最低要求与下载

| 用途 | 要求 / 下载 |
| --- | --- |
| 运行 App | iPhone，**iOS 26.0 或更高版本** |
| 下载 App | [GitHub Releases](https://github.com/liuxiaogang-com/FogWalk/releases)：展开 Assets，下载 `.ipa` 文件 |
| 签名安装 | [Sideloadly](https://sideloadly.io/)（Windows / macOS）及自己的 Apple 账号 |
| 从源码开发 | macOS、[Xcode 26 或更高版本](https://developer.apple.com/xcode/)，包含 iOS 26 SDK；macOS 版本须满足所选 Xcode 的要求 |

Releases 提供的是**未签名 IPA**，不能直接在手机上点击安装，需要按以下步骤签名。仅安装 App 无需 Xcode。

## 安装（Windows / macOS）

1. 下载 IPA 和对应系统的 Sideloadly。Windows 按官网指引安装桌面版 iTunes、iCloud 等依赖；现代 macOS 通过 Finder 管理设备。
2. 用 USB 连接并解锁 iPhone，在手机上选择“信任此电脑”。
3. 打开 Sideloadly，选择 **iPhone**，拖入 IPA，填写自己的 Apple 账号，点击 **Start**，按提示完成认证和安装。
4. 如提示开发者未受信任，前往 **设置 → 通用 → VPN 与设备管理**，信任对应的开发者条目。
5. 前往 **设置 → 隐私与安全性 → 开发者模式**，开启后按提示重启，并在重启后确认开启。本项目要求 iOS 26，使用上述签名方式必须开启开发者模式才能运行；Windows 和 macOS 均相同。
6. 打开 App，按需授予定位权限，即可开始探索或导入已有足迹。

免费 Apple 账号签名通常 **7 天有效**，到期需重新签名；也可配置 Sideloadly 自动刷新，刷新时电脑和手机需能连接。更新时保持相同 Apple 账号和应用标识，直接覆盖安装；更换签名账号或卸载前，请先导出 `.fogwalk` 备份。

参考：[Sideloadly FAQ](https://sideloadly.io/faq) · [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 开发

项目使用 SwiftUI、MapKit 和 Core Location 构建。

1. 克隆本仓库，用 Xcode 打开 `FogWalk.xcodeproj`。
2. 选择 `FogWalk` Scheme 和已安装的 iOS 26 或更高版本模拟器，点击 Run；执行测试使用 **Product → Test**。
3. 真机调试时，在 **Signing & Capabilities** 中选择自己的开发团队，并在 iPhone 上开启开发者模式。

在 macOS 仓库根目录打包未签名 IPA：

```sh
bash scripts/ci-build-unsigned.sh
```

产物位于 `.build/unsigned/`。Windows 可编辑源码，编译需使用 macOS + Xcode，或通过 [GitHub Actions](https://github.com/liuxiaogang-com/FogWalk/actions/workflows/ios-unsigned.yml) 构建。测试通过不代表后台定位连续性或耗电已完成真机验证。

### 版本管理

发版前运行 `python3 scripts/ci-version.py patch`（修复）、`minor`（新功能）或 `major`（重大版本）；Windows 使用已安装的 Python 3 执行同一脚本。脚本统一更新工程版本和本地构建号，`check` 可检查当前值。同一版本的重复构建保留版本号，由 CI / 虚拟机打包流程分别递增构建号；IPA 文件名与 Release 标题自动读取实际包内版本。变更记录见 [CHANGELOG.md](CHANGELOG.md)。
