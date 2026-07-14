# AppTileDemo

一个使用 SwiftUI 编写的原生 macOS App。它会读取本机已经安装的应用，并按照应用包中的分类信息展示为可启动的磁贴。

## 当前功能

- 扫描 `/Applications`、`~/Applications` 和 `/System/Applications`
- 自动读取真实应用名称、图标、版本和 Bundle ID
- 按类别显示应用磁贴
- 搜索应用、分类和 Bundle ID
- 点击磁贴启动应用
- 收藏应用
- 通过右键菜单手动修改分类
- 在 Finder 中显示应用
- 刷新应用列表

收藏和手动分类使用 `UserDefaults` 保存在本机。

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

- 拖动磁贴排序
- 小、中、宽三种磁贴尺寸
- 用户自定义分类
- 应用隐藏和重复版本管理
- 全局快捷键呼出窗口
- 拼音和用户关键词搜索
- 登录启动及后台监听应用安装变化
