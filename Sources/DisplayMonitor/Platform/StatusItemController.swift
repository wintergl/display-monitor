import AppKit
import DisplayMonitorCore
import OSLog

enum StatusItemMode: String, CaseIterable, Sendable {
    case dualEntry
    case singleStatusItem

    var label: String {
        switch self {
        case .dualEntry:
            return "双入口"
        case .singleStatusItem:
            return "单状态项 fallback"
        }
    }
}

@MainActor
final class StatusItemController: NSObject, ObservableObject {
    @Published private(set) var mode: StatusItemMode = .singleStatusItem
    @Published private(set) var isActivityVisible = false

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "StatusItem")
    private var activityItem: NSStatusItem?
    private var activityStatusMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var onToggleMonitor: (() -> Void)?
    private var onOpenConsole: (() -> Void)?
    private var onCaptureRegion: (() -> Void)?
    private var onRestoreShelf: (() -> Void)?

    private var desiredState: MonitorDesiredState = .off
    private var runtimeState: MonitorRuntimeState = .idle
    private var shelfState: ShelfState = .safeVisibility(.shelfNoGo)
    private var lastRenderedActivityVisibility: Bool?

    func start(
        onToggleMonitor: @escaping () -> Void,
        onOpenConsole: @escaping () -> Void,
        onCaptureRegion: @escaping () -> Void,
        onRestoreShelf: @escaping () -> Void
    ) {
        guard activityItem == nil else {
            return
        }
        self.onToggleMonitor = onToggleMonitor
        self.onOpenConsole = onOpenConsole
        self.onCaptureRegion = onCaptureRegion
        self.onRestoreShelf = onRestoreShelf

        let candidate = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard candidate.button != nil else {
            mode = .singleStatusItem
            logger.error("activity.create.failed fallback=singleStatusItem")
            return
        }

        candidate.button?.toolTip = "Display Monitor Activity"
        candidate.menu = makeMenu()
        activityItem = candidate
        mode = .dualEntry
        logger.info("activity.create.success mode=dualEntry")
        render()
    }

    func update(
        desiredState: MonitorDesiredState,
        runtimeState: MonitorRuntimeState,
        shelfState: ShelfState
    ) {
        self.desiredState = desiredState
        self.runtimeState = runtimeState
        self.shelfState = shelfState
        render()
    }

    func stop() {
        if let activityItem {
            NSStatusBar.system.removeStatusItem(activityItem)
        }
        activityItem = nil
        activityStatusMenuItem = nil
        toggleMenuItem = nil
        isActivityVisible = false
        lastRenderedActivityVisibility = nil
        mode = .singleStatusItem
        logger.info("activity.destroy")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Monitor Activity")
        let statusItem = NSMenuItem(title: "Monitor：IDLE", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        activityStatusMenuItem = statusItem

        let toggle = NSMenuItem(
            title: "开启 Monitor",
            action: #selector(toggleMonitorFromMenu),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleMenuItem = toggle

        let console = NSMenuItem(
            title: "打开统一控制台",
            action: #selector(openConsoleFromMenu),
            keyEquivalent: ""
        )
        console.target = self
        menu.addItem(console)

        let capture = NSMenuItem(
            title: "框选截图",
            action: #selector(captureRegionFromMenu),
            keyEquivalent: ""
        )
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())
        let restore = NSMenuItem(
            title: "Shelf 恢复入口",
            action: #selector(restoreShelfFromMenu),
            keyEquivalent: ""
        )
        restore.target = self
        menu.addItem(restore)
        return menu
    }

    private func render() {
        guard let activityItem else {
            isActivityVisible = false
            return
        }

        let shouldBeVisible = desiredState == .on || runtimeState.keepsActivityEntryVisible
        activityItem.isVisible = shouldBeVisible
        isActivityVisible = shouldBeVisible
        if lastRenderedActivityVisibility != shouldBeVisible {
            logger.info(
                "activity.visibility visible=\(shouldBeVisible, privacy: .public) desired=\(self.desiredState.label, privacy: .public) runtime=\(self.runtimeState.label, privacy: .public)"
            )
            lastRenderedActivityVisibility = shouldBeVisible
        }
        activityStatusMenuItem?.title = "Monitor：\(runtimeState.label)"
        toggleMenuItem?.title = desiredState == .on ? "关闭 Monitor" : "开启 Monitor"

        let symbolName: String
        switch runtimeState {
        case .failed:
            symbolName = "exclamationmark.triangle"
        case .paused:
            symbolName = "pause.rectangle"
        case .starting, .running:
            symbolName = "display.and.arrow.down"
        case .suspended:
            symbolName = "display.trianglebadge.exclamationmark"
        case .stopping:
            symbolName = "stop.circle"
        case .idle:
            symbolName = "display"
        }
        activityItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Monitor \(runtimeState.label)"
        )
        activityItem.button?.title = shouldBeVisible ? "Monitor" : ""
        activityItem.button?.toolTip = "Monitor：\(runtimeState.label)；Shelf：\(shelfState.label)"
    }

    @objc private func toggleMonitorFromMenu() {
        onToggleMonitor?()
    }

    @objc private func openConsoleFromMenu() {
        onOpenConsole?()
    }

    @objc private func captureRegionFromMenu() {
        onCaptureRegion?()
    }

    @objc private func restoreShelfFromMenu() {
        onRestoreShelf?()
    }

    static func runPhase0StatusItemLifecycleProbe() {
        let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Phase0")
        // NSStatusItem visibility is settled by the main run loop after app launch.
        // Deferring the probe avoids treating that startup window as a lifecycle failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let statusBar = NSStatusBar.system
            let anchor = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            let activity = statusBar.statusItem(withLength: NSStatusItem.variableLength)

            anchor.button?.title = "Phase0 Anchor"
            activity.button?.title = "Phase0 Activity"
            anchor.menu = NSMenu(title: "ToolSuite Anchor")
            activity.menu = NSMenu(title: "Monitor Activity")

            let initialIndependent = anchor.isVisible && activity.isVisible &&
                anchor.button?.title == "Phase0 Anchor" &&
                activity.button?.title == "Phase0 Activity" &&
                anchor.menu?.title == "ToolSuite Anchor" &&
                activity.menu?.title == "Monitor Activity"

            activity.isVisible = false
            let anchorSurvivesActivityHide = anchor.isVisible && !activity.isVisible
            activity.isVisible = true
            let activityRestores = activity.isVisible
            statusBar.removeStatusItem(activity)
            let anchorSurvivesActivityDestroy = anchor.isVisible
            statusBar.removeStatusItem(anchor)

            let passed = initialIndependent && anchorSurvivesActivityHide &&
                activityRestores && anchorSurvivesActivityDestroy
            let result = passed ? "PASS" : "FAIL"
            logger.info("phase0.statusItem.probe=\(result, privacy: .public) independentLifecycle=\(initialIndependent, privacy: .public) anchorSurvivesHide=\(anchorSurvivesActivityHide, privacy: .public) activityRestores=\(activityRestores, privacy: .public) anchorSurvivesDestroy=\(anchorSurvivesActivityDestroy, privacy: .public)")
            print("STATUS_ITEM_PROBE=\(result)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }
}
