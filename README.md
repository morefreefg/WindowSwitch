<p align="center"><img src="Design/AppIcon.png" width="128" alt="WindowSwitch icon"></p>

# WindowSwitch

[![Build](https://github.com/morefreefg/WindowSwitch/actions/workflows/build.yml/badge.svg)](https://github.com/morefreefg/WindowSwitch/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native macOS window switcher with fast quick taps, static window previews, and display-aware focus. Built with Swift, AppKit, and SwiftUI. macOS 14 or later; Universal binaries for Apple silicon and Intel.

## Features

- Quick tap the configured shortcut to toggle between the two most recent eligible apps/windows on the screen under the mouse. Hold to show the full list.
- One recent window per app by default. Disable this in General to list every window; the current-app shortcut always keeps all of that app's windows.
- Shared recent-window ordering for quick switching, the full list, and Dock focus, including focus changes outside WindowSwitch.
- Filter by display, Space, hidden/minimized state, application, and window title.
- High quality previews use the display's pixel scale. Static caches are reused; previews do not run as live video streams.
- Optional idle-time background preloading, enabled with a 30-second interval by default, with a configurable interval and small low-priority thumbnails. Busy, hot, or low-power systems pause or slow this work.
- Dock clicks focus an eligible window on the clicked display, preserving windows on other displays.
- Configurable fade durations, native settings, menus, and Liquid Glass on supported macOS versions.
- Window close, minimize, fullscreen, layout, and Space actions; optional native app-switcher window previews.
- Native Sparkle updates, with RC support; no analytics, crash uploads, or account requirement.

## Install

Download the Universal DMG from [Releases](https://github.com/morefreefg/WindowSwitch/releases), open it, and drag WindowSwitch to Applications.

The first-run wizard checks permissions before enabling window switching or Dock focus. Accessibility is needed to list/control windows; Screen Recording is needed only when previews are enabled. Permission requests happen on the Grant buttons, already-granted items are skipped, and audio is not recorded. Quit other window-switching utilities before enabling overlapping shortcuts.

The initial release uses an **ad-hoc signature and is not Apple-notarized**. macOS may require explicit approval in System Settings → Privacy & Security. This is not a Developer ID signature. See [release signing](Docs/Releasing.md) for the optional Developer ID/notarization setup.

Defaults: Command+Tab for the window list, Option+` for the current application's windows. Quick tap is enabled, with a 300 ms hold threshold. Shortcuts and display filters are configurable.

## Build

Install Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then:

```sh
brew install xcodegen
./Scripts/test.sh
./Scripts/build.sh
./Scripts/package.sh
```

Build products use a temporary directory; `dist/` contains the Universal DMG, ZIP, checksums, and build manifest. Builds are ad-hoc signed unless `WINDOWSWITCH_SIGNING_IDENTITY` is explicitly supplied. No local certificate is selected or exported automatically.

## Serverless updates

GitHub Releases stores the Universal update archives; GitHub Pages serves an Ed25519-signed appcast. Sparkle verifies the feed and each update before installation. No update server needs to be hosted separately.

Automatic checks run every six hours by default. RC releases are included by default, alongside stable releases; both preferences are configurable in Updates. Automatic download/install is opt-in, with a native Check for Updates action available from the menu bar and settings. Releases marked RC are published as GitHub pre-releases.

The first working release with this updater is 0.2.0-rc.2. Earlier builds must be upgraded manually once. Ad-hoc application signing does not provide the same macOS permission identity stability as a Developer ID certificate; the separate Ed25519 update signature verifies authenticity but does not replace Apple notarization.

Settings use six compact native tabs with no scrolling. New installs and Restore Defaults use `Sources/App/Resources/DefaultSettings.plist`, containing functional/appearance settings only. The defaults select the mouse display, exclude other displays/Spaces, use High previews and 100 ms fades, and enable idle-time prefetching every 30 seconds.

## Keyboard actions inside the list

| Input | Action |
| --- | --- |
| Tab / Shift+Tab | Next / previous |
| Arrow keys / H J K L | Navigate |
| Enter / Escape | Confirm / cancel |
| W / Delete | Close selected window |
| M / F / C | Minimize / fullscreen / center |
| Shift+arrows | Window layouts |
| Space | Bring window to the current Space |
| N / T | New window / tab in the selected app |
| R / P | Recent documents / settings |
| / | Search the list |

## Privacy and compatibility

Preferences and thumbnail caches stay on the Mac; thumbnails are held in memory. Recent documents and browser shortcuts are read locally only when their corresponding features are used. System permission prompts remain under macOS control.

Some window focus, Space, and drawing operations depend on private macOS interfaces. Symbols are checked at runtime; OS updates may affect those features. Headless CI cannot validate cross-app Accessibility or multi-display input behavior. See [architecture and validation](Docs/Architecture.md).

## 中文说明

原生 macOS 窗口切换工具。短按切换鼠标所在屏幕最近两个候选项，长按显示列表；默认每个应用只显示最近窗口。General 可切回全部窗口。High 按屏幕像素生成缩略图；后台预加载默认开启，间隔 30 秒，开启后仅在空闲且低负载时低优先级执行。Dock 点击只聚焦当前屏幕窗口，不修改系统 Dock 偏好。

首次使用请在设置中完成辅助功能和屏幕录制授权；已授权的项目不会重复请求。应用不录制音频，通过 GitHub 自动检查更新，不包含统计上报。

## License

MIT. Third-party copyright and license notices are retained in [ThirdPartyNotices](Docs/ThirdPartyNotices.md) and the vendored package.
