<div align="right">

[English](README.md) | 简体中文

</div>

# NegiPad(葱启动器)

一个使用 SwiftUI 编写的原生 macOS 应用启动器:按全局快捷键唤出居中浮动面板,搜索并启动本机已安装的应用,同时保留 Launchpad 式的磁贴整理界面。

## 当前功能

- 启动时显示类似 Raycast 的居中浮动面板,并使用紧凑图标网格展示应用
- 使用接近经典 Launchpad 的紧凑图标网格,可拖拽调整应用顺序
- 启动器支持向下滚动和左右翻页两种浏览方式,并可设置 `Shift + 滚轮` 或直接滚轮翻页
- 将应用拖到另一图标中央可创建文件夹,点击文件夹后可直接编辑名称并保存
- 文件夹内的应用可拖到面板外移回主网格,少于两个成员时自动解散文件夹
- 浮动面板失去焦点时自动隐藏,按 `Esc` 也可以关闭
- 搜索框自动聚焦,支持方向键选择和回车启动应用
- 支持自定义全局快捷键唤醒启动器,默认使用 `Option + Space`,并检查快捷键冲突
- 扫描 `/Applications`、`~/Applications` 和 `/System/Applications`
- 运行期间自动监听应用目录,新安装、删除或移动应用后自动刷新
- 自动读取真实应用名称、图标、版本和 Bundle ID
- 保留完整的分类磁贴管理界面
- 搜索应用、分类和 Bundle ID
- 点击磁贴启动应用
- 收藏应用
- 支持创建自定义分类、选择分类图标和颜色,并通过右键菜单编辑或删除
- 通过应用右键菜单手动修改分类
- 在 Finder 中显示应用
- 刷新应用列表

收藏、手动分类和拖拽后的应用顺序使用 `UserDefaults` 保存在本机。

## 两种界面

- 日常启动器:应用启动或点击 Dock 图标时显示浮动搜索面板。
- 应用管理:点击浮动面板底部的"应用管理",或按 `Command + ,` 打开原有磁贴界面。

浮动面板隐藏后应用仍会留在后台运行。需要彻底退出时按 `Command + Q`。

## 运行

在仓库根目录执行:

```bash
open NegiPad.xcodeproj
```

在 Xcode 顶部选择 `NegiPad` Scheme 和 `My Mac`,然后按 `Command + R`。

也可以通过终端构建正式的 `.app`:

```bash
xcodebuild -project NegiPad.xcodeproj \
  -scheme NegiPad \
  -configuration Debug \
  -derivedDataPath .xcode-build \
  build
```

构建产物位于:

```bash
.xcode-build/Build/Products/Debug/NegiPad.app
```

## 后续适合增加

- 小、中、宽三种磁贴尺寸
- 应用隐藏和重复版本管理
- 拼音和用户关键词搜索
- 登录启动及后台监听应用安装变化
