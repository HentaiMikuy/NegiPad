<div align="right">

English | [简体中文](README.zh-CN.md)

</div>

# NegiPad (Scallion Launcher)

A native macOS app launcher written in SwiftUI: summon a centered floating panel with a global hotkey, search and launch apps installed on your machine, while keeping a Launchpad-style tile management interface.

## Current Features

- Shows a Raycast-like centered floating panel on launch, displaying apps in a compact icon grid
- Uses a compact icon grid close to the classic Launchpad, with drag-to-reorder support
- The launcher supports two browsing modes — vertical scrolling and horizontal paging — and you can configure `Shift + mouse wheel` or direct wheel paging
- Drag an app onto the center of another icon to create a folder; click a folder to edit its name directly and save
- Apps inside a folder can be dragged outside the panel back to the main grid; folders with fewer than two members dissolve automatically
- The floating panel hides automatically when it loses focus; pressing `Esc` also closes it
- The search box is auto-focused and supports arrow-key selection and Enter to launch
- Supports a customizable global hotkey to summon the launcher, defaulting to `Option + Space`, and detects hotkey conflicts
- Scans `/Applications`, `~/Applications`, and `/System/Applications`
- Watches app directories while running, refreshing automatically after apps are installed, deleted, or moved
- Automatically reads real app names, icons, versions, and Bundle IDs
- Keeps the full categorized tile management interface
- Searches apps, categories, and Bundle IDs
- Launches an app by clicking its tile
- Favorites apps
- Supports creating custom categories, choosing category icons and colors, and editing or deleting them via the context menu
- Manually change an app's category from its context menu
- Shows an app in Finder
- Refreshes the app list

Favorites, manual categories, and the app order after dragging are saved locally with `UserDefaults`.

## Two Interfaces

- Daily launcher: the floating search panel appears when the app launches or when you click the Dock icon.
- App management: click "App Management" at the bottom of the floating panel, or press `Command + ,` to open the original tile interface.

The app keeps running in the background after the floating panel hides. Press `Command + Q` to quit completely.

## Build & Run

From the repository root:

```bash
open NegiPad.xcodeproj
```

Select the `NegiPad` scheme and `My Mac` at the top of Xcode, then press `Command + R`.

You can also build the `.app` from the terminal:

```bash
xcodebuild -project NegiPad.xcodeproj \
  -scheme NegiPad \
  -configuration Debug \
  -derivedDataPath .xcode-build \
  build
```

The build product is located at:

```bash
.xcode-build/Build/Products/Debug/NegiPad.app
```

## Ideas for Future Additions

- Small, medium, and wide tile sizes
- App hiding and duplicate-version management
- Pinyin and user-keyword search
- Launch at login and background watching of app installation changes
