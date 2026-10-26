import DisplayMonitorCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: ToolSuiteShell
    @ObservedObject var menuBarManagement: MenuBarManagementCoordinator

    var body: some View {
        Text("Monitor：\(model.desiredMonitorState.label) · \(model.monitorRuntimeState.label)")
            .font(.caption.weight(.semibold))
        Text(model.statusSummary)
            .font(.caption)

        Divider()

        Button(monitorToggleTitle) {
            Task { await shell.toggleMonitor() }
        }

        captureAction

        Button("显示或隐藏截图浮窗") {
            shell.toggleArtifactShelf()
        }

        if shell.pinnedScreenshotController.hasPinnedScreenshots {
            Button("清理所有贴图") {
                shell.clearPinnedScreenshots()
            }
        }

        if model.desiredMonitorState == .on {
            monitorRuntimeActions
        }

        if model.permissionState != .granted || model.inputControlPermission != .granted {
            permissionRepairMenu
        }

        if model.lastError != nil {
            Button("重试采集") {
                Task { await model.retryCapture() }
            }
        }

        Divider()

        Button(menuBarCollapseTitle) {
            shell.toggleMenuBarCollapse()
        }
        .disabled(
            !menuBarManagement.isCollapseAvailable
                && !menuBarManagement.isPreparingCollapse
                && !menuBarManagement.isCollapsed
        )

        Button("菜单栏整理…") {
            shell.openSettingsWindow(tab: .menuBar)
        }

        settingsEntry

        Button("关于 Display Monitor") {
            model.showAbout()
        }

        Divider()

        Button("退出 Display Monitor") {
            shell.quit()
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var captureAction: some View {
        if shell.recordingSessionController.isRecording {
            Button("停止区域录屏") {
                shell.stopRecording()
            }
        } else if shell.recordingSessionController.isBusy {
            Button("区域录屏收尾中…") {}
                .disabled(true)
        } else if shell.scrollCaptureSessionController.isCapturing {
            Button("结束滚动截图") {
                shell.stopScrollCapture()
            }
        } else if shell.scrollCaptureSessionController.isBusy {
            Button("滚动截图准备或收尾中…") {}
                .disabled(true)
        } else {
            Menu("截图") {
                Button(actionTitle("区域截图 / 更多", for: .captureRegion)) {
                    shell.captureRegion()
                }
                Button("窗口截图") {
                    shell.captureWindow()
                }
                Button("全屏截图（鼠标所在显示器）") {
                    shell.captureFullScreen()
                }
                Button("定时截图（\(model.screenshotTimerDelaySeconds) 秒）") {
                    shell.captureTimedRegion()
                }
                Divider()
                Button("重复上一次截图区域") {
                    shell.repeatLastScreenshot()
                }
                .disabled(model.lastScreenshotSelection == nil)
            }
        }
    }

    @ViewBuilder
    private var monitorRuntimeActions: some View {
        if model.snapshot.previewVisibility == .shown {
            Button("折叠为悬浮图标") {
                shell.collapsePreview()
            }
        }

        if model.snapshot.previewVisibility == .collapsed {
            Button("展开预览窗口") {
                shell.expandPreview()
            }
        }

        if model.snapshot.previewVisibility != .hidden {
            Button("隐藏预览") {
                model.hidePreview()
            }
        }

        Button(actionTitle(
            model.capturePhase == .paused ? "继续采集" : "暂停采集",
            for: .togglePause
        )) {
            Task { await shell.togglePause() }
        }

        Menu("鼠标位置") {
            Button(actionTitle("移到目标屏", for: .moveToTarget)) {
                shell.movePointerToTargetDisplay()
            }
            .disabled(!canMoveToTarget)

            Button(actionTitle("移回主屏", for: .moveToMain)) {
                shell.movePointerToMainDisplay()
            }
            .disabled(shell.inputModeCoordinator.directPointerSuspended)
        }
    }

    private var permissionRepairMenu: some View {
        Menu("需要权限") {
            Text("屏幕录制：\(shell.permissionCenter.screenRecordingLabel)")
            Text("辅助功能：\(shell.permissionCenter.accessibilityLabel)")

            Divider()

            if model.permissionState != .granted {
                Button("打开屏幕录制设置…") {
                    shell.openScreenRecordingSettings()
                }
            }

            if model.inputControlPermission != .granted {
                Button("打开辅助功能设置…") {
                    shell.openAccessibilitySettings()
                }
            }

            Button("重新检测权限") {
                Task { await shell.refreshPermissions() }
            }
        }
    }

    private var settingsEntry: some View {
        Button("设置…") {
            shell.openSettingsWindow()
        }
    }

    private var menuBarCollapseTitle: String {
        if !menuBarManagement.isEnabled {
            return "启用菜单栏整理…"
        }
        if menuBarManagement.isPreparingCollapse || menuBarManagement.isCollapsed {
            return "展开左侧图标"
        }
        return "收起左侧图标"
    }

    private var canMoveToTarget: Bool {
        guard !shell.inputModeCoordinator.directPointerSuspended else {
            return false
        }
        if case .online = model.targetState {
            return true
        }
        return false
    }

    private var monitorToggleTitle: String {
        actionTitle(
            model.desiredMonitorState == .on ? "关闭 Monitor" : "开启 Monitor",
            for: .toggleMonitor
        )
    }

    private func actionTitle(_ title: String, for command: ToolSuiteCommand) -> String {
        guard let registration = model.shortcutRegistrations.first(where: { $0.shortcut == command }),
              registration.isRegistered else {
            return title
        }
        return "\(title)（\(registration.binding.keyEquivalent)）"
    }
}
