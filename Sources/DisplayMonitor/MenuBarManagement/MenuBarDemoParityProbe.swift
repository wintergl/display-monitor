import AppKit
import CoreServices
import MenuBarVisibilityBridge
import OSLog

/// Explicit, isolated diagnostic. Reuses the DEMO's two fixed status items and
/// one selected helper target, without starting ToolSuiteShell or its scanner.
/// Normal application launches never enter this path.
@MainActor
final class MenuBarDemoParityProbe: NSObject, NSWindowDelegate {
    static let argument = "--menu-bar-demo-parity-probe"
    static var helperID: String {
        let isolated = "com.hanshuai.MenuBarBoundaryProbe20261022"
        return Bundle.main.object(forInfoDictionaryKey: "DisplayMonitorDiagnosticHelperID") as? String == isolated
            ? isolated : "com.hanshuai.MenuBarHideProbe"
    }
    enum EntryMode: Int, CaseIterable {
        case demo, demoHiddenActivity, product
        var title: String {
            switch self {
            case .demo: "DEMO 两入口（基线）"
            case .demoHiddenActivity: "DEMO 入口，活动项隐藏"
            case .product: "主工程入口与关闭的活动项"
            }
        }
    }
    static func requestedEntryMode(arguments: [String]) -> EntryMode {
        let prefix = "--menu-bar-demo-entry-mode="
        guard let value = arguments.first(where: { $0.hasPrefix(prefix) }),
              let number = Int(value.dropFirst(prefix.count)),
              let mode = EntryMode(rawValue: number) else { return .demo }
        return mode
    }
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "DemoParityProbe")
    private var window: NSWindow?
    private var items: [NSStatusItem] = []
    private var entryMode: EntryMode = .demo
    private var productMain: MainMenuBarStatusItemController?
    private var productActivity: StatusItemController?
    private var assertion: DMMenuBarVisibilityAssertion?
    private var token: UUID?
    private var launchedHelper: NSRunningApplication?
    private let message = NSTextField(wrappingLabelWithString:
        "只对照 DEMO 的固定入口和隐藏调用，不启动主工程整理逻辑。先启动隔离 Probe，再请求隐藏它。不会隐藏其他应用或移动图标。")
    private let hideButton = NSButton(title: "隐藏测试图标（15 秒）", target: nil, action: nil)

    static func plan(runningIDs: Set<String>, controllerID: String = AppConstants.bundleIdentifier) throws -> MenuBarCollapsePlan {
        try MenuBarCollapsePlan(runningBundleIdentifiers: runningIDs,
            targetBundleIdentifiers: [helperID],
            protectionPolicy: .init(ownBundleIdentifier: controllerID))
    }

    func start(entryMode: EntryMode = .demo) {
        self.entryMode = entryMode
        NSApp.setActivationPolicy(.regular)
        installEntries()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 270),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "DEMO 源码最小对照 · Display Monitor 身份"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let launch = NSButton(title: "启动测试图标", target: self, action: #selector(launchProbe))
        hideButton.target = self
        hideButton.action = #selector(toggle)
        hideButton.isEnabled = false
        let restore = NSButton(title: "立即恢复", target: self, action: #selector(restore))
        let quit = NSButton(title: "退出并恢复", target: self, action: #selector(quit))
        let buttons = NSStackView(views: [launch, hideButton, restore, quit])
        buttons.spacing = 10
        let modes = NSPopUpButton(frame: .zero, pullsDown: false)
        modes.addItems(withTitles: EntryMode.allCases.map(\.title))
        modes.selectItem(at: entryMode.rawValue)
        modes.isEnabled = !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--menu-bar-demo-entry-mode=") })
        modes.target = self
        modes.action = #selector(selectEntryMode(_:))
        let content = NSStackView(views: [message, modes, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 24
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(content)
        if let root = panel.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                content.centerYAnchor.constraint(equalTo: root.centerYAnchor)
            ])
        }
        window = panel
        panel.center()
        showWindow()
        message.stringValue = "当前对照：\(entryMode.title)。只隐藏本页临时启动的测试图标，不影响你的其他应用。"
        logger.notice("demoParity.started shellStarted=false mode=\(self.entryMode.rawValue, privacy: .public)")
    }

    private func installEntries() {
        if entryMode == .product {
            let main = MainMenuBarStatusItemController()
            main.onRevealNativeMenuBar = { [weak self] in self?.toggle() }
            main.onContextMenuRequested = { [weak self] _ in self?.showWindow() }
            main.start(symbolName: "display.2", title: AppConstants.appName,
                accessibilityIdentifier: MenuBarManagementCoordinator.anchorAccessibilityIdentifier)
            productMain = main
            let activity = StatusItemController()
            activity.start(onToggleMonitor: {}, onOpenConsole: {}, onCaptureRegion: {}, onRestoreShelf: {})
            productActivity = activity
            return
        }
        for (suffix, symbol, label, action) in [
            ("anchor", "rectangle.split.1x2", "Display Monitor 对照入口", #selector(toggle)),
            ("activity", "waveform.path.ecg", "Display Monitor 对照活动项", #selector(showWindow))
        ] {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = NSStatusItem.AutosaveName("\(AppConstants.bundleIdentifier).demoParity.\(suffix)")
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.button?.setAccessibilityLabel(label)
            item.button?.setAccessibilityIdentifier("\(AppConstants.bundleIdentifier).demoParity.\(suffix)")
            item.button?.target = self
            item.button?.action = action
            items.append(item)
        }
        if entryMode == .demoHiddenActivity { items.last?.isVisible = false }
    }

    @objc private func selectEntryMode(_ sender: NSPopUpButton) {
        guard let mode = EntryMode(rawValue: sender.indexOfSelectedItem) else { return }
        restore()
        removeEntries()
        entryMode = mode
        installEntries()
        message.stringValue = "已切换：\(mode.title)。没有发送隐藏请求；可先确认入口可见，再点隐藏 Probe。"
        logger.notice("demoParity.mode mode=\(mode.rawValue, privacy: .public)")
    }

    private func removeEntries() {
        items.forEach { NSStatusBar.system.removeStatusItem($0) }
        items.removeAll()
        productMain?.stop()
        productMain = nil
        productActivity?.stop()
        productActivity = nil
    }

    @objc private func launchProbe() {
        guard launchedHelper == nil else { return }
        let standalone = ProcessInfo.processInfo.arguments.contains("--menu-bar-demo-standalone-helper")
        let url = Self.helperURL(applicationURL: Bundle.main.bundleURL, standalone: standalone)
        guard Bundle(url: url)?.bundleIdentifier == Self.helperID,
              NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperID).isEmpty else {
            message.stringValue = "隔离 Probe 不存在或已有实例；未启动，也未隐藏。"
            return
        }
        guard LSRegisterURL(url as CFURL, true) == noErr else {
            message.stringValue = "隔离 Probe 登记失败；未隐藏。"
            return
        }
        Task { @MainActor [weak self] in
            do {
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                guard let self, self.window != nil else { _ = app.terminate(); return }
                guard app.bundleURL?.standardizedFileURL == url.standardizedFileURL else {
                    self.message.stringValue = "系统返回的测试图标位置与请求不一致；未隐藏，也未结束该进程。"
                    return
                }
                self.launchedHelper = app
                self.hideButton.isEnabled = true
                self.message.stringValue = "测试图标已启动。点“隐藏测试图标”后，请看分界方框入口是否还在；15 秒后会恢复。"
            } catch { self?.message.stringValue = "启动失败：\(error.localizedDescription)" }
        }
    }

    static func helperURL(applicationURL: URL, standalone: Bool) -> URL {
        standalone
            ? applicationURL.deletingLastPathComponent().appendingPathComponent("MenuBarHideProbe.app")
            : applicationURL.appendingPathComponent("Contents/Helpers/MenuBarHideProbe.app")
    }

    @objc private func toggle() {
        if token != nil { restore(); return }
        guard let helper = launchedHelper, !helper.isTerminated,
              DMMenuBarVisibility.supportsHiding() else { return }
        do {
            let ids = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
            let controllerID = Bundle.main.bundleIdentifier ?? AppConstants.bundleIdentifier
            let plan = try Self.plan(runningIDs: ids, controllerID: controllerID)
            let request = UUID()
            token = request
            // Independent bounded recovery, armed BEFORE activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard self?.token == request else { return }
                self?.restore()
            }
            message.stringValue = "已请求只隐藏测试图标；15 秒后自动恢复。窗口和“立即恢复”按钮始终保留。"
            assertion = DMMenuBarVisibility.begin(allowing: plan.allowedBundleIdentifiers,
                systemItems: plan.allowedSystemItems.map { NSNumber(value: $0) }) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.token == request else { return }
                    if let error { self.restore(); self.message.stringValue = error.localizedDescription }
                    else {
                        self.message.stringValue = "系统已确认请求（不是视觉验收）。请看分界方框入口是否仍在。15 秒后恢复。"
                        self.logger.notice("demoParity.nativeAcknowledged visualVerified=false")
                    }
                }
            }
            if assertion == nil { restore() }
            logger.notice("demoParity.begin targets=1 mode=\(self.entryMode.rawValue, privacy: .public) ownAllowed=\(plan.allowedBundleIdentifiers.contains(controllerID), privacy: .public)")
        } catch { message.stringValue = error.localizedDescription }
    }

    @objc private func restore() {
        token = nil
        assertion?.invalidate()
        assertion = nil
        message.stringValue = "隐藏请求已释放。可以再次对照，或退出并恢复。"
        logger.notice("demoParity.restored")
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { quit(); return false }
    func shutdown() {
        restore()
        removeEntries()
        if let helper = launchedHelper, !helper.isTerminated { _ = helper.terminate() }
        launchedHelper = nil
        window?.orderOut(nil)
        window = nil
    }
}
