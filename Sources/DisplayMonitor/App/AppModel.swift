import AppKit
import DisplayMonitorCore
import Foundation
import OSLog

/// Dependencies assembled by ToolSuiteShell. AppModel retains observable
/// product state and narrow monitor commands, but does not decide how the
/// monitor, persistence, panels or platform services are constructed.
@MainActor
struct AppModelDependencies {
    let settingsStore: SettingsStore
    let displayManager: DisplayManager
    let permissionManager: ScreenRecordingPermissionManager
    let pointerManager: PointerManager
    let directControlPermissionManager: DirectControlPermissionManager
    let launchAtLoginManager: LaunchAtLoginManager
    let aboutPanelPresenter: AboutPanelPresenter
    let sampleDisplayCoordinator: SampleBufferDisplayCoordinator
    let captureCoordinator: CaptureCoordinator
    let makePreviewPanelController: @MainActor (AppModel, SampleBufferDisplayCoordinator) -> PreviewPanelController

    static func standard(
        settingsStore: SettingsStore = SettingsStore()
    ) -> AppModelDependencies {
        let sampleDisplayCoordinator = SampleBufferDisplayCoordinator()
        return AppModelDependencies(
            settingsStore: settingsStore,
            displayManager: DisplayManager(),
            permissionManager: ScreenRecordingPermissionManager(),
            pointerManager: PointerManager(),
            directControlPermissionManager: DirectControlPermissionManager(),
            launchAtLoginManager: LaunchAtLoginManager(),
            aboutPanelPresenter: AboutPanelPresenter(),
            sampleDisplayCoordinator: sampleDisplayCoordinator,
            captureCoordinator: CaptureCoordinator(sampleDisplayCoordinator: sampleDisplayCoordinator),
            makePreviewPanelController: { model, coordinator in
                PreviewPanelController(model: model, sampleDisplayCoordinator: coordinator)
            }
        )
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var permissionState: ScreenRecordingPermissionState = .unknown
    @Published private(set) var capturePhase: CapturePhase = .idle
    @Published private(set) var desiredMonitorState: MonitorDesiredState = .off
    @Published private(set) var monitorRuntimeState: MonitorRuntimeState = .idle
    @Published private(set) var previewVisibility: PreviewVisibility = .hidden
    @Published private(set) var lastFrameTime: Date?
    private(set) var completeFrameCount: UInt64 = 0
    @Published private(set) var lastError: CaptureError?
    @Published private(set) var launchAtLoginStatus = "未检查"
    @Published private(set) var shortcutRegistrations: [GlobalShortcutRegistration] = []
    @Published private(set) var inputControlPermission: InputControlPermissionState = .unknown
    @Published private(set) var inputControlStatusMessage: String?
    @Published private(set) var isControlModeEnabled = false
    @Published private(set) var isDirectPointerCaptureActive = false
    @Published var selectedDisplayID: CGDirectDisplayID?

    var onDirectPointerShortcut: (@MainActor (ToolSuiteCommand) -> Void)?
    var onQuitRequested: (@MainActor () -> Void)?

    var persistedShortcutBindings: [String: String] {
        settings.shortcutBindings
    }

    var shortcutBindings: [ShortcutBinding] {
        ShortcutRegistry.bindings(from: settings.shortcutBindings)
    }

    func setShortcutBinding(_ binding: ShortcutBinding) {
        guard shortcutBindings.contains(where: { $0.command == binding.command }) else {
            return
        }
        let persistedValue = ShortcutRegistry.persistedValue(for: binding)
        guard settings.shortcutBindings[binding.command.settingsKey] != persistedValue else {
            return
        }
        settings.shortcutBindings[binding.command.settingsKey] = persistedValue
        settingsStore.save(settings)
        logger.info(
            "shortcut.binding.updated command=\(binding.command.title, privacy: .public) binding=\(binding.keyEquivalent, privacy: .public)"
        )
        objectWillChange.send()
    }

    func restoreDefaultShortcutBindings() {
        guard settings.shortcutBindings != AppSettings.defaultShortcutBindings else {
            return
        }
        settings.shortcutBindings = AppSettings.defaultShortcutBindings
        settingsStore.save(settings)
        logger.info("shortcut.bindings.restoredDefaults")
        objectWillChange.send()
    }

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "App")
    private let settingsStore: SettingsStore
    private let displayManager: DisplayManager
    private let permissionManager: ScreenRecordingPermissionManager
    private let pointerManager: PointerManager
    private let directControlPermissionManager: DirectControlPermissionManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private let aboutPanelPresenter: AboutPanelPresenter
    private let sampleDisplayCoordinator: SampleBufferDisplayCoordinator
    private let captureCoordinator: CaptureCoordinator
    private let makePreviewPanelController: @MainActor (AppModel, SampleBufferDisplayCoordinator) -> PreviewPanelController
    private lazy var previewPanelController = makePreviewPanelController(
        self,
        sampleDisplayCoordinator
    )

    private var settings: AppSettings
    private var didStart = false
    private var generation = 0
    private var displayRefreshTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var displayRefreshRevision = 0
    private var isScreensSleeping = false
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var controlModeDisabledByUserForCurrentPreviewSession = false
    private let showPreviewOnLaunchForValidation: Bool
    private let forceMainDisplaySelectionForValidation: Bool
    private let runAutomationScriptForValidation: Bool

