<p align="center">
  <img src="Resources/DisplayMonitor.icon.png" width="88" alt="Display Monitor app icon">
</p>
<h1 align="center">Display Monitor</h1>
<p align="center"><strong>A quieter menu bar. A quicker way to capture.</strong></p>
<p align="center">Collapse menu bar clutter, take screenshots, record a region, and keep another display in view.<br>Native Swift + AppKit + SwiftUI. No third-party package dependencies.</p>
<p align="center">
  <a href="https://github.com/wintergl/display-monitor/releases/latest"><img src="https://img.shields.io/github/v/release/wintergl/display-monitor?color=3984ff" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-22a67a" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-macOS-222222" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
</p>
<p align="center"><a href="https://github.com/wintergl/display-monitor/releases/latest">Download for Apple Silicon</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="docs/BUILDING.md">Build from source</a> · <a href="docs/ARCHITECTURE.md">Explore the code</a></p>

![Display Monitor feature overview](docs/assets/overview.svg)
<sub>Feature illustration; not a screenshot of the app.</sub>

## Less clutter, fewer interruptions

Your menu bar should leave room for what you use. Your capture tools should be there when you need them. Display Monitor puts both in one native macOS utility, with an extra trick: a floating view of your other display.

| Feature | What you can do |
| --- | --- |
| **Collapse the menu bar** | Keep icons on the left of the Display Monitor divider tucked away. Click to reveal them, then collapse again. Optional automatic re-collapse waits while you use a menu. |
| **Arrange your icons** | Prepare an ordering draft, then explicitly apply it. Keep frequently used items in the visible area. |
| **Capture and annotate** | Select a region, window, or screen; use a timer or repeat the last region. Copy, save, edit, or pin the result from the floating capture tools. |
| **Capture a long page** | Scroll through a selected region to stitch a long screenshot, with manual controls and seam review. |
| **Record a region** | Select an area, record to MP4, and stop from the recording controls. Playback and file actions stay close to the result. |
| **Watch another display** | Keep an extended display in a floating preview, adjust size and frame rate, and optionally use modifier-held pointer control. |

**Menu bar collapse and ordering require macOS 27+, runtime support, and launching from `/Applications`.** The app's deployment target is macOS 13; capture APIs vary by OS. The downloadable build is Apple Silicon. The interface is currently primarily in Chinese. See [compatibility and limitations](docs/COMPATIBILITY.md).

## Get started

1. Download the latest **DMG** from [Releases](https://github.com/wintergl/display-monitor/releases/latest).
2. Move **Display Monitor.app** into **Applications** and open it.
3. Open the menu bar item's context menu to reach tools and settings.
4. Grant **Screen Recording** for capture and preview. Grant **Accessibility** when using menu bar controls or direct pointer control.
5. In menu bar settings, review the visible/collapsed groups before enabling persistent collapse.

The published Apple Silicon app is Developer ID signed and notarized. Source builds can use ad hoc signing; see [build instructions](docs/BUILDING.md). The release notes distinguish the prebuilt app from source packaging changes.

### Everyday shortcuts

| Shortcut | Action |
| --- | --- |
| `⌥ A` | Select a capture region; choose screenshot, scroll capture, or recording in the workspace |
| `⌥ F1` | Toggle display preview |
| `⌥ ⌘ P` | Pause/resume preview |
| `⌥ ⌘ →` / `⌥ ⌘ ←` | Move the pointer to the target/main display |

Shortcuts can be changed in Settings. Capture results support copy/save actions without opening a full editor first.

## For builders

```sh
git clone https://github.com/wintergl/display-monitor.git
cd display-monitor
./script/build_and_run.sh --release-build-only
# Output: dist/Display Monitor.app
swift test
```

Use an Apple Silicon Mac with Xcode 26+ and the macOS 26 SDK or newer. The initial public source was checked with Swift 6.4. The build script does not install over an existing app or stop a running one. See [BUILDING.md](docs/BUILDING.md) for signing, launch, and permission details.

The code separates deterministic policies from native UI and capture:

- **DisplayMonitorCore** — capture coordination, artifact lifecycle, geometry, input leases, and safety policies.
- **DisplayMonitor** — AppKit/SwiftUI interfaces, ScreenCaptureKit capture, AVFoundation writing, and menu bar coordination.
- **MenuBarVisibilityBridge** — a small Objective-C boundary around runtime-resolved menu bar visibility APIs.

Useful starting points: [menu bar management](Sources/DisplayMonitor/MenuBarManagement), [screenshot rendering](Sources/DisplayMonitor/App/ScreenshotDocumentRenderer.swift), [recording](Sources/DisplayMonitor/App/RecordingSessionController.swift), and [tests](Tests/DisplayMonitorCoreTests). [Architecture notes →](docs/ARCHITECTURE.md)

## Know before using

Menu bar hiding uses a **private macOS framework**, resolved at runtime. It can change with system updates and is unsuitable for an App Store distribution without replacing that implementation. Clicking the system clock can temporarily reveal hidden icons. DRM/protected content may appear black. Recording audio is not currently implemented. Monitor + recording concurrency is conservatively gated; stop Monitor if a combination is unavailable. GIF export is experimental and disabled by default.

The source contains no analytics SDK, account requirement, or cloud upload client. Captures and settings are stored locally; exports and clipboard actions happen when you choose them. Screen recording and accessibility permissions still grant access to sensitive on-screen content. [Privacy details →](docs/PRIVACY.md)

## Contribute, reuse, and credit

Bug reports with clear reproduction steps, compatibility reports, and English localization contributions are welcome. Please remove personal content from screenshots and logs before sharing them. Read [CONTRIBUTING.md](CONTRIBUTING.md).

If you build on this project, a link back to **[wintergl/display-monitor](https://github.com/wintergl/display-monitor)** helps others find the original work. GitHub's **Cite this repository** entry is backed by [CITATION.cff](CITATION.cff). Starring the repo also helps people discover it.

[MIT licensed](LICENSE). Keep the copyright and license notice when redistributing the code.
