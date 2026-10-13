# FreeLaunchpad

免费的原生 macOS 应用启动器，使用 Swift、AppKit 和 SwiftUI 独立实现，MIT 许可。当前版本 **1.8.1**。

## 功能

- 全屏图标网格、名称与拼音搜索、键盘导航、分页和文件夹。
- 自由拖放并对齐不可见网格，支持跨页移动、交换位置和批量整理。
- 页面管理保持与启动台一致的布局，支持跨页勾选、批量移动、页面命名和撤销。
- 图标大小、横纵间距、透明背景、桌面壁纸、自定义背景及 Dock 隐藏可调。
- macOS 26 及更新版本使用 Apple Liquid Glass；旧系统使用半透明材质。
- 布局锁定、隐藏应用、额外扫描目录、登录启动和布局备份。
- 批量启动、正常退出应用；保存独立的桌面工作组，将应用普通窗口集中到新的 macOS 桌面。

## 下载安装

[下载 FreeLaunchpad 1.8.1 DMG（Apple Silicon）](https://github.com/zhoujiacheng1031/FreeLaunchpad/releases/download/v1.8.1/FreeLaunchpad-1.8.1-macOS-arm64.dmg)。打开磁盘映像，将 FreeLaunchpad 拖入 Applications 后启动。

其他安装包见 [GitHub Releases](https://github.com/zhoujiacheng1031/FreeLaunchpad/releases)。最低 macOS 13；Intel 安装包尚未提供。

## 构建与运行

需要 macOS 13 或更新版本、Xcode Command Line Tools。没有第三方应用运行依赖。

```sh
git clone git@github.com:zhoujiacheng1031/FreeLaunchpad.git
cd FreeLaunchpad
bash icon.sh
bash build.sh
bash test.sh
bash package-dmg.sh
```

解压 `dist/FreeLaunchpad-macOS-arm64.zip`，将应用放入 `~/Applications` 或 `/Applications` 后打开。Intel 构建可执行 `FREE_LAUNCHPAD_ARCH=x86_64 bash build.sh`；本次未实测 Intel。

构建使用本地临时签名，未经 Apple Developer ID 签名和公证。在同步目录内，Finder 元数据可能影响严格签名验证，推荐使用分发 ZIP 解压的副本。

## 使用

- **Control + Option + 空格**：显示或隐藏启动台。
- **Command + L**：页面管理。
- **Command + G**：桌面工作组。
- 输入应用名或拼音搜索，回车启动；Esc 返回。

桌面工作组中选择应用并保存，点击“新建桌面并归入应用”。首次使用需启用 FreeLaunchpad 的辅助功能权限；按钮旁提供系统设置入口。macOS 27 对应页面名为“设备控制和数据访问”。重新编译会改变签名；更新后若开关已开但运行仍报告无权限，可移除旧记录，重启应用，通过权限入口重新登记并开启。

更多操作见[使用指南](docs/USAGE.md)。数据保存在 `~/Library/Application Support/FreeLaunchpad/`，应用不含联网接口、遥测、账户或付费限制。

## 验证与限制

259 项回归检查通过。在 macOS 27.0.1、Apple Silicon 上实测：新建及切换桌面，启动计算器与时钟进入目标桌面，将两者已运行的普通窗口移入同一新桌面，以及批量正常退出。每个窗口移动成功均检查实际桌面归属。更多验收范围见[验证说明](docs/TESTING.md)。

桌面集成使用辅助功能与动态探测的非公开 SkyLight 接口，可能随系统升级改变。全屏、固定到特定桌面、显示在多个桌面和后续新开的窗口可能需要手动调整。每次点击创建新桌面，暂不复用已有桌面；退出应用不会删除桌面。应用使用正常退出，保存提示需在对应应用处理。

四／五指全局捏合、系统 Launchpad 布局迁移、系统图标色彩和应用卸载尚未实现。多显示器实机和其他系统版本未完成验收；备份中的应用及背景路径跨机器可能需调整。

## 实现来源与许可

使用 [REA](https://github.com/morluto/rea) 对 BuhoLaunchpad 2.0.0 进行只读包结构、资源和依赖分析后，独立实现常用功能。仓库不包含原应用的代码、图标或素材。可使用 `bash analyze.sh /path/to/BuhoLaunchpad.app` 重新运行分析；该脚本需要 REA 或 Node.js，生成材料留在本机。

桌面兼容策略参考 [Hammerspoon Spaces](https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces) 和[桥接接口头文件](https://gist.github.com/stephancasas-openai/1b31a8d76c6a103e4676ac196e06e9d8)，调用与结果验证以 Swift 独立实现，不依赖 Hammerspoon。不修改 SIP，不注入 Dock，不强制退出或重启成员应用。

[MIT License](LICENSE)。