    init(dependencies: AppModelDependencies = .standard()) {
        settingsStore = dependencies.settingsStore
        displayManager = dependencies.displayManager
        permissionManager = dependencies.permissionManager
        pointerManager = dependencies.pointerManager
        directControlPermissionManager = dependencies.directControlPermissionManager
        launchAtLoginManager = dependencies.launchAtLoginManager
        aboutPanelPresenter = dependencies.aboutPanelPresenter
        sampleDisplayCoordinator = dependencies.sampleDisplayCoordinator
        captureCoordinator = dependencies.captureCoordinator
        makePreviewPanelController = dependencies.makePreviewPanelController
        settings = settingsStore.load()
        let arguments = ProcessInfo.processInfo.arguments
        showPreviewOnLaunchForValidation = arguments.contains("--show-preview")
        forceMainDisplaySelectionForValidation = arguments.contains("--select-main-display")
        runAutomationScriptForValidation = arguments.contains("--automation-script")
        if showPreviewOnLaunchForValidation {
            settings.previewIsVisible = true
            settings.preferredPreviewPresentation = .shown
        }
        if arguments.contains("--start-paused") {
            settings.captureIsPaused = true
        }
        selectedDisplayID = settings.lastSessionDisplayID
        previewVisibility = showPreviewOnLaunchForValidation ? Self.previewVisibility(from: settings) : .hidden
        capturePhase = showPreviewOnLaunchForValidation && settings.captureIsPaused ? .paused : .idle
    }

    var frameRate: Int {
        settings.frameRate
    }

    var captureResolution: CaptureResolutionPreset {
        settings.captureResolution
    }

    var previewWindowSize: PreviewWindowSizePreset {
        settings.previewWindowSize
    }

    var previewWindowContentSize: CGSize {
        settings.previewWindowSize.contentSize
    }

    var previewIsPinned: Bool {
        settings.previewIsPinned
    }

    var showsCursor: Bool {
        settings.showsCursor
    }

    var directControlModifier: DirectControlModifier {
        settings.directControlModifier
    }

    var scrollCaptureMode: ScrollCaptureMode {
        settings.scrollCaptureMode
    }

    var artifactShelfAutoPresent: Bool {
        settings.artifactShelfAutoPresent
    }

    var artifactShelfFollowsActiveDisplay: Bool {
        settings.artifactShelfFollowsActiveDisplay
    }

    var artifactShelfRecentLimit: Int {
        settings.artifactShelfRecentLimit
    }

    var artifactShelfMargin: CGFloat {
        CGFloat(settings.artifactShelfMargin)
    }

    var screenshotSaveDirectory: URL {
        ScreenshotOutputLocation.resolvedDirectory(path: settings.screenshotSaveDirectoryPath)
    }

    var screenshotSaveDirectoryName: String {
        let name = screenshotSaveDirectory.lastPathComponent
        return name.isEmpty ? ScreenshotOutputLocation.defaultFolderName : name
    }

    var usesDefaultScreenshotSaveDirectory: Bool {
        settings.screenshotSaveDirectoryPath == nil
    }

    var screenshotTimerDelaySeconds: Int {
        settings.screenshotTimerDelaySeconds
    }

    var lastScreenshotSelection: ScreenshotWorkspaceController.SelectedRegion? {
        guard let displayID = settings.lastScreenshotDisplayID,
              let region = settings.lastScreenshotRegion else {
            return nil
        }
        return ScreenshotWorkspaceController.SelectedRegion(
            displayID: displayID,
            region: region
        )
    }

    var lastScreenshotAnnotationTool: ScreenshotAnnotationTool {
        settings.lastScreenshotAnnotationTool
    }

    var canControlTarget: Bool {
        guard inputControlPermission == .granted else {
            return false
        }
        if case .online = targetState {
            return true
        }
        return false
    }

    var directControlReadyMessage: String {
        "直控已启用：鼠标位于 Monitor 画面内时按住 \(directControlModifier.symbol) 进入，松开返回"
    }

    var snapshot: CaptureSnapshot {
        CaptureSnapshot(
            permission: permissionState,
            target: targetState,
            phase: capturePhase,
            previewVisibility: previewVisibility,
            lastFrameTime: lastFrameTime,
            lastError: lastError
        )
    }

    var targetState: TargetDisplayState {
        guard let selectedDisplayID else {
            if let selectedDisplay = settings.selectedDisplay {
                return .disconnected(selectedDisplay)
            }
            return .noneSelected
        }

        guard let descriptor = displays.first(where: { $0.id == selectedDisplayID }) else {
            if let selectedDisplay = settings.selectedDisplay {
                return .disconnected(selectedDisplay)
            }
            return .noneSelected
        }

        guard descriptor.captureAvailability.isSelectable else {
            return .unsupported(descriptor.captureAvailability.label)
        }
        return .online(descriptor)
    }

    var statusSummary: String {
        if desiredMonitorState == .off {
            return monitorRuntimeState == .idle ? "Monitor OFF · IDLE" : "Monitor OFF · \(monitorRuntimeState.label)"
        }

        switch permissionState {
        case .unknown, .checking:
            return "正在检查权限"
        case .notGranted:
            return "需要屏幕录制权限"
        case .revoked:
            return "屏幕录制权限已失效"
        case .granted:
            break
        }

        switch targetState {
        case .noneSelected:
            return "未连接可监看的扩展显示器"
        case .disconnected:
            return "目标显示器已断开"
        case .ambiguous:
            return "目标显示器无法唯一识别"
        case .unsupported(let reason):
            return reason
        case .online:
            break
        }

        switch capturePhase {
        case .idle:
            return "待采集"
        case .starting:
            return "正在启动采集"
        case .capturing:
            return "正在监看"
        case .pausing, .paused:
            return "已暂停"
        case .stopping:
            return "正在停止采集"
        case .retrying(let attempt):
            return "正在重试 \(attempt)/3"
        case .failed(let error):
            return error.message
        }
    }

    var menuSymbolName: String {
        switch capturePhase {
        case .capturing:
            return "display.and.arrow.down"
        case .failed:
            return "exclamationmark.triangle"
        case .paused:
            return "pause.rectangle"
        default:
            return "display"
        }
    }

