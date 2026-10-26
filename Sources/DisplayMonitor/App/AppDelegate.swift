import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var shell: ToolSuiteShell?
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Lifecycle")
    private var startupTask: Task<Void, Never>?
    private var demoParityProbe: MenuBarDemoParityProbe?
    private var menuBarValidationTimer: Timer?
    private lazy var terminationCoordinator = ApplicationTerminationCoordinator(
        cleanup: { [weak self] in
            await self?.shell?.prepareForTermination(recordingBudgetSeconds: 5)
        },
        requestTermination: { NSApp.terminate(nil) },
        onCompletion: { [weak self] timedOut in
            guard let self else { return }
            self.shell?.finishTerminationCleanup()
            if timedOut {
                self.logger.error("lifecycle.termination.deadlineExceeded")
            } else {
                self.logger.notice("lifecycle.termination.cleanupCompleted")
            }
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains(MenuBarDemoParityProbe.argument) {
            let probe = MenuBarDemoParityProbe()
            demoParityProbe = probe
            probe.start(entryMode: MenuBarDemoParityProbe.requestedEntryMode(
                arguments: ProcessInfo.processInfo.arguments))
            return
        }
        let demoParity = Bundle.main.object(forInfoDictionaryKey: "DisplayMonitorDemoApplicationParity") as? Bool == true
        NSApp.setActivationPolicy(Self.activationPolicy(demoParity: demoParity))
        logger.info("lifecycle.activationPolicy demoParity=\(demoParity, privacy: .public)")
        if ProcessInfo.processInfo.arguments.contains("--phase0-status-item-lifecycle") {
            StatusItemController.runPhase0StatusItemLifecycleProbe()
            return
        }
        guard let shell else {
            logger.error("lifecycle.startup.missingShell")
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        let shouldShowMenuBarSettings = arguments.contains("--show-menu-bar-settings")
        let shouldShowSettings = shouldShowMenuBarSettings || arguments.contains("--show-settings")
        // Explicit local acceptance only: a missing menu-bar entry must not
        // strand a test instance. Normal launches never schedule this timer.
        if arguments.contains("--menu-bar-validation-quit-after-180s") {
            let timer = Timer(timeInterval: 180, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.logger.notice("menuBar.validation.normalQuitDeadline")
                    NSApp.terminate(nil)
                }
            }
            menuBarValidationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        startupTask = Task { @MainActor in
            await shell.startIfNeeded()
            guard !Task.isCancelled else { return }
            if shouldShowSettings {
                shell.openSettingsWindow(tab: shouldShowMenuBarSettings ? .menuBar : nil)
            }
        }
    }

    static func activationPolicy(demoParity: Bool) -> NSApplication.ActivationPolicy {
        demoParity ? .regular : .accessory
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let demoParityProbe {
            demoParityProbe.shutdown()
            self.demoParityProbe = nil
            return .terminateNow
        }
        guard let shell else { return .terminateNow }
        if terminationCoordinator.state == .running {
            logger.notice("lifecycle.termination.requested")
            startupTask?.cancel()
            startupTask = nil
            shell.beginTermination()
        }
        return terminationCoordinator.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarValidationTimer?.invalidate()
        menuBarValidationTimer = nil
        shell?.finishTerminationCleanup()
        logger.notice("lifecycle.termination.completed")
    }

}
