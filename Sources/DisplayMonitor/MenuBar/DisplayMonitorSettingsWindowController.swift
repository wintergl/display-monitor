import AppKit
import SwiftUI

@MainActor
final class DisplayMonitorSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private weak var shell: ToolSuiteShell?
    private let navigation = DisplayMonitorSettingsNavigation()

    init(shell: ToolSuiteShell) {
        self.shell = shell
        let hostingController = NSHostingController(
            rootView: DisplayMonitorSettingsView(shell: shell, navigation: navigation)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Display Monitor 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(DisplayMonitorSettingsLayout.preferredContentSize)
        window.contentMinSize = DisplayMonitorSettingsLayout.minimumContentSize
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        let autosaveName = "DisplayMonitor.SettingsWindow"
        let restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if restoredFrame {
            let restoredContentSize = window.contentRect(forFrameRect: window.frame).size
            if restoredContentSize.width < DisplayMonitorSettingsLayout.minimumContentSize.width
                || restoredContentSize.height < DisplayMonitorSettingsLayout.minimumContentSize.height {
                window.setContentSize(DisplayMonitorSettingsLayout.preferredContentSize)
            }
        } else {
            window.center()
        }

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(tab: DisplayMonitorSettingsTab? = nil) {
        if let tab {
            navigation.selectedTab = tab
        }
        AppWindowActivation.activate()
        showWindow(nil)
        constrainWindowToVisibleScreen()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancelShortcutRecording(in: notification.object as? NSWindow)
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelShortcutRecording(in: notification.object as? NSWindow)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        shell?.menuBarManagement.refreshPermissions()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        cancelShortcutRecording(in: notification.object as? NSWindow)
    }

    private func cancelShortcutRecording(in window: NSWindow?) {
        _ = window?.makeFirstResponder(nil)
        shell?.cancelShortcutRecording()
        shell?.cancelMenuBarOrdering(reason: "设置窗口已离开前台，正在停止排序并释放输入。")
    }

    private func constrainWindowToVisibleScreen() {
        guard let window,
              let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let constrainedFrame = window.constrainFrameRect(window.frame, to: targetScreen)
        guard constrainedFrame != window.frame else { return }
        window.setFrame(constrainedFrame, display: false)
    }
}