    func startIfNeeded() async {
        guard !didStart, !isShuttingDown else {
            return
        }
        logger.info("app.start frameRate=\(self.settings.frameRate, privacy: .public) captureResolution=\(self.settings.captureResolution.label, privacy: .public) previewWindowSize=\(self.settings.previewWindowSize.label, privacy: .public) previewVisible=\(self.settings.previewIsVisible, privacy: .public) collapsed=\(self.settings.previewIsCollapsed, privacy: .public) paused=\(self.settings.captureIsPaused, privacy: .public)")
        didStart = true
        installObservers()
        refreshInputControlPermission()
        launchAtLoginStatus = launchAtLoginManager.statusText()
        await recheckPermission(restartCapture: false)
        guard !isShuttingDown else { return }
        await refreshDisplays()
        guard !isShuttingDown else { return }
        restoreOrChooseDisplay()

        // ToolSuite startup is intentionally idle. A persisted preview
        // preference is only restored after an explicit user/validation
        // request; it must never start a stream or create a panel implicitly.
        guard showPreviewOnLaunchForValidation else {
            logger.info("monitor.startup.idle")
            previewVisibility = .hidden
            capturePhase = .idle
            desiredMonitorState = .off
            monitorRuntimeState = .idle
            return
        }

        await turnMonitorOn()

        if runAutomationScriptForValidation {
            runAutomationScript()
        }
    }

    func toggleMonitor() async {
        guard !isShuttingDown else { return }
        switch desiredMonitorState {
        case .off:
            await turnMonitorOn()
        case .on:
            await turnMonitorOff()
        }
    }

    private func turnMonitorOn() async {
        guard !isShuttingDown else { return }
        logger.info("monitor.toggle.requested desired=on")
        desiredMonitorState = .on
        monitorRuntimeState = .starting

        switch settings.preferredPreviewPresentation {
        case .shown:
            showPreview(restartCaptureForSelfExclusion: false)
        case .collapsed:
            collapsePreview(restartCaptureForSelfExclusion: false)
        case .hidden:
            previewVisibility = .hidden
            previewPanelController.hide()
        }

        if permissionState == .unknown || permissionState == .checking {
            await recheckPermission(restartCapture: false)
        }
        guard permissionState == .granted else {
            monitorRuntimeState = .failed(
                CaptureError(
                    code: "screen_recording_permission_required",
                    message: "需要屏幕录制权限"
                )
            )
            return
        }
        if !displays.contains(where: { $0.captureAvailability.isSelectable }) {
            await refreshDisplays()
            restoreOrChooseDisplay()
        }
        guard case .online = targetState else {
            monitorRuntimeState = .suspended("目标显示器不可用")
            return
        }
        if settings.captureIsPaused {
            capturePhase = .paused
            monitorRuntimeState = .paused
            return
        }
        await restartCaptureIfPossible()
    }

    private func turnMonitorOff() async {
        logger.info("monitor.toggle.requested desired=off")
        desiredMonitorState = .off
        monitorRuntimeState = .stopping
        disableControlMode(reason: "monitor.off", restartCapture: false)
        generation += 1
        let operation = generation
        previewPanelController.hide()
        previewVisibility = .hidden
        settings.previewIsVisible = false
        settings.previewIsCollapsed = false
        settingsStore.save(settings)
        guard await stopCaptureAndReportFailure(operation: operation) else { return }
        capturePhase = .idle
        monitorRuntimeState = .idle
    }

    func showPreview() {
        guard desiredMonitorState == .on else {
            Task { @MainActor in
                await toggleMonitor()
            }
            return
        }
        showPreview(restartCaptureForSelfExclusion: true)
    }

    func expandPreview() {
        guard desiredMonitorState == .on else {
            Task { @MainActor in
                await toggleMonitor()
            }
            return
        }
        showPreview(restartCaptureForSelfExclusion: true)
    }

    private func showPreview(restartCaptureForSelfExclusion: Bool) {
        guard !isShuttingDown else { return }
        logger.info("preview.show")
        controlModeDisabledByUserForCurrentPreviewSession = false
        previewVisibility = .shown
        settings.previewIsVisible = true
        settings.previewIsCollapsed = false
        settings.preferredPreviewPresentation = .shown
        settingsStore.save(settings)
        previewPanelController.show(restoredFrame: settings.previewContentFrame)
        autoEnableControlModeIfNeeded(
            reason: "preview.shown",
            restartCapture: false
        )
        if restartCaptureForSelfExclusion,
           permissionState == .granted,
           !settings.captureIsPaused {
            Task { @MainActor in
                await restartCaptureIfPossible()
            }
        }
    }

    func collapsePreview() {
        collapsePreview(restartCaptureForSelfExclusion: true)
    }

    private func collapsePreview(restartCaptureForSelfExclusion: Bool) {
        guard !isShuttingDown else { return }
        logger.info("preview.collapse")
        disableControlMode(reason: "preview.collapsed", restartCapture: false)
        previewVisibility = .collapsed
        settings.previewIsVisible = true
        settings.previewIsCollapsed = true
        settings.preferredPreviewPresentation = .collapsed
        settingsStore.save(settings)
        previewPanelController.showCollapsed(restoredFrame: settings.collapsedIconFrame)
        if restartCaptureForSelfExclusion,
           permissionState == .granted,
           !settings.captureIsPaused {
            Task { @MainActor in
                await restartCaptureIfPossible()
            }
        }
    }

    func hidePreview() {
        logger.info("preview.hide")
        disableControlMode(reason: "preview.hidden")
        previewVisibility = .hidden
        settings.previewIsVisible = false
        settings.previewIsCollapsed = false
        settings.preferredPreviewPresentation = .hidden
        settingsStore.save(settings)
        previewPanelController.hide()
    }

    func resetPreviewWindow() {
        logger.info("preview.resetFrame")
        if previewVisibility == .collapsed {
            previewPanelController.resetCollapsedFrame()
        } else {
            previewPanelController.resetFrame()
        }
    }

    func previewPanelDidClose() {
        logger.info("preview.closeButton")
        collapsePreview()
    }

