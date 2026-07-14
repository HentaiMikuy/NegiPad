# AppTileDemo

一个使用 SwiftUI 编写的原生 macOS App。它会读取本机已经安装的应用，并按照应用包中的分类信息展示为可启动的磁贴。

## 当前功能

- 启动时显示类似 Raycast 的居中浮动面板，并使用紧凑图标网格展示应用
- 使用接近经典 Launchpad 的紧凑图标网格，可拖拽调整应用顺序
- 将应用拖到另一图标中央可创建文件夹，点击文件夹后可直接编辑名称并保存
- 浮动面板失去焦点时自动隐藏，按 `Esc` 也可以关闭
- 搜索框自动聚焦，支持方向键选择和回车启动应用
- 扫描 `/Applications`、`~/Applications` 和 `/System/Applications`
- 自动读取真实应用名称、图标、版本和 Bundle ID
- 保留完整的分类磁贴管理界面
- 搜索应用、分类和 Bundle ID
- 点击磁贴启动应用
- 收藏应用
- 通过右键菜单手动修改分类
- 在 Finder 中显示应用
- 刷新应用列表

收藏、手动分类和拖拽后的应用顺序使用 `UserDefaults` 保存在本机。

## 两种界面

- 日常启动器：应用启动或点击 Dock 图标时显示浮动搜索面板。
- 应用管理：点击浮动面板底部的“应用管理”，或按 `Command + ,` 打开原有磁贴界面。

浮动面板隐藏后应用仍会留在后台运行。需要彻底退出时按 `Command + Q`。

## 运行

使用 Xcode 打开：

```bash
open /Users/konomip/Study/AI_Talk/AppTileDemo/AppTileDemo.xcodeproj
```

在 Xcode 顶部选择 `AppTileDemo` Scheme 和 `My Mac`，然后按 `Command + R`。

也可以通过终端构建正式的 `.app`：

```bash
cd /Users/konomip/Study/AI_Talk/AppTileDemo
xcodebuild -project AppTileDemo.xcodeproj \
  -scheme AppTileDemo \
  -configuration Debug \
  -derivedDataPath .xcode-build \
  build
```

构建产物位于：

```bash
.xcode-build/Build/Products/Debug/AppTileDemo.app
```

## 后续适合增加

- 小、中、宽三种磁贴尺寸
- 用户自定义分类
- 应用隐藏和重复版本管理
- 全局快捷键呼出窗口
- 拼音和用户关键词搜索
- 登录启动及后台监听应用安装变化
