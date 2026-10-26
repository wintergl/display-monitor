import AppKit
import DisplayMonitorCore

/// Builds the anchor status item's secondary-click menu from the live shell state.
///
/// The menu is intentionally rebuilt for every presentation: AppKit owns only the
/// imperative target/action edge, while `ToolSuiteShell` and `AppModel` remain the
/// source of truth for command availability and titles.
@MainActor
final class MainMenuBarContextMenuController: NSObject {
    private weak var shell: ToolSuiteShell?

    init(shell: ToolSuiteShell) {
        self.shell = shell
        super.init()
    }

    func show(relativeTo statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }
        let menu = makeMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4),
            in: button
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Display Monitor")
        guard let shell else { return menu }
        let model = shell.monitor

        menu.addItem(infoItem(
            "Monitor：\(model.desiredMonitorState.label) · \(model.monitorRuntimeState.label)"
        ))
        menu.addItem(infoItem(model.statusSummary))
        menu.addItem(.separator())

        menu.addItem(actionItem(
            actionTitle(
                model.desiredMonitorState == .on ? "关闭 Monitor" : "开启 Monitor",
                command: .toggleMonitor,
                model: model
            ),
            action: #selector(toggleMonitor)
        ))

        addCaptureAction(to: menu, shell: shell, model: model)
        menu.addItem(actionItem(
            "显示或隐藏截图浮窗",
            action: #selector(toggleArtifactShelf)
        ))

        if shell.pinnedScreenshotController.hasPinnedScreenshots {
            menu.addItem(actionItem("清理所有贴图", action: #selector(clearPinnedScreenshots)))
        }

        if model.desiredMonitorState == .on {
            addMonitorRuntimeActions(to: menu, shell: shell, model: model)
        }

        if model.permissionState != .granted || model.inputControlPermission != .granted {
            menu.addItem(permissionRepairItem(shell: shell, model: model))
        }

        if model.lastError != nil {
            menu.addItem(actionItem("重试采集", action: #selector(retryCapture)))
        }

        menu.addItem(.separator())

        let management = shell.menuBarManagement
        let collapseItem = actionItem(
            menuBarCollapseTitle(management),
            action: #selector(toggleMenuBarCollapse)
        )
        collapseItem.isEnabled = management.isCollapseAvailable
            || management.isPreparingCollapse
            || management.isCollapsed
        menu.addItem(collapseItem)

        menu.addItem(actionItem("菜单栏整理…", action: #selector(openMenuBarSettings)))
        menu.addItem(actionItem("设置…", action: #selector(openSettings)))
        menu.addItem(actionItem("关于 Display Monitor", action: #selector(showAbout)))

        menu.addItem(.separator())
        let quitItem = actionItem(
            "退出 Display Monitor",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        return menu
    }

    private func addCaptureAction(
        to menu: NSMenu,
        shell: ToolSuiteShell,
        model: AppModel
    ) {
        if shell.recordingSessionController.isRecording {
            menu.addItem(actionItem("停止区域录屏", action: #selector(stopRecording)))
            return
        }
        if shell.recordingSessionController.isBusy {
            menu.addItem(infoItem("区域录屏收尾中…"))
            return
        }
        if shell.scrollCaptureSessionController.isCapturing {
            menu.addItem(actionItem("结束滚动截图", action: #selector(stopScrollCapture)))
            return
        }
        if shell.scrollCaptureSessionController.isBusy {
            menu.addItem(infoItem("滚动截图准备或收尾中…"))
            return
        }

        let captureItem = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu(title: "截图")
        captureMenu.addItem(actionItem(
            actionTitle("区域截图 / 更多", command: .captureRegion, model: model),
            action: #selector(captureRegion)
        ))
        captureMenu.addItem(actionItem("窗口截图", action: #selector(captureWindow)))
        captureMenu.addItem(actionItem(
            "全屏截图（鼠标所在显示器）",
            action: #selector(captureFullScreen)
        ))
        captureMenu.addItem(actionItem(
            "定时截图（\(model.screenshotTimerDelaySeconds) 秒）",
            action: #selector(captureTimedRegion)
        ))
        captureMenu.addItem(.separator())
        let repeatItem = actionItem(
            "重复上一次截图区域",
            action: #selector(repeatLastScreenshot)
        )
        repeatItem.isEnabled = model.lastScreenshotSelection != nil
        captureMenu.addItem(repeatItem)
        captureItem.submenu = captureMenu
        menu.addItem(captureItem)
    }

    private func addMonitorRuntimeActions(
        to menu: NSMenu,
        shell: ToolSuiteShell,
        model: AppModel
    ) {
        let pinItem = actionItem("监控窗口置顶", action: #selector(togglePreviewPinning))
        pinItem.state = model.previewIsPinned ? .on : .off
        menu.addItem(pinItem)

        switch model.snapshot.previewVisibility {
        case .shown:
            menu.addItem(actionItem("折叠为悬浮图标", action: #selector(collapsePreview)))
        case .collapsed:
            menu.addItem(actionItem("展开预览窗口", action: #selector(expandPreview)))
        case .hidden:
            break
        }

        if model.snapshot.previewVisibility != .hidden {
            menu.addItem(actionItem("隐藏预览", action: #selector(hidePreview)))
        }

        let pauseTitle = model.capturePhase == .paused ? "继续采集" : "暂停采集"
        menu.addItem(actionItem(
            actionTitle(pauseTitle, command: .togglePause, model: model),
            action: #selector(togglePause)
        ))

        let pointerItem = NSMenuItem(title: "鼠标位置", action: nil, keyEquivalent: "")
        let pointerMenu = NSMenu(title: "鼠标位置")
        let moveToTarget = actionItem(
            actionTitle("移到目标屏", command: .moveToTarget, model: model),
            action: #selector(movePointerToTargetDisplay)
        )
        moveToTarget.isEnabled = canMoveToTarget(shell: shell, model: model)
        pointerMenu.addItem(moveToTarget)

        let moveToMain = actionItem(
            actionTitle("移回主屏", command: .moveToMain, model: model),
            action: #selector(movePointerToMainDisplay)
        )
        moveToMain.isEnabled = !shell.inputModeCoordinator.directPointerSuspended
        pointerMenu.addItem(moveToMain)
        pointerItem.submenu = pointerMenu
        menu.addItem(pointerItem)
    }

    private func permissionRepairItem(shell: ToolSuiteShell, model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "需要权限", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "需要权限")
        submenu.addItem(infoItem("屏幕录制：\(shell.permissionCenter.screenRecordingLabel)"))
        submenu.addItem(infoItem("辅助功能：\(shell.permissionCenter.accessibilityLabel)"))
        submenu.addItem(.separator())

        if model.permissionState != .granted {
            submenu.addItem(actionItem(
                "打开屏幕录制设置…",
                action: #selector(openScreenRecordingSettings)
            ))
        }
        if model.inputControlPermission != .granted {
            submenu.addItem(actionItem(
                "打开辅助功能设置…",
                action: #selector(openAccessibilitySettings)
            ))
        }
        submenu.addItem(actionItem("重新检测权限", action: #selector(refreshPermissions)))
        item.submenu = submenu
        return item
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionTitle(
        _ title: String,
        command: ToolSuiteCommand,
        model: AppModel
    ) -> String {
        guard let registration = model.shortcutRegistrations.first(where: {
            $0.shortcut == command
        }), registration.isRegistered else {
            return title
        }
        return "\(title)（\(registration.binding.keyEquivalent)）"
    }

    private func menuBarCollapseTitle(_ management: MenuBarManagementCoordinator) -> String {
        if !management.isEnabled {
            return "启用菜单栏整理…"
        }
        if management.isPreparingCollapse || management.isCollapsed {
            return "展开左侧图标"
        }
        return "收起左侧图标"
    }

    private func canMoveToTarget(shell: ToolSuiteShell, model: AppModel) -> Bool {
        guard !shell.inputModeCoordinator.directPointerSuspended else { return false }
        if case .online = model.targetState {
            return true
        }
        return false
    }

    @objc private func toggleMonitor() {
        Task { @MainActor [weak self] in
            await self?.shell?.toggleMonitor()
        }
    }

    @objc private func captureRegion() { shell?.captureRegion() }
    @objc private func captureWindow() { shell?.captureWindow() }
    @objc private func captureFullScreen() { shell?.captureFullScreen() }
    @objc private func captureTimedRegion() { shell?.captureTimedRegion() }
    @objc private func repeatLastScreenshot() { shell?.repeatLastScreenshot() }
    @objc private func stopScrollCapture() { shell?.stopScrollCapture() }
    @objc private func stopRecording() { shell?.stopRecording() }
    @objc private func toggleArtifactShelf() { shell?.toggleArtifactShelf() }
    @objc private func clearPinnedScreenshots() { shell?.clearPinnedScreenshots() }
    @objc private func expandPreview() { shell?.expandPreview() }
    @objc private func collapsePreview() { shell?.collapsePreview() }
    @objc private func hidePreview() { shell?.monitor.hidePreview() }

    @objc private func togglePreviewPinning() {
        guard let model = shell?.monitor else { return }
        model.setPreviewPinned(!model.previewIsPinned)
    }

    @objc private func togglePause() {
        Task { @MainActor [weak self] in
            await self?.shell?.togglePause()
        }
    }

    @objc private func movePointerToTargetDisplay() { shell?.movePointerToTargetDisplay() }
    @objc private func movePointerToMainDisplay() { shell?.movePointerToMainDisplay() }
    @objc private func openScreenRecordingSettings() { shell?.openScreenRecordingSettings() }
    @objc private func openAccessibilitySettings() { shell?.openAccessibilitySettings() }

    @objc private func refreshPermissions() {
        Task { @MainActor [weak self] in
            await self?.shell?.refreshPermissions()
        }
    }

    @objc private func retryCapture() {
        Task { @MainActor [weak self] in
            await self?.shell?.monitor.retryCapture()
        }
    }

    @objc private func toggleMenuBarCollapse() { shell?.toggleMenuBarCollapse() }
    @objc private func openMenuBarSettings() { shell?.openSettingsWindow(tab: .menuBar) }
    @objc private func openSettings() { shell?.openSettingsWindow() }
    @objc private func showAbout() { shell?.monitor.showAbout() }
    @objc private func quit() { shell?.quit() }
}