    func previewPanelFrameDidChange(_ frame: CGRect) {
        settings.previewContentFrame = frame
        settingsStore.save(settings)
    }

    func collapsedIconFrameDidChange(_ frame: CGRect) {
        settings.collapsedIconFrame = frame
        settingsStore.save(settings)
    }

    func selectDisplay(_ descriptor: DisplayDescriptor) async {
        guard descriptor.captureAvailability.isSelectable else {
            logger.info("display.selectRejected displayID=\(descriptor.id, privacy: .public) availability=\(descriptor.captureAvailability.label, privacy: .public)")
            lastError = CaptureError(code: "display_not_selectable", message: descriptor.captureAvailability.label)
            return
        }
        logger.info("display.select displayID=\(descriptor.id, privacy: .public) primary=\(descriptor.isPrimary, privacy: .public) availability=\(descriptor.captureAvailability.label, privacy: .public)")
        disableControlMode(reason: "display.changed", restartCapture: false)
        selectedDisplayID = descriptor.id
        settings.selectedDisplay = descriptor.persistentIdentity
        settings.lastSessionDisplayID = descriptor.id
        settingsStore.save(settings)
        autoEnableControlModeIfNeeded(
            reason: "display.changed",
            restartCapture: false
        )
        await restartCaptureIfPossible()
    }

    func setFrameRate(_ frameRate: Int) async {
        guard [5, 10, 15, 30].contains(frameRate), settings.frameRate != frameRate else {
            return
        }
        logger.info("capture.setFrameRate \(frameRate, privacy: .public)")
        settings.frameRate = frameRate
        settingsStore.save(settings)
        await restartCaptureIfPossible()
    }

    func setCaptureResolution(_ captureResolution: CaptureResolutionPreset) async {
        guard CaptureResolutionPreset.selectableCases.contains(captureResolution),
              settings.captureResolution != captureResolution else {
            return
        }
        logger.info("capture.setResolution \(captureResolution.label, privacy: .public)")
        settings.captureResolution = captureResolution
        settingsStore.save(settings)
        await restartCaptureIfPossible()
    }

    func setPreviewWindowSize(_ previewWindowSize: PreviewWindowSizePreset) {
        guard PreviewWindowSizePreset.selectableCases.contains(previewWindowSize),
              settings.previewWindowSize != previewWindowSize else {
            return
        }
        logger.info("preview.setWindowSize \(previewWindowSize.label, privacy: .public)")
        objectWillChange.send()
        settings.previewWindowSize = previewWindowSize
        settingsStore.save(settings)
        if previewVisibility == .shown {
            previewPanelController.resizePreview(to: previewWindowSize.contentSize)
        }
    }

    func setPreviewPinned(_ isPinned: Bool) {
        guard !isShuttingDown, settings.previewIsPinned != isPinned else { return }
        logger.info("preview.setPinned \(isPinned, privacy: .public)")
        objectWillChange.send()
        settings.previewIsPinned = isPinned
        settingsStore.save(settings)
        previewPanelController.updatePinning()
    }

    func setShowsCursor(_ showsCursor: Bool) async {
        guard settings.showsCursor != showsCursor else {
            return
        }
        logger.info("capture.setShowsCursor \(showsCursor, privacy: .public)")
        settings.showsCursor = showsCursor
        settingsStore.save(settings)
        await restartCaptureIfPossible()
    }

    func setDirectControlModifier(_ modifier: DirectControlModifier) {
        guard settings.directControlModifier != modifier else {
            return
        }
        logger.info("directControl.setModifier modifier=\(modifier.rawValue, privacy: .public)")
        objectWillChange.send()
        settings.directControlModifier = modifier
        inputControlStatusMessage = isControlModeEnabled
            ? directControlReadyMessage
            : nil
        settingsStore.save(settings)
    }

