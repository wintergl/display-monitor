import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import DisplayMonitorCore
import OSLog

enum CaptureTargetApplicationPolicy {
    static func preferredPID(
        frontmostExternalPID: Int32?,
        lastExternalPID: Int32?
    ) -> Int32? {
        frontmostExternalPID ?? lastExternalPID
    }
}

private struct ShortcutRecordingSession {
    let leaseToken: InputLeaseToken
    let originalBindings: [ToolSuiteCommand: ShortcutBinding]
    var pendingBinding: ShortcutBinding?
}

private enum StandaloneScreenshotMode: Equatable {
    case window
    case fullScreen
    case timedRegion
    case repeatLastRegion
}

@MainActor
final class ToolSuiteShell: ObservableObject {
    let monitor: AppModel
    let mainMenuBarStatusItemController: MainMenuBarStatusItemController
    let statusItemController: StatusItemController
    let shortcutRouter: any ShortcutRouting
    let inputModeCoordinator: InputModeCoordinator
    let captureResourceCoordinator: CaptureResourceCoordinator
    let permissionCenter: PermissionCenter
    let shelfController: ShelfSafeVisibilityController
    let artifactStore: ArtifactStore
    let artifactShelfController: ArtifactShelfController
    let pinnedScreenshotController: PinnedScreenshotController
    let screenshotWorkspaceController: ScreenshotWorkspaceController
    let scrollCaptureSessionController: ScrollCaptureSessionController
    let recordingSessionController: RecordingSessionController
    let gifExportService: GifExportService
    lazy var menuBarManagement: MenuBarManagementCoordinator = {
        MenuBarManagementCoordinator(
            captureQuickBarIcons: { [weak self] items in
                guard let self,
                      !self.isPreparingForTermination,
                      self.inputModeCoordinator.lease == nil,
                      let token = self.captureResourceCoordinator.acquireOptionalStill(
                          monitorActive: self.monitor.desiredMonitorState == .on
                      ) else { return [:] }
                let resources = self.captureResourceCoordinator
                return await MenuBarQuickBarIconCapture.capture(
                    items: items,
                    onSettled: { resources.releaseOptionalStill(token) }
                )
            },
            acquireInputLease: { [weak self] operationID in
                guard let self else { return nil }
                let token = self.inputModeCoordinator.acquire(
                    .menuBarShelfManagement,
                    operationID: operationID
                )
                self.monitor.setInputModeSuspended(
                    self.inputModeCoordinator.directPointerSuspended
                )
                self.synchronize()
                return token
            },
            releaseInputLease: { [weak self] token, reason in
                guard let self else { return false }
                let released = self.inputModeCoordinator.release(token, reason: reason)
                self.monitor.setInputModeSuspended(
                    self.inputModeCoordinator.directPointerSuspended
                )
                self.synchronize()
                return released
            }
        )
    }()

    @Published private(set) var isStarted = false
    @Published private(set) var isShortcutRecording = false
    @Published private(set) var lastCommandMessage: String?
    @Published private(set) var shortcutSettingsMessage: String?

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ToolSuiteShell")
    private var monitorObservation: AnyCancellable?
    private var menuBarManagementObservation: AnyCancellable?
    private var isPreparingCaptureSelection = false
    private var lastExternalApplicationPID: Int32?
    private var applicationActivationObserver: NSObjectProtocol?
    private var workspacePowerObservers: [NSObjectProtocol] = []
    private var shortcutHealthTask: Task<Void, Never>?
    private var shortcutRecoveryPolicy = ShortcutRecoveryPolicy()
    private var settingsWindowController: DisplayMonitorSettingsWindowController?
    private var shortcutRecordingSession: ShortcutRecordingSession?
    private var isPreparingForTermination = false
    private var terminationCleanupStarted = false
    private var terminationCleanupFinished = false
    private var captureWorkflowTask: Task<Void, Never>?
    private var gifExportTask: Task<Void, Never>?
    private var quickBarActivationTask: Task<Void, Never>?
    private var quickBarActivationID: UUID?
    private let acceptanceContext: AcceptanceContext?
    private lazy var mainMenuBarContextMenuController = MainMenuBarContextMenuController(
        shell: self
    )

