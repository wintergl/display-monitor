# Code map

Display Monitor is a SwiftPM macOS GUI application with three main modules and no external package dependencies.

| Module | Responsibility | Good entry points |
| --- | --- | --- |
| DisplayMonitorCore | Pure policies, artifact manifests, geometry, input ownership, and capture concurrency decisions | `CaptureExtensions.swift`, `ArtifactStore.swift`, `InputLease.swift` |
| DisplayMonitor | AppKit/SwiftUI, permissions, ScreenCaptureKit, AVFoundation, and desktop coordination | `App/ToolSuiteShell.swift`, `MenuBarManagement/`, `Platform/` |
| MenuBarVisibilityBridge | Runtime checks, Objective-C exception boundary, and main-queue delivery for native hiding | `MenuBarVisibilityBridge.m` |

## Menu bar

`MenuBarManagementCoordinator` reads the real menu bar, maintains a draft, and applies ordering only on explicit action. A divider separates the collapsed group from visible icons. Discovery and physical topology checks guard changes; cancellation releases input ownership. Hiding requests have an owner that can invalidate them. The native callback crosses onto the main queue before entering Swift's main-actor code.

`MenuBarHidingLaunchPolicy` requires `/Applications`. OS and runtime checks stay in the product; a successful build does not imply native hiding is supported.

## Capture and results

`ScreenshotWorkspaceController` provides selection. `ScreenshotDocumentRenderer` and raster source/queue components handle editing and export. Long captures have explicit follow, manual, seam-review, and finalize states. `RecordingSessionController` coordinates capture, deadlines, writing, and finalization; `RecordingWriter` produces MP4 through AVFoundation.

`ArtifactStore` manages local results. Input leases and capture resource coordination prevent competing operations from owning the same native resources. Monitor/capture concurrency is intentionally conservative until runtime-specific evidence permits it.

## Explore and reuse

The geometry, state machines, cancellation policies, and rendering tests are useful independent reading paths. `DisplayMonitorCore` is currently an internal package target, not a separately versioned public SDK. Integrators can copy/adapt code under MIT and should test their own native behavior and distribution constraints.

The public repository starts with a clean source snapshot. Personal desktop reports, message databases, screenshots, reverse-engineering workspaces, and private signing credentials are not distributed.