    func setScrollCaptureMode(_ mode: ScrollCaptureMode) {
        guard settings.scrollCaptureMode != mode else { return }
        settings.scrollCaptureMode = mode
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func setArtifactShelfAutoPresent(_ enabled: Bool) {
        guard settings.artifactShelfAutoPresent != enabled else { return }
        settings.artifactShelfAutoPresent = enabled
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func setArtifactShelfFollowsActiveDisplay(_ enabled: Bool) {
        guard settings.artifactShelfFollowsActiveDisplay != enabled else { return }
        settings.artifactShelfFollowsActiveDisplay = enabled
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func setScreenshotSaveDirectory(_ directory: URL) {
        let normalizedDirectory = directory.standardizedFileURL
        guard normalizedDirectory.isFileURL else { return }
        let path = normalizedDirectory.path
        guard settings.screenshotSaveDirectoryPath != path else { return }
        settings.screenshotSaveDirectoryPath = path
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func resetScreenshotSaveDirectory() {
        guard settings.screenshotSaveDirectoryPath != nil else { return }
        settings.screenshotSaveDirectoryPath = nil
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func setScreenshotTimerDelaySeconds(_ seconds: Int) {
        guard [3, 5, 10].contains(seconds),
              settings.screenshotTimerDelaySeconds != seconds else { return }
        settings.screenshotTimerDelaySeconds = seconds
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func rememberScreenshotSelection(_ selection: ScreenshotWorkspaceController.SelectedRegion) {
        guard settings.lastScreenshotDisplayID != selection.displayID
                || settings.lastScreenshotRegion != selection.region else { return }
        settings.lastScreenshotDisplayID = selection.displayID
        settings.lastScreenshotRegion = selection.region
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func setLastScreenshotAnnotationTool(_ tool: ScreenshotAnnotationTool) {
        // Selection and crop are document operations, not reusable annotation
        // brushes. Keep the most recent actual annotation tool as the default.
        guard tool != .select,
              tool != .crop,
              settings.lastScreenshotAnnotationTool != tool else { return }
        settings.lastScreenshotAnnotationTool = tool
        settingsStore.save(settings)
        objectWillChange.send()
    }

    func togglePause() async {
        guard !isShuttingDown, desiredMonitorState == .on else {
            logger.info("capture.pause.ignored monitorOff")
            return
        }
        if settings.captureIsPaused {
            logger.info("capture.resume.requested")
            settings.captureIsPaused = false
            settingsStore.save(settings)
            monitorRuntimeState = .starting
            await restartCaptureIfPossible()
        } else {
            logger.info("capture.pause.requested")
            settings.captureIsPaused = true
            settingsStore.save(settings)
            generation += 1
            let operation = generation
            capturePhase = .pausing
            monitorRuntimeState = .stopping
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            capturePhase = .paused
            monitorRuntimeState = .paused
        }
    }

    func retryCapture() async {
        logger.info("capture.retry.requested")
        settings.captureIsPaused = false
        settingsStore.save(settings)
        await recheckPermission(restartCapture: false)
        await refreshDisplays()
        if desiredMonitorState == .on {
            await restartCaptureIfPossible()
        }
    }

    func refreshDisplaysForUserAction() async {
        logger.info("display.refresh.requested reason=userAction")
        await refreshDisplays()
        restoreOrChooseDisplay()
    }

    func recheckPermission(restartCapture: Bool = true) async {
        guard !isShuttingDown else { return }
        logger.info("permission.recheck restartCapture=\(restartCapture, privacy: .public)")
        refreshInputControlPermission()
        permissionState = .checking
        let granted = permissionManager.preflight()
        permissionState = PermissionStateResolver.resolve(
            preflightGranted: granted,
            previouslyObservedGrant: settings.permissionGrantPreviouslyObserved
        )
        logger.info("permission.state granted=\(granted, privacy: .public) previouslyObserved=\(self.settings.permissionGrantPreviouslyObserved, privacy: .public)")
        if granted {
            settings.permissionGrantPreviouslyObserved = true
            settingsStore.save(settings)
        } else {
            generation += 1
            let operation = generation
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            if capturePhase != .paused {
                capturePhase = .idle
            }
            if desiredMonitorState == .on {
                monitorRuntimeState = .failed(
                    CaptureError(
                        code: "screen_recording_permission_required",
                        message: "需要屏幕录制权限"
                    )
                )
            } else {
                monitorRuntimeState = .idle
            }
        }
        if restartCapture {
            await restartCaptureIfPossible()
        }
    }

    func movePointerToTargetDisplay() {
        guard let selectedDisplayID else {
            return
        }
        logger.info("pointer.moveToTarget displayID=\(selectedDisplayID, privacy: .public)")
        pointerManager.moveMouse(toCenterOf: selectedDisplayID)
    }

    func movePointerToMainDisplay() {
        logger.info("pointer.moveToMain")
        pointerManager.moveMouse(toCenterOf: CGMainDisplayID())
    }

    func toggleControlMode() {
        if isControlModeEnabled {
            controlModeDisabledByUserForCurrentPreviewSession = true
            disableControlMode(reason: "user.disabled")
            return
        }

        controlModeDisabledByUserForCurrentPreviewSession = false
        let state = updateInputControlPermissionState()
        guard state == .granted else {
            logger.info("controlMode.enableBlocked permission=\(self.inputControlPermission.label, privacy: .public)")
            lastError = CaptureError(
                code: "input_control_permission_required",
                message: "需要辅助功能权限",
                detail: "授权后返回 Display Monitor，并再次点击“操作”"
            )
            inputControlStatusMessage = "授权后返回 Display Monitor，并再次点击“操作”"
            directControlPermissionManager.openSettings()
            return
        }
        guard case .online = targetState else {
            logger.info("controlMode.enableBlocked targetUnavailable")
            lastError = CaptureError(code: "control_target_unavailable", message: "请先选择可采集的目标显示器")
            return
        }

        enableControlMode(reason: "user.enabled", restartCapture: true)
    }

    func refreshInputControlPermission() {
        let state = updateInputControlPermissionState()
        if state != .granted {
            disableControlMode(reason: "permission.unavailable")
            return
        }
        autoEnableControlModeIfNeeded(
            reason: "permission.available",
            restartCapture: true,
            refreshPermission: false
        )
        if !isControlModeEnabled {
            inputControlStatusMessage = nil
        }
    }

    func handleDirectPointerCaptureChanged(_ isActive: Bool) {
        isDirectPointerCaptureActive = isActive
        if isActive {
            inputControlStatusMessage = "直控中：目标鼠标已显示，松开 \(directControlModifier.symbol) 返回"
        } else {
            inputControlStatusMessage = isControlModeEnabled
                ? directControlReadyMessage
                : nil
        }
        logger.info("controlMode.directCapture active=\(isActive, privacy: .public)")
    }

    func handleDirectPointerCaptureFailure(_ message: String) {
        isDirectPointerCaptureActive = false
        inputControlStatusMessage = message
        logger.info("controlMode.directCaptureRejected message=\(message, privacy: .public)")
    }

    func handleDirectPointerShortcut(_ command: ToolSuiteCommand) {
        logger.info("controlMode.directCaptureShortcut command=\(command.title, privacy: .public)")
        onDirectPointerShortcut?(command)
    }

    func setInputModeSuspended(_ suspended: Bool) {
        if suspended {
            disableControlMode(reason: "input.lease", restartCapture: false)
            return
        }
        guard !isShuttingDown, !isScreensSleeping, desiredMonitorState == .on else {
            return
        }
        autoEnableControlModeIfNeeded(
            reason: "input.lease.released",
            restartCapture: false
        )
    }

    func updateShortcutRegistrations(_ registrations: [GlobalShortcutRegistration]) {
        guard shortcutRegistrations != registrations else {
            return
        }
        shortcutRegistrations = registrations
        let registeredCount = registrations.filter(\.isRegistered).count
        logger.info("shortcut.registered count=\(registeredCount, privacy: .public) total=\(registrations.count, privacy: .public)")
    }

    func toggleLaunchAtLogin() {
        logger.info("launchAtLogin.toggle")
        do {
            try launchAtLoginManager.toggle()
            launchAtLoginStatus = launchAtLoginManager.statusText()
        } catch {
            lastError = CaptureError(
                code: "launch_at_login_failed",
                message: "开机启动设置失败",
                detail: String(describing: error)
            )
            launchAtLoginStatus = launchAtLoginManager.statusText()
        }
    }

    func showAbout() {
        logger.info("about.show")
        aboutPanelPresenter.show()
    }

    private func disableControlMode(reason: String, restartCapture: Bool = true) {
        guard isControlModeEnabled else {
            return
        }
        logger.info("controlMode.disabled reason=\(reason, privacy: .public)")
        isControlModeEnabled = false
        isDirectPointerCaptureActive = false
        if restartCapture,
           permissionState == .granted,
           !settings.captureIsPaused {
            Task { @MainActor in
                await restartCaptureIfPossible()
            }
        }
    }

    private func updateInputControlPermissionState() -> InputControlPermissionState {
        let state = directControlPermissionManager.permissionState()
        inputControlPermission = state
        return state
    }

    private func autoEnableControlModeIfNeeded(
        reason: String,
        restartCapture: Bool,
        refreshPermission: Bool = true
    ) {
        guard !isShuttingDown, !isScreensSleeping, !isControlModeEnabled else {
            return
        }
        if refreshPermission {
            _ = updateInputControlPermissionState()
        }
        let hasOnlineTarget: Bool
        if case .online = targetState {
            hasOnlineTarget = true
        } else {
            hasOnlineTarget = false
        }
        guard DirectControlActivationPolicy.shouldAutoEnable(
            previewVisibility: previewVisibility,
            hasAccessibilityPermission: inputControlPermission == .granted,
            hasOnlineTarget: hasOnlineTarget,
            userDisabledForCurrentPreviewSession: controlModeDisabledByUserForCurrentPreviewSession
        ) else {
            logger.info(
                "controlMode.autoEnableSkipped reason=\(reason, privacy: .public) permission=\(self.inputControlPermission.label, privacy: .public) targetOnline=\(hasOnlineTarget, privacy: .public) userDisabled=\(self.controlModeDisabledByUserForCurrentPreviewSession, privacy: .public)"
            )
            return
        }
        enableControlMode(reason: reason, restartCapture: restartCapture)
    }

    private func enableControlMode(reason: String, restartCapture: Bool) {
        guard !isShuttingDown, !isScreensSleeping, !isControlModeEnabled else {
            return
        }
        logger.info(
            "controlMode.enabled mode=directPointer reason=\(reason, privacy: .public) modifier=\(self.directControlModifier.rawValue, privacy: .public)"
        )
        if lastError?.code == "input_control_permission_required" {
            lastError = nil
        }
        inputControlStatusMessage = directControlReadyMessage
        isControlModeEnabled = true
        if restartCapture {
            Task { @MainActor in
                await restartCaptureIfPossible()
            }
        }
    }

    func quit() {
        logger.info("app.quit.requested")
        if let onQuitRequested {
            onQuitRequested()
        } else {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func shutdownForShell() async {
        await shutdown()
    }

    private func runAutomationScript() {
        Task { @MainActor in
            await runAutomationScriptSteps()
        }
    }

    private func runAutomationScriptSteps() async {
        logger.info("automation.start")
        await waitForAutomationCaptureReadiness()

        logger.info("automation.step collapsePreview")
        collapsePreview()
        await automationDelay(seconds: 0.8)

        logger.info("automation.step expandPreview")
        expandPreview()
        await automationDelay(seconds: 2.0)

        logger.info("automation.step hidePreview")
        hidePreview()
        await automationDelay(seconds: 0.4)

        logger.info("automation.step showPreview")
        showPreview()
        await automationDelay(seconds: 2.0)

        logger.info("automation.step pause")
        if !settings.captureIsPaused {
            await togglePause()
        }
        await automationDelay(seconds: 0.5)

        logger.info("automation.step resume")
        if settings.captureIsPaused {
            await togglePause()
        }
        await automationDelay(seconds: 2.0)

        logger.info("automation.step movePointerToTarget")
        movePointerToTargetDisplay()
        await automationDelay(seconds: 0.2)

        logger.info("automation.step movePointerToMain")
        movePointerToMainDisplay()

        logger.info("automation.completed phase=\(self.statusSummary, privacy: .public)")
    }

    private func waitForAutomationCaptureReadiness() async {
        for _ in 0..<20 {
            if case .capturing = capturePhase {
                logger.info("automation.captureReady")
                return
            }
            if case .failed(let error) = capturePhase {
                logger.error("automation.captureFailed code=\(error.code, privacy: .public)")
                return
            }
            await automationDelay(seconds: 0.25)
        }
        logger.error("automation.captureNotReady phase=\(self.statusSummary, privacy: .public)")
    }

    private func automationDelay(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func refreshDisplays() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        let revision = displayRefreshRevision
        let refreshedDisplays = await displayManager.refreshDisplays()
        guard !isShuttingDown, !Task.isCancelled, revision == displayRefreshRevision else { return }
        displays = refreshedDisplays
        let selectableCount = displays.filter { $0.captureAvailability.isSelectable }.count
        logger.info("display.refresh count=\(self.displays.count, privacy: .public) selectable=\(selectableCount, privacy: .public)")
        if isControlModeEnabled, !canControlTarget {
            disableControlMode(reason: "display.unavailable", restartCapture: false)
        }
    }

    private func restoreOrChooseDisplay() {
        if forceMainDisplaySelectionForValidation,
           let mainDisplay = displays.first(where: { $0.id == CGMainDisplayID() && $0.captureAvailability.isSelectable }) {
            logger.info("display.validationMainSelected displayID=\(mainDisplay.id, privacy: .public)")
            selectedDisplayID = mainDisplay.id
            return
        }

        if let selectedDisplay = settings.selectedDisplay {
            switch DisplayIdentityMatcher.match(
                lastSessionDisplayID: settings.lastSessionDisplayID,
                identity: selectedDisplay,
                candidates: displays
            ) {
            case .matched(let descriptor):
                logger.info("display.restore.matched displayID=\(descriptor.id, privacy: .public)")
                selectedDisplayID = descriptor.id
                return
            case .ambiguous:
                logger.info("display.restore.ambiguous")
                selectedDisplayID = nil
                lastError = CaptureError(code: "display_ambiguous", message: "目标显示器无法唯一识别")
                return
            case .disconnected:
                logger.info("display.restore.disconnected")
                selectedDisplayID = nil
                return
            }
        }

        let defaultTarget = displays.first {
            !$0.isPrimary && $0.isOnline && $0.captureAvailability.isSelectable
        }
        if let defaultTarget {
            logger.info("display.defaultSelected displayID=\(defaultTarget.id, privacy: .public)")
            selectedDisplayID = defaultTarget.id
            settings.selectedDisplay = defaultTarget.persistentIdentity
            settings.lastSessionDisplayID = defaultTarget.id
            settingsStore.save(settings)
        }
    }

    private func stopCaptureAndReportFailure(operation: Int) async -> Bool {
        let stopError = await captureCoordinator.stop()
        guard operation == generation, !isShuttingDown, !isScreensSleeping else { return false }
        guard let stopError else { return true }
        lastError = stopError
        capturePhase = .failed(stopError)
        monitorRuntimeState = .failed(stopError)
        return false
    }

    private func restartCaptureIfPossible() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        guard !isScreensSleeping else {
            logger.info("capture.start.skipped screensSleeping")
            return
        }
        guard desiredMonitorState == .on else {
            logger.info("capture.start.skipped monitorOff")
            generation += 1
            let operation = generation
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            capturePhase = .idle
            monitorRuntimeState = .idle
            return
        }
        guard permissionState == .granted else {
            logger.info("capture.start.skipped permissionNotGranted")
            generation += 1
            let operation = generation
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            monitorRuntimeState = .failed(
                CaptureError(
                    code: "screen_recording_permission_required",
                    message: "需要屏幕录制权限"
                )
            )
            return
        }
        guard !settings.captureIsPaused else {
            logger.info("capture.start.skipped userPaused")
            generation += 1
            let operation = generation
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            capturePhase = .paused
            monitorRuntimeState = .paused
            return
        }
        guard case .online(let descriptor) = targetState else {
            logger.info("capture.start.skipped noOnlineTarget")
            generation += 1
            let operation = generation
            guard await stopCaptureAndReportFailure(operation: operation) else { return }
            capturePhase = .idle
            monitorRuntimeState = .suspended("目标显示器不可用")
            return
        }

        generation += 1
        let operation = generation
        let effectiveShowsCursor = settings.showsCursor || isControlModeEnabled
        capturePhase = .starting
        lastError = nil
        logger.info("capture.start.requested generation=\(operation, privacy: .public) displayID=\(descriptor.id, privacy: .public) frameRate=\(self.settings.frameRate, privacy: .public) showsCursor=\(effectiveShowsCursor, privacy: .public)")

        var finalError: CaptureError?
        for attempt in 1...CaptureRetryPolicy.maximumAttempts {
            if attempt > 1 {
                capturePhase = .retrying(attempt: attempt)
            }
            do {
            try await captureCoordinator.start(
                display: descriptor,
                frameRate: settings.frameRate,
                captureResolution: settings.captureResolution,
                showsCursor: effectiveShowsCursor,
                generation: operation,
                onFrame: { [weak self] frameGeneration, date, frameCount in
                    self?.handleFrame(generation: frameGeneration, date: date, frameCount: frameCount)
                },
                onError: { [weak self] frameGeneration, error in
                    self?.handleCaptureError(generation: frameGeneration, error: error)
                }
            )
            guard operation == generation, !isShuttingDown, !isScreensSleeping, !Task.isCancelled else {
                return
            }
            capturePhase = .capturing
            markSelectedDisplayAvailability(.available)
            logger.info("capture.start.succeeded generation=\(operation, privacy: .public) attempt=\(attempt, privacy: .public)")
            if !forceMainDisplaySelectionForValidation {
                settings.selectedDisplay = descriptor.persistentIdentity
                settings.lastSessionDisplayID = descriptor.id
                settingsStore.save(settings)
            }
            return
        } catch is CancellationError {
            return
        } catch let captureError as CaptureError {
            guard operation == generation, !isShuttingDown, !isScreensSleeping, !Task.isCancelled else {
                return
            }
            finalError = captureError
            logger.error("capture.start.failed generation=\(operation, privacy: .public) attempt=\(attempt, privacy: .public) code=\(captureError.code, privacy: .public) detail=\(captureError.detail ?? "", privacy: .public)")
            if CaptureRetryPolicy.shouldRetry(captureError, attempt: attempt),
               let delay = CaptureRetryPolicy.delaySeconds(forAttempt: attempt) {
                capturePhase = .retrying(attempt: attempt)
                logger.info("capture.retry.scheduled generation=\(operation, privacy: .public) attempt=\(attempt + 1, privacy: .public) delay=\(delay, privacy: .public)")
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard operation == generation, !isShuttingDown, !isScreensSleeping else {
                    return
                }
                continue
            }
            break
        } catch {
            guard operation == generation, !isShuttingDown, !isScreensSleeping, !Task.isCancelled else {
                return
            }
            let captureError = CaptureError(
                code: "stream_start_failed",
                message: "采集启动失败",
                detail: String(describing: error)
            )
            finalError = captureError
            logger.error("capture.start.failed generation=\(operation, privacy: .public) attempt=\(attempt, privacy: .public) code=\(captureError.code, privacy: .public) detail=\(captureError.detail ?? "", privacy: .public)")
            if CaptureRetryPolicy.shouldRetry(captureError, attempt: attempt),
               let delay = CaptureRetryPolicy.delaySeconds(forAttempt: attempt) {
                capturePhase = .retrying(attempt: attempt)
                logger.info("capture.retry.scheduled generation=\(operation, privacy: .public) attempt=\(attempt + 1, privacy: .public) delay=\(delay, privacy: .public)")
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard operation == generation, !isShuttingDown, !isScreensSleeping else {
                    return
                }
                continue
            }
            break
            }
        }

        let captureError = finalError ?? CaptureError(code: "stream_start_failed", message: "采集启动失败")
        lastError = captureError
        markSelectedDisplayAvailability(.captureFailed(captureError))
        capturePhase = .failed(captureError)
        monitorRuntimeState = .failed(captureError)
        logger.error("capture.start.exhausted generation=\(operation, privacy: .public) code=\(captureError.code, privacy: .public)")
        }

    private func handleFrame(generation frameGeneration: Int, date: Date, frameCount: Int) {
        guard frameGeneration == generation, !isShuttingDown, !isScreensSleeping else {
            return
        }
        lastFrameTime = date
        completeFrameCount &+= UInt64(frameCount)
        if case .starting = capturePhase {
            capturePhase = .capturing
        }
        if desiredMonitorState == .on {
            monitorRuntimeState = .running
        }
        if let selectedDisplayID,
           let index = displays.firstIndex(where: { $0.id == selectedDisplayID }) {
            displays[index].captureAvailability = .available
        }
    }

    private func handleCaptureError(generation frameGeneration: Int, error: CaptureError) {
        guard frameGeneration == generation, !isShuttingDown, !isScreensSleeping else {
            return
        }
        lastError = error
        markSelectedDisplayAvailability(.captureFailed(error))
        capturePhase = .failed(error)
        monitorRuntimeState = .failed(error)
        logger.error("capture.runtime.failed generation=\(frameGeneration, privacy: .public) code=\(error.code, privacy: .public)")
    }

    private func markSelectedDisplayAvailability(_ availability: DisplayCaptureAvailability) {
        guard let selectedDisplayID,
              let index = displays.firstIndex(where: { $0.id == selectedDisplayID }) else {
            return
        }
        displays[index].captureAvailability = availability
    }

    private func installObservers() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDisplayRefresh()
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleScreensDidSleep()
                }
            }
        )
        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleScreensDidWake()
                }
            }
        )
    }

    private func scheduleDisplayRefresh() {
        guard !isShuttingDown, !isScreensSleeping else { return }
        logger.info("display.refresh.scheduled")
        displayRefreshTask?.cancel()
        displayRefreshRevision &+= 1
        let revision = displayRefreshRevision
        displayRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard let self, !self.isShuttingDown, !self.isScreensSleeping,
                  self.displayRefreshRevision == revision else {
                return
            }
            await self.refreshDisplays()
            guard !Task.isCancelled, !self.isShuttingDown, !self.isScreensSleeping,
                  self.displayRefreshRevision == revision else { return }
            self.restoreOrChooseDisplay()
            self.autoEnableControlModeIfNeeded(
                reason: "display.refreshed",
                restartCapture: false
            )
            await self.restartCaptureIfPossible()
        }
    }