    init(
        monitor: AppModel? = nil,
        shortcutRouter: (any ShortcutRouting)? = nil,
        artifactRootURL: URL? = nil
    ) {
        let monitor = monitor ?? AppModel(dependencies: AppModelDependencies.standard())
        self.monitor = monitor
        mainMenuBarStatusItemController = MainMenuBarStatusItemController()
        statusItemController = StatusItemController()
        self.shortcutRouter = shortcutRouter ?? ShortcutRouter()
        let inputModeCoordinator = InputModeCoordinator()
        self.inputModeCoordinator = inputModeCoordinator
        let acceptanceContext: AcceptanceContext?
        do {
            acceptanceContext = try AcceptanceRuntime.loadIfRequested()
        } catch {
            fatalError("Acceptance plan validation failed: \(error.localizedDescription)")
        }
        self.acceptanceContext = acceptanceContext
        let provisionalProbe = acceptanceContext.flatMap { context -> (
            combination: CaptureConcurrencyCombination,
            evidenceID: String
        )? in
            guard context.plan.mode == .capabilityProbe,
                  context.plan.phase == .execute,
                  let combination = context.plan.combination else { return nil }
            return (combination, "provisional-\(context.plan.nonce.uuidString)")
        }
        let capabilityProvider = CaptureConcurrencyCapabilityProvider(
            provisionalProbe: provisionalProbe
        )
        let capabilityProbeCoordinator = acceptanceContext.flatMap { context in
            context.plan.mode == .capabilityProbe && context.plan.phase == .execute
                ? CapabilityProbeAcceptanceCoordinator(
                    context: context,
                    provider: capabilityProvider
                )
                : nil
        }
        let captureResourceCoordinator = CaptureResourceCoordinator(
            capabilityProvider: capabilityProvider
        )
        self.captureResourceCoordinator = captureResourceCoordinator
        permissionCenter = PermissionCenter()
        shelfController = ShelfSafeVisibilityController()
        let finalizationFaultHandler: (@Sendable (
            ArtifactFinalizationFault,
            ArtifactManifest
        ) -> Void)?
        if let acceptanceContext {
            finalizationFaultHandler = { point, manifest in
                acceptanceContext.reporter.hitFinalizationFault(point, manifest: manifest)
            }
        } else {
            finalizationFaultHandler = nil
        }
        let artifactStore = ArtifactStore(
            rootURL: acceptanceContext?.artifactRoot ?? artifactRootURL ?? ArtifactStore.defaultRootURL(),
            validator: ArtifactMediaValidator.validate,
            staleLockInterval: acceptanceContext == nil ? 30 : 0,
            configuredFinalizationFault: acceptanceContext?.configuredFinalizationFault ?? .none,
            finalizationFaultHandler: finalizationFaultHandler
        )
        self.artifactStore = artifactStore
        let artifactShelfController = ArtifactShelfController(
            artifactStore: artifactStore,
            shouldAutoPresent: { monitor.artifactShelfAutoPresent },
            recentLimit: { monitor.artifactShelfRecentLimit },
            shelfMargin: { monitor.artifactShelfMargin },
            screenshotSaveDirectory: { monitor.screenshotSaveDirectory },
            initialAnnotationTool: { monitor.lastScreenshotAnnotationTool },
            onAnnotationToolSelected: { tool in
                monitor.setLastScreenshotAnnotationTool(tool)
            }
        )
        self.artifactShelfController = artifactShelfController
        let pinnedScreenshotController = PinnedScreenshotController(
            artifactStore: artifactStore,
            screenshotSaveDirectory: { monitor.screenshotSaveDirectory }
        )
        self.pinnedScreenshotController = pinnedScreenshotController
        let screenshotService = ScreenshotService()
        screenshotWorkspaceController = ScreenshotWorkspaceController(
            artifactStore: artifactStore,
            service: screenshotService,
            onSelectionWillBegin: {
                artifactShelfController.hideForCaptureSelection()
            }
        )
        let scrollCaptureSessionController = ScrollCaptureSessionController(
            artifactStore: artifactStore,
            artifactShelfController: artifactShelfController,
            resourceCoordinator: captureResourceCoordinator,
            inputModeCoordinator: inputModeCoordinator,
            monitorActive: { monitor.desiredMonitorState == .on }
        )
        self.scrollCaptureSessionController = scrollCaptureSessionController
        let recordingSessionController = RecordingSessionController(
            artifactStore: artifactStore,
            resourceCoordinator: captureResourceCoordinator,
            inputModeCoordinator: inputModeCoordinator,
            acceptanceContext: acceptanceContext,
            capabilityProbeCoordinator: capabilityProbeCoordinator,
            monitorCompleteFrameCount: { monitor.completeFrameCount },
            monitorHealthy: {
                monitor.desiredMonitorState == .on && monitor.monitorRuntimeState == .running
            },
            activeResourceCount: { captureResourceCoordinator.activeResources.count },
            monitorActive: { monitor.desiredMonitorState == .on }
        )
        self.recordingSessionController = recordingSessionController
        let gifExportService = GifExportService(
            artifactStore: artifactStore,
            isExtensionEnabled: { Self.gifCaptureExtensionEnabled },
            recordingBusy: { recordingSessionController.isBusy }
        )
        self.gifExportService = gifExportService
        artifactShelfController.onStatusMessage = { [weak self] message in
            self?.announce(message)
        }
        pinnedScreenshotController.onStatusMessage = { [weak self] message in
            self?.announce(message)
        }
        pinnedScreenshotController.onPinnedScreenshotsChanged = { [weak self] in
            self?.synchronize()
        }
        artifactShelfController.shouldRejectEditing = { [weak recordingSessionController] in
            recordingSessionController?.isRecording ?? false || scrollCaptureSessionController.isBusy
        }
        scrollCaptureSessionController.onStatusMessage = { [weak self] message in
            self?.announce(message)
        }
        scrollCaptureSessionController.onTerminal = { [weak self] _ in
            guard let self else { return }
            self.screenshotWorkspaceController.endCaptureOverlay()
            self.monitor.setInputModeSuspended(self.inputModeCoordinator.directPointerSuspended)
            self.synchronize()
        }
        recordingSessionController.onArtifactReady = { [weak self] artifact in
            Task { @MainActor [weak self] in
                guard let self, !self.isPreparingForTermination else { return }
                await self.artifactShelfController.present(artifact)
            }
        }
        recordingSessionController.onArtifactState = { [weak self] _ in
            self?.synchronize()
        }
        scrollCaptureSessionController.onArtifactState = { [weak self] _ in
            self?.synchronize()
        }
        recordingSessionController.onStatusMessage = { [weak self] message in
            self?.announce(message)
        }
        gifExportService.onStatusMessage = { [weak self] message in
            self?.announce(message)
            Task { @MainActor [weak self] in
                guard let self, !self.isPreparingForTermination else { return }
                await self.artifactShelfController.refresh()
            }
        }
        artifactShelfController.isGIFExportEnabled = { gifExportService.isEnabled }
        artifactShelfController.isGIFExporting = { gifExportService.isExporting }
        artifactShelfController.onExportGIF = { [weak self] source in
            guard let self, !self.isPreparingForTermination, self.gifExportTask == nil else { return }
            self.gifExportTask = Task { @MainActor [weak self] in
                guard let self, !self.isPreparingForTermination, !Task.isCancelled else { return }
                defer { self.gifExportTask = nil }
                do {
                    let artifact = try await self.gifExportService.export(from: source)
                    guard !self.isPreparingForTermination, !Task.isCancelled else { return }
                    await self.artifactShelfController.present(artifact)
                } catch is CancellationError {
                    return
                } catch let error as CaptureError {
                    self.announce("GIF 导出未完成：\(error.description)")
                } catch {
                    self.announce("GIF 导出未完成：\(error.localizedDescription)")
                }
                guard !self.isPreparingForTermination, !Task.isCancelled else { return }
                await self.artifactShelfController.refresh()
            }
        }
        artifactShelfController.onCancelGIFExport = { [weak self] in
            self?.gifExportTask?.cancel()
            self?.gifExportService.cancelCurrentExport()
        }
        artifactShelfController.onRetryRecording = { [weak self] in
            self?.captureRegion()
        }
        monitor.onQuitRequested = { [weak self] in
            self?.quit()
        }
    }

    var menuSymbolName: String {
        menuBarManagement.iconStyle.symbolName(monitorSymbol: monitor.menuSymbolName)
    }

    var shelfState: ShelfState {
        shelfController.state
    }

    var statusItemMode: StatusItemMode {
        statusItemController.mode
    }

    var shelfInventory: [SafeVisibilityInventoryItem] {
        shelfController.inventory
    }