    private func handleScreensDidSleep() async {
        guard !isShuttingDown else { return }
        logger.info("sleep.willStopCapture")
        isScreensSleeping = true
        wakeTask?.cancel()
        wakeTask = nil
        displayRefreshRevision &+= 1
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        disableControlMode(reason: "screens.sleep", restartCapture: false)
        generation += 1
        let operation = generation
        await captureCoordinator.stop()
        guard !isShuttingDown, isScreensSleeping, operation == generation else { return }
        if settings.captureIsPaused {
            capturePhase = .paused
        } else {
            capturePhase = .idle
        }
        if desiredMonitorState == .on {
            monitorRuntimeState = .suspended("sleep")
        } else {
            monitorRuntimeState = .idle
        }
    }

    private func handleScreensDidWake() async {
        guard !isShuttingDown else { return }
        logger.info("wake.recheck")
        wakeTask?.cancel()
        displayRefreshTask?.cancel()
        displayRefreshRevision &+= 1
        let revision = displayRefreshRevision
        isScreensSleeping = true
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard let self, !self.isShuttingDown,
                  self.displayRefreshRevision == revision else { return }
            await self.recheckPermission(restartCapture: false)
            guard !Task.isCancelled, !self.isShuttingDown,
                  self.displayRefreshRevision == revision else { return }
            await self.refreshDisplays()
            guard !Task.isCancelled, !self.isShuttingDown,
                  self.displayRefreshRevision == revision else { return }
            self.isScreensSleeping = false
            self.restoreOrChooseDisplay()
            self.autoEnableControlModeIfNeeded(reason: "screens.woke", restartCapture: false)
            if self.desiredMonitorState == .on {
                await self.restartCaptureIfPossible()
            }
        }
        wakeTask = task
        await task.value
    }

    func beginTermination() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        desiredMonitorState = .off
        logger.info("app.shutdown.begin")
        displayRefreshRevision &+= 1
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        disableControlMode(reason: "app.shutdown", restartCapture: false)
        previewPanelController.shutdown()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        generation += 1
    }

    private func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        beginTermination()
        let task = Task { @MainActor [self] in
            await captureCoordinator.stop()
            sampleDisplayCoordinator.flush()
            settingsStore.save(settings)
            desiredMonitorState = .off
            capturePhase = .idle
            monitorRuntimeState = .idle
        }
        shutdownTask = task
        await task.value
    }

    private static func previewVisibility(from settings: AppSettings) -> PreviewVisibility {
        guard settings.previewIsVisible else {
            return .hidden
        }
        return settings.previewIsCollapsed ? .collapsed : .shown
    }
}