    func startIfNeeded() async {
        guard !isStarted, !isPreparingForTermination, !Task.isCancelled else {
            return
        }
        isStarted = true
        configureMainMenuBarStatusItem()
        startTrackingExternalApplications()
        monitorObservation = monitor.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronize()
            }
        }

        await monitor.startIfNeeded()
        guard !isPreparingForTermination, !Task.isCancelled else { return }
        let recoveryResults = await artifactShelfController.start()
        guard !isPreparingForTermination, !Task.isCancelled else { return }
        if let acceptanceContext, acceptanceContext.plan.phase == .recover {
            if recoveryResults.isEmpty {
                acceptanceContext.reporter.record(event: "acceptance.recovery.empty")
            }
            for result in recoveryResults {
                let disposition: String
                switch result.disposition {
                case .unchanged: disposition = "unchanged"
                case .recoveredCompleted: disposition = "recoveredCompleted"
                case .recoveredPartial: disposition = "recoveredPartial"
                case .failed: disposition = "failed"
                case .needsConfirmation: disposition = "needsConfirmation"
                }
                acceptanceContext.reporter.record(event: "acceptance.recovery.result", fields: [
                    "artifactID": result.manifest.id.uuidString,
                    "operationID": result.manifest.activeOperationID.uuidString,
                    "status": result.manifest.status.rawValue,
                    "commitPhase": result.manifest.commitPhase.rawValue,
                    "commitSequence": String(result.manifest.commitSequence),
                    "disposition": disposition,
                    "message": result.message ?? ""
                ])
            }
        }
        installWorkspacePowerObservers()
        menuBarManagement.prepare()
        menuBarManagementObservation = menuBarManagement.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.synchronize()
            }
        }
        registerShortcuts()
        startShortcutHealthMonitoring()
        monitor.onDirectPointerShortcut = { [weak self] command in
            self?.route(command)
        }

        statusItemController.start(
            onToggleMonitor: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.toggleMonitor()
                }
            },
            onOpenConsole: { [weak self] in
                self?.announce("统一控制台已在 ToolSuite Anchor 中打开")
            },
            onCaptureRegion: { [weak self] in
                self?.captureRegion()
            },
            onRestoreShelf: { [weak self] in
                self?.restoreShelfReadOnly()
            }
        )
        synchronize()
        logger.info("shell.started monitor=\(self.monitor.desiredMonitorState.label, privacy: .public) shelf=\(self.shelfController.state.label, privacy: .public)")
        if ProcessInfo.processInfo.arguments.contains("--start-capture-selection") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self,
                      !self.isPreparingForTermination,
                      !Task.isCancelled,
                      !self.isPreparingCaptureSelection,
                      !self.scrollCaptureSessionController.isBusy,
                      !self.recordingSessionController.isBusy else { return }
                self.logger.info("capture.validation.startSelection")
                self.captureRegion()
            }
        }
        Task { @MainActor in
            await V1ACaptureProbe.runIfRequested()
        }
    }

    func toggleMonitor() async {
        guard !isPreparingForTermination, !Task.isCancelled else { return }
        await monitor.toggleMonitor()
        synchronize()
    }

    func expandPreview() {
        guard !isPreparingForTermination else { return }
        monitor.expandPreview()
        synchronize()
    }

    func collapsePreview() {
        guard !isPreparingForTermination else { return }
        monitor.collapsePreview()
        synchronize()
    }

    func togglePause() async {
        guard !isPreparingForTermination, !Task.isCancelled else { return }
        await monitor.togglePause()
        synchronize()
    }

    func captureRegion() {
        beginCaptureSelection()
    }

    func captureWindow() {
        beginStandaloneScreenshot(.window)
    }

    func captureFullScreen() {
        beginStandaloneScreenshot(.fullScreen)
    }

    func captureTimedRegion() {
        beginStandaloneScreenshot(.timedRegion)
    }

    func repeatLastScreenshot() {
        beginStandaloneScreenshot(.repeatLastRegion)
    }

    func stopScrollCapture() {
        scrollCaptureSessionController.finishUserStopped()
    }

    func stopRecording() {
        Task { @MainActor [weak self] in
            await self?.recordingSessionController.stop()
        }
    }

    func toggleArtifactShelf() {
        artifactShelfController.toggleVisibility()
    }

    func clearPinnedScreenshots() {
        pinnedScreenshotController.dismissAll()
    }

    func movePointerToTargetDisplay() {
        guard !inputModeCoordinator.directPointerSuspended else {
            announce("菜单栏排序正在使用鼠标，请等待完成或先停止排序")
            return
        }
        monitor.movePointerToTargetDisplay()
    }

    func movePointerToMainDisplay() {
        guard !inputModeCoordinator.directPointerSuspended else {
            announce("菜单栏排序正在使用鼠标，请等待完成或先停止排序")
            return
        }
        monitor.movePointerToMainDisplay()
    }

    func openSettingsWindow(tab: DisplayMonitorSettingsTab? = nil) {
        guard !isPreparingForTermination else { return }
        if let settingsWindowController {
            settingsWindowController.present(tab: tab)
            return
        }
        let controller = DisplayMonitorSettingsWindowController(shell: self)
        controller.onClose = { [weak self] in
            self?.settingsWindowController = nil
        }
        settingsWindowController = controller
        controller.present(tab: tab)
    }

    func toggleMenuBarCollapse() {
        guard !isPreparingForTermination else { return }
        if menuBarManagement.isEnabled {
            menuBarManagement.toggleCollapseFromSettings()
        } else {
            openSettingsWindow(tab: .menuBar)
        }
    }

    private func configureMainMenuBarStatusItem() {
        let quickBarIsActive = menuBarManagement.isEnabled
            && menuBarManagement.wantsPersistentCollapse
            && menuBarManagement.isCollapsed
        mainMenuBarStatusItemController.updatePresentationMode(
            quickBarIsActive ? menuBarManagement.primaryPresentationMode : .nativeMenuBar
        )
        mainMenuBarStatusItemController.updateQuickBarItems(
            quickBarIsActive ? menuBarManagement.quickBarItems : []
        )
        mainMenuBarStatusItemController.updateChangePresentation(
            menuBarManagement.changePresentation
        )
        mainMenuBarStatusItemController.updateHoverEnabled(
            quickBarIsActive && menuBarManagement.showQuickBarOnHover
        )
        mainMenuBarStatusItemController.onRevealNativeMenuBar = { [weak self] in
            guard let self, !self.isPreparingForTermination else { return }
            if self.menuBarManagement.isEnabled {
                self.menuBarManagement.toggleCurrentCollapseVisibility()
            } else {
                self.openSettingsWindow(tab: .menuBar)
            }
        }
        mainMenuBarStatusItemController.onQuickBarItemSelected = { [weak self] item in
            self?.activateQuickBarItem(item)
        }
        mainMenuBarStatusItemController.onQuickBarOrderApplied = { [weak self] originalIDs, proposedIDs in
            guard let self, !self.isPreparingForTermination else { return }
            self.menuBarManagement.applyQuickBarOrder(
                originalIDs: originalIDs,
                proposedIDs: proposedIDs
            )
            self.synchronize()
        }
        mainMenuBarStatusItemController.onContextMenuRequested = { [weak self] statusItem in
            self?.mainMenuBarContextMenuController.show(relativeTo: statusItem)
        }
        mainMenuBarStatusItemController.onQuickBarDismissed = { [weak self] dismissedChangeID in
            self?.menuBarManagement.dismissChangePresentation(id: dismissedChangeID)
            self?.synchronize()
        }
        mainMenuBarStatusItemController.start(
            symbolName: menuSymbolName,
            title: AppConstants.appName,
            accessibilityIdentifier: MenuBarManagementCoordinator.anchorAccessibilityIdentifier
        )
        menuBarManagement.ownedStatusItemEvidence = { [weak self] in
            guard let self else { return nil }
            let mainVisible = self.mainMenuBarStatusItemController.hasVisibleEntry
            return MenuBarOwnedStatusItemEvidence(
                processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier),
                mainEntryVisible: mainVisible,
                visibleItemCount: (mainVisible ? 1 : 0) + (self.statusItemController.isActivityVisible ? 1 : 0)
            )
        }
    }

    private func activateQuickBarItem(_ item: MenuBarQuickBarItem) {
        guard menuBarManagement.isEnabled,
              menuBarManagement.wantsPersistentCollapse,
              !isPreparingForTermination else {
            openSettingsWindow(tab: .menuBar)
            return
        }
        if let reason = item.selectionBlockReason {
            announce(reason)
            return
        }
        let previousTask = quickBarActivationTask
        previousTask?.cancel()
        let operationID = UUID()
        quickBarActivationID = operationID
        quickBarActivationTask = Task { @MainActor [weak self, previousTask] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled,
                  !self.isPreparingForTermination,
                  self.quickBarActivationID == operationID else { return }
            guard let leaseToken = self.inputModeCoordinator.acquire(
                .menuBarShelfManagement,
                operationID: operationID
            ) else {
                self.announce("当前有截图、录屏或其他输入操作，暂时不能打开隐藏图标")
                if self.quickBarActivationID == operationID {
                    self.quickBarActivationID = nil
                    self.quickBarActivationTask = nil
                }
                return
            }
            var releaseReason = InputLeaseReleaseReason.cancelled
            var revealInteractionToken: UUID?
            var shouldRecollapse = false
            var keepExpandedAsUserIntent = false
            var recollapseDelay = Duration.milliseconds(350)
            self.monitor.setInputModeSuspended(true)
            self.synchronize()
            defer {
                _ = self.inputModeCoordinator.release(leaseToken, reason: releaseReason)
                self.monitor.setInputModeSuspended(
                    self.inputModeCoordinator.directPointerSuspended
                )
                if let revealInteractionToken {
                    self.menuBarManagement.endTemporaryRevealInteraction(
                        revealInteractionToken,
                        shouldRecollapse: shouldRecollapse,
                        keepExpandedAsUserIntent: keepExpandedAsUserIntent,
                        delay: recollapseDelay
                    )
                }
                if self.quickBarActivationID == operationID {
                    self.quickBarActivationID = nil
                    self.quickBarActivationTask = nil
                }
                self.synchronize()
            }
            guard let interactionToken = self.menuBarManagement.beginTemporaryRevealInteraction()
            else { return }
            revealInteractionToken = interactionToken
            self.synchronize()
            self.announce("正在显示并打开 \(item.displayName) 的真实菜单…")
            // The real AX activation is supplied by MenuBarQuickBarItemActivator.
            // Keeping this orchestration here lets the status-item controller
            // remain presentation-only.
            guard !Task.isCancelled, !self.isPreparingForTermination else { return }
            let baselineMenuObservation = MenuBarQuickBarMenuObservationReader.read(
                ownerPID: item.processIdentifier,
                expectedBundleIdentifier: item.bundleIdentifier
            )
            let result = await MenuBarQuickBarItemActivator.activate(item)
            guard !Task.isCancelled, !self.isPreparingForTermination else { return }
            switch result {
            case .activated:
                self.announce("已打开 \(item.displayName) 的真实菜单")
                let didObserveMenuClose = await self.waitForQuickBarMenuToClose(
                    item: item,
                    baseline: baselineMenuObservation
                )
                guard !Task.isCancelled, !self.isPreparingForTermination else { return }
                releaseReason = .completed
                shouldRecollapse = didObserveMenuClose
                if !didObserveMenuClose {
                    keepExpandedAsUserIntent = true
                    self.announce("无法确认原应用菜单已经关闭，左侧图标暂时保持展开；再次点击入口可重新收起")
                }
            case .notFound(let message), .failed(let message):
                self.announce(message)
                releaseReason = .completed
                shouldRecollapse = true
                recollapseDelay = .seconds(1)
            case .cancelled:
                return
            }
        }
    }

    private func waitForQuickBarMenuToClose(
        item: MenuBarQuickBarItem,
        baseline: MenuBarQuickBarMenuObservation
    ) async -> Bool {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let totalBudget = Duration.seconds(15)
        let openingBudget = Duration.seconds(4)
        return await MenuBarQuickBarMenuCloseWaiter.wait(
            baseline: baseline,
            remainingBudget: {
                let elapsed = startedAt.duration(to: clock.now)
                return elapsed >= totalBudget ? .zero : totalBudget - elapsed
            },
            openingRemainingBudget: {
                let elapsed = startedAt.duration(to: clock.now)
                return elapsed >= openingBudget ? .zero : openingBudget - elapsed
            },
            observe: {
                MenuBarQuickBarMenuObservationReader.read(
                    ownerPID: item.processIdentifier,
                    expectedBundleIdentifier: item.bundleIdentifier
                )
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    func cancelMenuBarOrdering(reason: String) {
        menuBarManagement.cancel(reason: reason)
    }

    func setArtifactShelfFollowsActiveDisplay(_ enabled: Bool) {
        monitor.setArtifactShelfFollowsActiveDisplay(enabled)
        artifactShelfController.refreshFollowActiveDisplayPolicy()
    }

    func chooseScreenshotSaveDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存位置"
        panel.message = "点击截图预览浮窗的“保存”按钮时，文件会保存到这里"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = monitor.screenshotSaveDirectory

        AppWindowActivation.activate()
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            announce("所选文件夹不可写，请选择其他位置")
            return
        }
        monitor.setScreenshotSaveDirectory(directory)
        announce("截图保存位置已设为：\(monitor.screenshotSaveDirectory.path)")
        synchronize()
    }

    func revealScreenshotSaveDirectory() {
        let directory = monitor.screenshotSaveDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            announce("无法打开截图保存位置：\(error.localizedDescription)")
        }
    }

    func resetScreenshotSaveDirectory() {
        monitor.resetScreenshotSaveDirectory()
        announce("截图保存位置已恢复默认：\(monitor.screenshotSaveDirectory.path)")
        synchronize()
    }

    func beginShortcutRecording() -> Bool {
        guard shortcutRecordingSession == nil else {
            return false
        }
        guard let leaseToken = inputModeCoordinator.acquire(.shortcutSafety) else {
            if let activeOwner = inputModeCoordinator.lease?.owner {
                announceShortcut("请先完成“\(activeOwner.label)”，再修改快捷键")
            } else {
                announceShortcut("当前输入操作尚未结束，请稍后再修改快捷键")
            }
            synchronize()
            return false
        }

        let originalBindings = Dictionary(
            uniqueKeysWithValues: monitor.shortcutBindings.map { ($0.command, $0) }
        )
        shortcutRecordingSession = ShortcutRecordingSession(
            leaseToken: leaseToken,
            originalBindings: originalBindings,
            pendingBinding: nil
        )
        isShortcutRecording = true
        shortcutRouter.stop()
        monitor.updateShortcutRegistrations([])
        monitor.setInputModeSuspended(inputModeCoordinator.directPointerSuspended)
        announceShortcut("录制中，已暂时停用全局快捷键")
        synchronize()
        logger.info("shortcut.recording.started")
        return true
    }

    @discardableResult
    func updateShortcutBinding(_ binding: ShortcutBinding) -> Bool {
        let existingBindings = monitor.shortcutBindings
        if let conflict = ShortcutRegistry.conflictingCommand(
            for: binding,
            in: existingBindings
        ) {
            announceShortcut("\(binding.keyEquivalent) 已用于“\(conflict.title)”")
            return false
        }
        guard let previousBinding = existingBindings.first(where: {
            $0.command == binding.command
        }) else {
            return false
        }
        guard previousBinding != binding else {
            announceShortcut("“\(binding.command.title)”快捷键未更改")
            return false
        }

        if shortcutRecordingSession != nil {
            shortcutRecordingSession?.pendingBinding = binding
            announceShortcut("已录入 \(binding.keyEquivalent)，松开按键后生效")
            synchronize()
            return true
        }

        monitor.setShortcutBinding(binding)
        registerShortcuts()
        guard let registration = shortcutRouter.registrations.first(where: {
            $0.shortcut == binding.command
        }), registration.isRegistered else {
            monitor.setShortcutBinding(previousBinding)
            registerShortcuts()
            announceShortcut("\(binding.keyEquivalent) 无法注册，已恢复 \(previousBinding.keyEquivalent)")
            synchronize()
            return false
        }

        announceShortcut("“\(binding.command.title)”已改为 \(binding.keyEquivalent)")
        synchronize()
        return true
    }

    func finishShortcutRecording(_ completion: ShortcutRecorderCompletion) {
        guard let session = shortcutRecordingSession else {
            return
        }
        shortcutRecordingSession = nil
        isShortcutRecording = false

        var releaseReason = InputLeaseReleaseReason.cancelled
        if completion == .captured, let pendingBinding = session.pendingBinding {
            monitor.setShortcutBinding(pendingBinding)
            registerShortcuts()
            if let registration = shortcutRouter.registrations.first(where: {
                $0.shortcut == pendingBinding.command
            }), registration.isRegistered {
                releaseReason = .completed
                announceShortcut("“\(pendingBinding.command.title)”已改为 \(pendingBinding.keyEquivalent)")
            } else if let originalBinding = session.originalBindings[pendingBinding.command] {
                monitor.setShortcutBinding(originalBinding)
                registerShortcuts()
                announceShortcut(
                    "\(pendingBinding.keyEquivalent) 无法注册，已恢复 \(originalBinding.keyEquivalent)"
                )
            }
        } else {
            registerShortcuts()
            if completion == .cancelled {
                announceShortcut("已取消，快捷键未更改")
            }
        }

        if !inputModeCoordinator.release(session.leaseToken, reason: releaseReason) {
            logger.error("shortcut.recording.releaseRejected")
        }
        monitor.setInputModeSuspended(inputModeCoordinator.directPointerSuspended)
        synchronize()
        logger.info(
            "shortcut.recording.finished completion=\(String(describing: completion), privacy: .public) release=\(releaseReason.rawValue, privacy: .public)"
        )
    }

    func cancelShortcutRecording() {
        finishShortcutRecording(.cancelled)
    }

    private func discardShortcutRecordingForTermination() {
        guard let session = shortcutRecordingSession else {
            return
        }
        shortcutRecordingSession = nil
        isShortcutRecording = false
        _ = inputModeCoordinator.release(
            session.leaseToken,
            reason: .applicationTermination
        )
    }

    func restoreDefaultShortcutBindings() {
        guard !isShortcutRecording else {
            announceShortcut("请先按 Esc 取消当前快捷键录制")
            return
        }
        monitor.restoreDefaultShortcutBindings()
        registerShortcuts()
        announceShortcut("快捷键已恢复默认绑定")
        synchronize()
    }

    func refreshPermissions() async {
        await monitor.recheckPermission(restartCapture: monitor.desiredMonitorState == .on)
        if monitor.permissionState != .granted {
            await scrollCaptureSessionController.stopForPermissionRevocation()
            await recordingSessionController.stopForPermissionRevocation()
        }
        permissionCenter.refresh()
        menuBarManagement.refreshPermissions()
        synchronize()
    }

    func openScreenRecordingSettings() {
        permissionCenter.openScreenRecordingSettings()
    }

    func openAccessibilitySettings() {
        permissionCenter.openAccessibilitySettings()
    }

    func restoreShelfReadOnly() {
        shelfController.restoreAllReadOnly()
        announce(shelfController.lastActionMessage ?? "Shelf 恢复入口已保留")
        synchronize()
    }

    func quit() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Synchronous input/UI barrier, executed before the first terminate call
    /// unwinds. Late async completions must not start another capture session.
    func beginTermination() {
        guard !isPreparingForTermination else { return }
        isPreparingForTermination = true
        logger.notice("lifecycle.cleanup.begin")
        captureWorkflowTask?.cancel()
        menuBarManagement.beginTermination()
        discardShortcutRecordingForTermination()
        shortcutHealthTask?.cancel()
        shortcutHealthTask = nil
        shortcutRouter.stop()
        stopTrackingExternalApplications()
        removeWorkspacePowerObservers()
        monitor.onDirectPointerShortcut = nil
        monitor.onQuitRequested = nil
        inputModeCoordinator.beginTermination()
        captureResourceCoordinator.stopAcceptingRequests()
        monitor.beginTermination()
        monitor.setInputModeSuspended(true)
        screenshotWorkspaceController.cancel()
        artifactShelfController.hide()
        quickBarActivationID = nil
        quickBarActivationTask?.cancel()
        quickBarActivationTask = nil
        mainMenuBarStatusItemController.stop()
        statusItemController.stop()
        gifExportTask?.cancel()
        gifExportService.beginTermination()
        monitorObservation?.cancel()
        monitorObservation = nil
        menuBarManagementObservation?.cancel()
        menuBarManagementObservation = nil
    }

    func prepareForTermination(recordingBudgetSeconds: TimeInterval = 5) async {
        beginTermination()
        guard !terminationCleanupStarted else { return }
        terminationCleanupStarted = true
        // Stop independent streams together so an unresponsive scroll stream
        // cannot consume the recording's entire persistence budget.
        async let scroll: Void = scrollCaptureSessionController.shutdown()
        async let recording: Void = finishRecordingWithinTerminationBudget(seconds: recordingBudgetSeconds)
        async let monitor: Void = self.monitor.shutdownForShell()
        async let menuBar: Void = menuBarManagement.shutdown()
        _ = await (scroll, recording, monitor, menuBar)
        finishTerminationCleanup()
    }

    func finishTerminationCleanup() {
        guard !terminationCleanupFinished else { return }
        terminationCleanupFinished = true
        _ = inputModeCoordinator.releaseAll(reason: .applicationTermination)
        captureResourceCoordinator.releaseAllForTermination()
        monitor.setInputModeSuspended(true)
        logger.notice("lifecycle.cleanup.finished")
    }

    private func finishRecordingWithinTerminationBudget(seconds: TimeInterval) async {
        guard recordingSessionController.isBusy else { return }
        await withCheckedContinuation { continuation in
            var resolved = false
            let resumeOnce: @MainActor () -> Void = {
                guard !resolved else { return }
                resolved = true
                continuation.resume()
            }
            Task { @MainActor [recordingSessionController] in
                await recordingSessionController.shutdown()
                resumeOnce()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                resumeOnce()
            }
        }
    }

    private func route(_ command: ToolSuiteCommand) {
        guard !isPreparingForTermination else { return }
        logger.info("shortcut.route command=\(command.title, privacy: .public)")
        switch command {
        case .toggleMonitor:
            Task { @MainActor [weak self] in
                await self?.toggleMonitor()
            }
        case .captureRegion:
            beginCaptureSelection()
        case .togglePause:
            Task { @MainActor [weak self] in
                await self?.togglePause()
            }
        case .moveToTarget:
            movePointerToTargetDisplay()
        case .moveToMain:
            movePointerToMainDisplay()
        }
        synchronize()
    }

    private func beginCaptureSelection() {
        guard !isPreparingForTermination else { return }
        guard !isPreparingCaptureSelection else {
            announce("正在检查可共享显示器，请稍候")
            return
        }
        guard !screenshotWorkspaceController.isSelecting,
              !scrollCaptureSessionController.isBusy,
              !recordingSessionController.isBusy else {
            announce("当前已有采集会话，请先结束或等待收尾")
            return
        }
        let operationID = UUID()
        guard let selectionLeaseToken = inputModeCoordinator.acquire(
            .captureWorkflow,
            operationID: operationID
        ) else {
            announce("当前已有输入操作占用，未重复启动截图工作流")
            return
        }
        isPreparingCaptureSelection = true
        monitor.setInputModeSuspended(true)
        let targetApplicationPID = preferredCaptureTargetApplicationPID()
        logger.info(
            "capture.target.selected pid=\(targetApplicationPID ?? -1, privacy: .public) remembered=\(self.lastExternalApplicationPID ?? -1, privacy: .public)"
        )
        announce("正在准备截图…")
        captureWorkflowTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            var leaseReleaseReason: InputLeaseReleaseReason = .cancelled
            var workflowLeaseToken: InputLeaseToken? = selectionLeaseToken
            var stillResourceHeld = false
            defer {
                if stillResourceHeld {
                    self.captureResourceCoordinator.release(.still)
                }
                self.isPreparingCaptureSelection = false
                self.captureWorkflowTask = nil
                if let workflowLeaseToken {
                    self.inputModeCoordinator.release(
                        workflowLeaseToken,
                        reason: leaseReleaseReason
                    )
                }
                self.monitor.setInputModeSuspended(self.inputModeCoordinator.directPointerSuspended)
                self.synchronize()
            }

            guard await self.ensureSelectableDisplayForCapture(
                workflow: "regionSelection"
            ) else {
                guard !self.isPreparingForTermination, !Task.isCancelled else { return }
                let message = "截图不可用：当前没有可共享显示器，请先唤醒或连接显示器"
                self.announce(message)
                self.screenshotWorkspaceController.showNotice(message)
                self.logger.error("screenshot.unavailable reason=noSelectableDisplay")
                return
            }

            do {
                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }
                let resourceDecision = await self.captureResourceCoordinator.acquire(
                    .still,
                    monitorActive: self.monitor.desiredMonitorState == .on
                )
                guard case .granted = resourceDecision else {
                    let reason: String
                    switch resourceDecision {
                    case .queued(let message), .rejected(let message): reason = message
                    case .granted: reason = "资源不可用"
                    }
                    throw CaptureError(
                        code: "screenshot_resource_unavailable",
                        message: "截图暂不可启动",
                        detail: reason
                    )
                }
                stillResourceHeld = true
                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }
                self.announce("拖动框选区域")
                let request = try await self.screenshotWorkspaceController.selectCaptureAction()
                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }

                switch request.action {
                case .still, .pinStill:
                    let result = try await self.screenshotWorkspaceController.captureSelectedRegion(
                        selected: request.selectedRegion,
                        frozenFrame: request.frozenFrame,
                        operationID: operationID
                    )
                    try Task.checkCancellation()
                    guard !self.isPreparingForTermination else { throw CancellationError() }
                    self.monitor.rememberScreenshotSelection(request.selectedRegion)
                    if request.action == .pinStill {
                        await self.pinnedScreenshotController.present(result.artifact)
                    } else {
                        await self.artifactShelfController.present(result.artifact)
                        self.announce("截图已捕获：请在截图浮窗中复制或存储")
                    }
                    leaseReleaseReason = .completed

                case .scroll:
                    do {
                        self.captureResourceCoordinator.release(.still)
                        stillResourceHeld = false
                        guard let scrollLeaseToken = self.inputModeCoordinator.transfer(
                            selectionLeaseToken,
                            to: .scrollCapture
                        ) else {
                            throw CaptureError(
                                code: "scroll_capture_lease_transfer_failed",
                                message: "滚动截图无法接管输入租约"
                            )
                        }
                        workflowLeaseToken = nil
                        try await self.scrollCaptureSessionController.start(
                            selection: request.selectedRegion,
                            requestedMode: self.monitor.scrollCaptureMode,
                            targetApplicationPID: targetApplicationPID,
                            operationID: operationID,
                            leaseToken: scrollLeaseToken
                        )
                        leaseReleaseReason = .completed
                        self.announce("正在准备滚动截图…")
                    } catch {
                        self.screenshotWorkspaceController.endCaptureOverlay()
                        throw error
                    }

                case .recording:
                    self.captureResourceCoordinator.release(.still)
                    stillResourceHeld = false
                    guard let recordingLeaseToken = self.inputModeCoordinator.transfer(
                        selectionLeaseToken,
                        to: .recordingCapture
                    ) else {
                        throw CaptureError(
                            code: "recording_lease_transfer_failed",
                            message: "区域录屏无法接管输入租约"
                        )
                    }
                    workflowLeaseToken = nil
                    self.announce("正在准备区域录屏；可在 HUD 中取消")
                    try await self.recordingSessionController.start(
                        selection: request.selectedRegion,
                        showsCursor: self.monitor.showsCursor,
                        operationID: operationID,
                        leaseToken: recordingLeaseToken
                    )
                    leaseReleaseReason = .completed
                }
            } catch is CancellationError {
                leaseReleaseReason = self.isPreparingForTermination ? .applicationTermination : .cancelled
            } catch let error as CaptureError where error.code == "screenshot_cancelled" {
                self.announce("截图已取消")
            } catch let error as CaptureError {
                self.announce("采集失败：\(error.description)")
                self.logger.error("capture.workflow.failed code=\(error.code, privacy: .public) detail=\(error.detail ?? "", privacy: .public)")
            } catch {
                self.announce("采集失败：\(String(describing: error))")
                self.logger.error("capture.workflow.failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func beginStandaloneScreenshot(_ mode: StandaloneScreenshotMode) {
        guard !isPreparingForTermination else { return }
        guard !isPreparingCaptureSelection else {
            announce("正在检查可共享显示器，请稍候")
            return
        }
        guard !screenshotWorkspaceController.isSelecting,
              !scrollCaptureSessionController.isBusy,
              !recordingSessionController.isBusy else {
            announce("当前已有采集会话，请先结束或等待收尾")
            return
        }
        if mode == .repeatLastRegion, monitor.lastScreenshotSelection == nil {
            announce("还没有可重复的截图区域，请先完成一次截图")
            return
        }

        let operationID = UUID()
        guard let leaseToken = inputModeCoordinator.acquire(
            .captureWorkflow,
            operationID: operationID
        ) else {
            announce("当前已有输入操作占用，未重复启动截图工作流")
            return
        }
        isPreparingCaptureSelection = true
        monitor.setInputModeSuspended(true)
        announce(standalonePreparationMessage(for: mode))

        captureWorkflowTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var releaseReason: InputLeaseReleaseReason = .cancelled
            defer {
                self.isPreparingCaptureSelection = false
                self.captureWorkflowTask = nil
                self.inputModeCoordinator.release(leaseToken, reason: releaseReason)
                self.monitor.setInputModeSuspended(self.inputModeCoordinator.directPointerSuspended)
                self.synchronize()
            }

            guard await self.ensureSelectableDisplayForCapture(
                workflow: "standalone"
            ) else {
                guard !self.isPreparingForTermination, !Task.isCancelled else { return }
                let message = "截图不可用：当前没有可共享显示器，请先唤醒或连接显示器"
                self.announce(message)
                self.screenshotWorkspaceController.showNotice(message)
                return
            }

            guard !self.isPreparingForTermination, !Task.isCancelled else { return }

            let resourceDecision = await self.captureResourceCoordinator.acquire(
                .still,
                monitorActive: self.monitor.desiredMonitorState == .on
            )
            guard case .granted = resourceDecision else {
                let detail: String
                switch resourceDecision {
                case .queued(let message), .rejected(let message): detail = message
                case .granted: detail = "资源不可用"
                }
                self.announce("截图暂不可启动：\(detail)")
                return
            }
            defer { self.captureResourceCoordinator.release(.still) }

            do {
                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }
                let result: ScreenshotWorkspaceController.Result
                switch mode {
                case .window:
                    result = try await self.screenshotWorkspaceController.captureWindow(
                        operationID: operationID
                    )
                case .fullScreen:
                    self.artifactShelfController.hideForCaptureSelection()
                    try await Task.sleep(nanoseconds: 120_000_000)
                    result = try await self.screenshotWorkspaceController.captureDisplayUnderPointer(
                        operationID: operationID
                    )
                case .timedRegion:
                    result = try await self.screenshotWorkspaceController.captureSelectedRegionAfterCountdown(
                        seconds: self.monitor.screenshotTimerDelaySeconds,
                        operationID: operationID
                    )
                case .repeatLastRegion:
                    guard let savedSelection = self.monitor.lastScreenshotSelection else {
                        throw CaptureError(
                            code: "screenshot_repeat_unavailable",
                            message: "还没有可重复的截图区域"
                        )
                    }
                    let selection = try self.screenshotWorkspaceController.resolveRepeatSelection(
                        savedSelection
                    )
                    self.artifactShelfController.hideForCaptureSelection()
                    try await Task.sleep(nanoseconds: 120_000_000)
                    result = try await self.screenshotWorkspaceController.captureSelectedRegion(
                        selected: selection,
                        operationID: operationID
                    )
                }

                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }
                self.monitor.rememberScreenshotSelection(
                    ScreenshotWorkspaceController.SelectedRegion(
                        displayID: result.displayID,
                        region: result.region
                    )
                )
                await self.artifactShelfController.present(result.artifact)
                self.announce("截图已捕获：请在截图浮窗中复制、编辑或存储")
                releaseReason = .completed
            } catch is CancellationError {
                releaseReason = self.isPreparingForTermination ? .applicationTermination : .cancelled
            } catch let error as CaptureError where error.code == "screenshot_cancelled" {
                self.announce("截图已取消")
            } catch let error as CaptureError {
                self.announce("截图失败：\(error.description)")
                self.logger.error(
                    "screenshot.standalone.failed code=\(error.code, privacy: .public) detail=\(error.detail ?? "", privacy: .public)"
                )
            } catch {
                self.announce("截图失败：\(error.localizedDescription)")
                self.logger.error("screenshot.standalone.failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func standalonePreparationMessage(for mode: StandaloneScreenshotMode) -> String {
        switch mode {
        case .window: return "移动鼠标选择要截图的窗口"
        case .fullScreen: return "正在截取鼠标所在显示器…"
        case .timedRegion: return "拖动框选区域，随后开始倒计时"
        case .repeatLastRegion: return "正在重复上一次截图区域…"
        }
    }

    private func ensureSelectableDisplayForCapture(workflow: String) async -> Bool {
        guard !isPreparingForTermination, !Task.isCancelled else { return false }
        if monitor.displays.contains(where: { $0.captureAvailability.isSelectable }) {
            logger.info(
                "screenshot.displayRefresh.skipped workflow=\(workflow, privacy: .public) reason=cachedSelectableDisplay"
            )
            return true
        }

        logger.info(
            "screenshot.displayRefresh.requested workflow=\(workflow, privacy: .public) reason=noCachedSelectableDisplay"
        )
        let progressNotice = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !self.isPreparingForTermination else { return }
            self.screenshotWorkspaceController.showNotice("正在准备截图…")
        }
        await monitor.refreshDisplaysForUserAction()
        progressNotice.cancel()
        return !isPreparingForTermination && !Task.isCancelled
            && monitor.displays.contains(where: { $0.captureAvailability.isSelectable })
    }

    private func startTrackingExternalApplications() {
        stopTrackingExternalApplications()
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(application)
            }
        }
    }

    private func installWorkspacePowerObservers() {
        removeWorkspacePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        workspacePowerObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.recordingSessionController.stopForSystemSleep()
                    self?.synchronize()
                }
            }
        )
        workspacePowerObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.recordingSessionController.handleSystemWake()
                    self?.requestShortcutRecovery(reason: "workspaceWake")
                    self?.synchronize()
                }
            }
        )
        workspacePowerObservers.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestShortcutRecovery(reason: "sessionActive")
                }
            }
        )
    }

    private func removeWorkspacePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspacePowerObservers.forEach(center.removeObserver)
        workspacePowerObservers.removeAll()
    }

    private func stopTrackingExternalApplications() {
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application, isEligibleCaptureTarget(application) else { return }
        lastExternalApplicationPID = application.processIdentifier
    }

    private func preferredCaptureTargetApplicationPID() -> Int32? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication.flatMap { application in
            isEligibleCaptureTarget(application) ? application.processIdentifier : nil
        }
        let rememberedPID = lastExternalApplicationPID.flatMap { pid -> Int32? in
            guard let application = NSRunningApplication(processIdentifier: pid),
                  isEligibleCaptureTarget(application) else { return nil }
            return pid
        }
        let preferred = CaptureTargetApplicationPolicy.preferredPID(
            frontmostExternalPID: frontmostPID,
            lastExternalPID: rememberedPID
        )
        if let preferred,
           let application = NSRunningApplication(processIdentifier: preferred) {
            rememberExternalApplication(application)
        }
        return preferred
    }

    private func isEligibleCaptureTarget(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != Int32(ProcessInfo.processInfo.processIdentifier) &&
            application.bundleIdentifier != AppConstants.bundleIdentifier &&
            !application.isTerminated
    }

    private func registerShortcuts() {
        guard !isPreparingForTermination else { return }
        let bindings = ShortcutRegistry.bindings(from: monitor.persistedShortcutBindings)
        shortcutRouter.start(bindings: bindings) { [weak self] command in
            self?.route(command)
        }
        monitor.updateShortcutRegistrations(shortcutRouter.registrations)
        let optionChordUnsafe = !shortcutRouter.hasSafeOptionChordRegistration
        inputModeCoordinator.setGlobalShortcutSafetyPaused(optionChordUnsafe)
        monitor.setInputModeSuspended(inputModeCoordinator.directPointerSuspended)
    }

    private func startShortcutHealthMonitoring() {
        shortcutHealthTask?.cancel()
        shortcutHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.performShortcutHealthCheck(reason: "periodic")
            }
        }
    }

    private func requestShortcutRecovery(reason: String) {
        shortcutRecoveryPolicy.requestLifecycleRecovery()
        performShortcutHealthCheck(reason: reason)
    }

    private func performShortcutHealthCheck(reason: String) {
        let bindings = ShortcutRegistry.bindings(from: monitor.persistedShortcutBindings)
        let registrationsHealthy = ShortcutRegistrationHealth.isHealthy(
            expectedBindings: bindings,
            registrations: shortcutRouter.registrations
        )
        let shouldRegister = shortcutRecoveryPolicy.shouldRegister(
            secureInputEnabled: IsSecureEventInputEnabled(),
            symbolicHotKeyMode: GetSymbolicHotKeyMode(),
            registrationsHealthy: registrationsHealthy,
            recoveryAllowed: !isPreparingForTermination && !isShortcutRecording
        )
        guard shouldRegister else { return }

        registerShortcuts()
        let recovered = ShortcutRegistrationHealth.isHealthy(
            expectedBindings: bindings,
            registrations: shortcutRouter.registrations
        )
        if recovered {
            logger.info("shortcut.recovery.succeeded reason=\(reason, privacy: .public)")
        } else {
            logger.error("shortcut.recovery.retryPending reason=\(reason, privacy: .public)")
        }
    }

    private func announce(_ message: String) {
        lastCommandMessage = message
        logger.info("command.message \(message, privacy: .public)")
    }

    private func announceShortcut(_ message: String) {
        shortcutSettingsMessage = message
        announce(message)
    }

    private func synchronize() {
        permissionCenter.sync(
            screenRecording: monitor.permissionState,
            accessibility: monitor.inputControlPermission
        )
        monitor.updateShortcutRegistrations(shortcutRouter.registrations)
        statusItemController.update(
            desiredState: monitor.desiredMonitorState,
            runtimeState: monitor.monitorRuntimeState,
            shelfState: shelfController.state
        )
        mainMenuBarStatusItemController.updateSymbol(
            name: menuSymbolName,
            accessibilityDescription: AppConstants.appName
        )
        let quickBarIsActive = menuBarManagement.isEnabled
            && menuBarManagement.wantsPersistentCollapse
            && menuBarManagement.isCollapsed
        mainMenuBarStatusItemController.updatePresentationMode(
            quickBarIsActive ? menuBarManagement.primaryPresentationMode : .nativeMenuBar
        )
        mainMenuBarStatusItemController.updateQuickBarItems(
            quickBarIsActive ? menuBarManagement.quickBarItems : []
        )
        mainMenuBarStatusItemController.updateChangePresentation(
            menuBarManagement.changePresentation
        )
        mainMenuBarStatusItemController.updateHoverEnabled(
            quickBarIsActive && menuBarManagement.showQuickBarOnHover
        )
        objectWillChange.send()
    }

    /// GIF remains disabled unless a separately approved Capture Extension is
    /// explicitly enabled at launch; it is intentionally not a schema-7
    /// product setting.
    private static var gifCaptureExtensionEnabled: Bool {
        ProcessInfo.processInfo.environment["DISPLAY_MONITOR_ENABLE_GIF_EXTENSION"] == "1"
    }
}
