import AppKit
import ApplicationServices
import Combine
import DisplayMonitorCore
import Foundation
import MenuBarVisibilityBridge
import OSLog

private struct PendingTemporaryRevealResolution {
    var keepExpanded = false
    var shouldRecollapse = false
    var recollapseDelay: Duration?

    mutating func merge(
        shouldRecollapse: Bool,
        keepExpanded: Bool,
        delay: Duration
    ) {
        self.keepExpanded = self.keepExpanded || keepExpanded
        guard shouldRecollapse else { return }
        self.shouldRecollapse = true
        if let recollapseDelay {
            self.recollapseDelay = max(recollapseDelay, delay)
        } else {
            recollapseDelay = delay
        }
    }
}

@MainActor
final class MenuBarManagementCoordinator: ObservableObject {
    nonisolated static let anchorAccessibilityIdentifier =
        "com.hanshuai.DisplayMonitor.menuBar.anchor"
    nonisolated static let anchorIdentity = MenuBarAnchorIdentity(
        bundleIdentifier: AppConstants.bundleIdentifier,
        title: AppConstants.appName,
        accessibilityIdentifier: anchorAccessibilityIdentifier
    )

    @Published private(set) var inventory: AnchoredMenuBarInventory?
    @Published private(set) var selectedDisplayID: UInt32 = 0
    @Published private(set) var draftIDs: [String] = []
    @Published private(set) var permissionStatus = MenuBarControlPermissionStatus(
        accessibilityGranted: false,
        eventPostingGranted: false
    )
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isReading = false
    @Published private(set) var isApplying = false
    @Published private(set) var hasRecovery = false
    @Published private(set) var isPreparingCollapse = false
    @Published private(set) var isCollapsed = false
    /// The user's durable resting-state preference. `isCollapsed` remains the
    /// observed state of the current native assertion.
    @Published private(set) var wantsPersistentCollapse: Bool
    /// Last explicit show/hide choice. This is intentionally separate from the
    /// durable preference and from scanning/preparing/native execution phases.
    @Published private(set) var userVisibilityIntent: MenuBarUserVisibilityIntent
    /// Controls what a primary click on the Display Monitor status item shows.
    @Published private(set) var primaryPresentationMode: MenuBarPrimaryPresentationMode
    @Published private(set) var iconStyle: MenuBarIconStyle
    @Published private(set) var autoHideDelaySeconds: Int
    @Published private(set) var showQuickBarOnHover: Bool
    @Published private(set) var changePresentation: MenuBarChangePresentation?
    @Published private(set) var message = "首次进入只检查能力。点“重新读取”后，才会读取菜单栏并生成草稿。"
    @Published private(set) var notes: [String] = []

    private let permissionClient: MenuBarControlPermissionClient
    private let acquireInputLease: @MainActor (UUID) -> InputLeaseToken?
    private let releaseInputLease: @MainActor (InputLeaseToken, InputLeaseReleaseReason) -> Bool
    private let captureQuickBarIcons: @MainActor ([MenuBarOrderItem]) async -> [String: MenuBarQuickBarIconSnapshot]
    private let storageRootURL: URL
    private let osMajorVersion: @Sendable () -> Int
    private let nativeVisibilitySupported: @MainActor () -> Bool
    private let disableNativeHidingForDiagnostics: Bool
    private let collapseRuntime: MenuBarCollapseRuntime
    private let protectionPolicy = MenuBarTargetProtectionPolicy(
        ownBundleIdentifier: AppConstants.bundleIdentifier
    )
    private let collapseProtectionPolicy = MenuBarTargetProtectionPolicy(
        ownBundleIdentifier: AppConstants.bundleIdentifier,
        collapsibleSystemBundleIdentifiers: [
            MenuBarTargetProtectionPolicy.textInputMenuAgentBundleIdentifier,
        ]
    )
    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "MenuBarManagement"
    )

    private var readTask: Task<Void, Never>?
    private let systemPanelAccessMonitor = MenuBarSystemPanelAccessMonitor()
    private var orderTask: Task<Void, Never>?
    private var collapsePreparationTask: Task<Void, Never>?
    private var collapseTimeoutTask: Task<Void, Never>?
    private var automaticRecollapseTask: Task<Void, Never>?
    private var applicationTopologyDebounceTask: Task<Void, Never>?
    private var lifecycleRecoveryTask: Task<Void, Never>?
    private var instantPreparationTask: Task<Void, Never>?
    private var instantPreparationTaskID: UUID?
    private var instantPreparation: MenuBarInstantCollapsePreparation?
    private var instantStructurePreparation: MenuBarInstantStructureCollapsePreparation?
    private var instantContextRevision: UInt64 = 0
    var ownedStatusItemEvidence: @MainActor () -> MenuBarOwnedStatusItemEvidence? = { nil }
    // Monitoring baseline only, never an executable visibility allow-list.
    private var directPhysicalTopology: MenuBarTopologySnapshot?
    /// A physically unsafe/unknown native result may not enter automatic retry.
    /// Deliberately session-only; never rewrite the user's saved preference.
    private var nativeSafetyBlocked = false
    private var physicalBootstrapGeneration: UInt64?
    private var revealedAutoRecollapseTask: Task<Void, Never>?
    private var revealedAutoRecollapseID: UUID?
    /// Retains every asynchronous operation until its body physically returns.
    /// The public task slots above may be cancelled, cleared or replaced while
    /// a native read is still unwinding; shutdown must still be able to drain
    /// those older generations before it reports cleanup complete.
    private var activeTrackedTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticRecollapseID: UUID?
    private var automaticReadID: UUID?
    private var automaticRecovery = MenuBarAutomaticCollapseRecovery()
    private var explicitRecollapseGeneration: UInt64?
    private var temporaryRevealInteractionIDs: Set<UUID> = []
    private var pendingTemporaryRevealResolution = PendingTemporaryRevealResolution()
    private var pendingRecollapseTrigger: String?
    private var cancellation: OrderCancellation?
    private var executionID: UUID?
    private var activeLeaseToken: InputLeaseToken?
    private var inputMonitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var persistentSession = PersistentHideSession()
    private var visibilityAssertion: (any MenuBarCollapseAssertion)?
    private var activeCollapsePlan: MenuBarCollapsePlan?
    private var activeTopologySnapshot: MenuBarTopologySnapshot?
    private var visibilityIntentGeneration: UInt64 = 0
    private var lastTopologyIssueSummary: String?
    private var topologyTimer: Timer?
    /// Identifies the exact asynchronous topology read. A completion from an
    /// invalidated session must never clear a newer session's in-flight gate.
    private var topologyReadID: UUID?
    /// Retained until the physical read returns. A cancelled old session keeps
    /// this single-flight gate closed so a new timer cannot stack another AX
    /// traversal on top of it.
    private var topologyReadTask: Task<Void, Never>?
    private var isPrepared = false
    private var isTerminating = false
    private var environmentAllowsRecollapse = true
    /// Real status-item pixels captured immediately before the current hide
    /// assertion. These are intentionally never persisted.
    private var quickBarIconSnapshots: [String: MenuBarQuickBarIconSnapshot] = [:]

    @discardableResult
    private func startTrackedTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !isTerminating else { return nil }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.activeTrackedTasks.removeValue(forKey: taskID) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        activeTrackedTasks[taskID] = task
        return task
    }

    private var journalURL: URL {
        storageRootURL.appendingPathComponent("order-recovery-v1.json")
    }

    private var collapseRecordURL: URL {
        storageRootURL.appendingPathComponent("collapse-session-v1.json")
    }

    private var historyRootURL: URL {
        storageRootURL.appendingPathComponent("history", isDirectory: true)
    }

    private var settingsURL: URL {
        storageRootURL.appendingPathComponent("settings-v1.json")
    }

    init(
        permissionClient: MenuBarControlPermissionClient = .system,
        storageRootURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("DisplayMonitor", isDirectory: true)
            .appendingPathComponent("MenuBar", isDirectory: true),
        osMajorVersion: @escaping @Sendable () -> Int = {
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        },
        nativeVisibilitySupported: @escaping @MainActor () -> Bool = {
            DMMenuBarVisibility.supportsHiding()
        },
        disableNativeHidingForDiagnostics: Bool = Bundle.main.object(
            forInfoDictionaryKey: "DisplayMonitorDiagnosticDisableNativeHiding") as? Bool == true,
        captureQuickBarIcons: @escaping @MainActor ([MenuBarOrderItem]) async -> [String: MenuBarQuickBarIconSnapshot] = { _ in [:] },
        collapseRuntime: MenuBarCollapseRuntime = MenuBarCollapseRuntime(),
        acquireInputLease: @escaping @MainActor (UUID) -> InputLeaseToken?,
        releaseInputLease: @escaping @MainActor (
            InputLeaseToken,
            InputLeaseReleaseReason
        ) -> Bool
    ) {
        self.permissionClient = permissionClient
        self.storageRootURL = storageRootURL
        self.osMajorVersion = osMajorVersion
        self.nativeVisibilitySupported = nativeVisibilitySupported
        self.disableNativeHidingForDiagnostics = disableNativeHidingForDiagnostics
        self.captureQuickBarIcons = captureQuickBarIcons
        self.collapseRuntime = collapseRuntime
        self.acquireInputLease = acquireInputLease
        self.releaseInputLease = releaseInputLease
        let settings = Self.loadSettings(from: storageRootURL)
        isEnabled = settings.isEnabled
        wantsPersistentCollapse = settings.wantsPersistentCollapse
        userVisibilityIntent = settings.wantsPersistentCollapse ? .collapsed : .revealed
        primaryPresentationMode = settings.primaryPresentationMode
        showQuickBarOnHover = settings.showQuickBarOnHover
        iconStyle = settings.iconStyle
        autoHideDelaySeconds = settings.autoHideDelaySeconds
        changePresentation = nil
        permissionStatus = permissionClient.snapshot()
    }

    var isOrderingAvailable: Bool { osMajorVersion() >= 27 }

    var isCollapseAvailable: Bool {
        !disableNativeHidingForDiagnostics && isOrderingAvailable && nativeVisibilitySupported()
            && collapseRuntime.hidingLaunchIssue() == nil
    }

    var isFeatureAvailable: Bool { isOrderingAvailable }

    var featureAvailabilityMessage: String {
        guard isOrderingAvailable else {
            return "菜单栏收起与排序需要 macOS 27 或更高版本；原有 Monitor、截图和录屏功能不受影响。"
        }
        guard !disableNativeHidingForDiagnostics, nativeVisibilitySupported() else {
            return "当前系统可读取并排序菜单栏；持续收起接口尚未就绪，因此“收起”暂时禁用。"
        }
        if let issue = collapseRuntime.hidingLaunchIssue() { return issue }
        return "当前系统支持固定分界、持续收起与真实排序。读取和模拟拖动分别检查权限。"
    }

    var layouts: [AnchoredMenuBarLayout] {
        (try? inventory?.validatedLayouts()) ?? []
    }

    var selectedLayout: AnchoredMenuBarLayout? {
        layouts.first { $0.displayID == selectedDisplayID }
    }

    var displayIDs: [UInt32] {
        layouts.map(\.displayID).sorted()
    }

    var rowsByID: [String: MenuBarOrderItem] {
        guard let selectedLayout else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: selectedLayout.orderedItems.map { ($0.id, $0) }
        )
    }

    var actualLeft: [MenuBarOrderItem] { selectedLayout?.leftItems ?? [] }
    var actualRight: [MenuBarOrderItem] { selectedLayout?.rightItems ?? [] }
    var anchorTitle: String { selectedLayout?.anchor.title ?? AppConstants.appName }

    var draftLeft: [MenuBarOrderItem] {
        guard let anchorID = selectedLayout?.anchorID,
              let anchorIndex = draftIDs.firstIndex(of: anchorID) else { return [] }
        return draftIDs[..<anchorIndex].compactMap { rowsByID[$0] }
    }

    var draftRight: [MenuBarOrderItem] {
        guard let anchorID = selectedLayout?.anchorID,
              let anchorIndex = draftIDs.firstIndex(of: anchorID),
              anchorIndex < draftIDs.index(before: draftIDs.endIndex) else { return [] }
        return draftIDs[draftIDs.index(after: anchorIndex)...].compactMap { rowsByID[$0] }
    }

    var hasChanges: Bool {
        guard let selectedLayout else { return false }
        return draftIDs != selectedLayout.orderedItems.map(\.id)
    }

    var coverageIsComplete: Bool {
        inventory?.coverage.isComplete == true && !layouts.isEmpty
    }

    var isBusy: Bool {
        isReading || isApplying || isPreparingCollapse || isCollapsed
    }

    var readBlockingReason: String? {
        if isTerminating { return "应用正在退出。" }
        if !isFeatureAvailable { return featureAvailabilityMessage }
        if !isEnabled { return "请先启用菜单栏整理；启用本身不会隐藏或移动图标。" }
        if isApplying { return "排序正在执行，结束后才能重新读取。" }
        if isPreparingCollapse || isCollapsed { return "请先展开左侧图标，再重新读取。" }
        if isReading { return "正在读取菜单栏。" }
        if hasChanges { return "请先应用或放弃当前草稿，再重新读取。" }
        if !permissionStatus.accessibilityGranted { return "读取图标需要先授权辅助功能。" }
        return nil
    }

    var canReadInventory: Bool { readBlockingReason == nil }

    var applyBlockingReason: String? {
        if isTerminating { return "应用正在退出。" }
        if let reason = Self.basicApplyBlockingReason(
            featureAvailable: isFeatureAvailable,
            availabilityMessage: featureAvailabilityMessage,
            enabled: isEnabled,
            applying: isApplying,
            collapseActive: isPreparingCollapse || isCollapsed,
            reading: isReading,
            accessibilityGranted: permissionStatus.accessibilityGranted,
            coverageComplete: coverageIsComplete,
            eventPostingGranted: permissionStatus.eventPostingGranted,
            hasChanges: hasChanges
        ) {
            return reason
        }
        guard let layout = selectedLayout else { return "没有可用的固定分界布局。" }
        do {
            _ = try AnchoredMenuBarPlanner.nextMove(
                current: layout.orderedItems,
                desiredIDs: draftIDs,
                anchorID: layout.anchorID,
                movableItemIDs: movableItemIDs(in: layout)
            )
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    nonisolated static func basicApplyBlockingReason(
        featureAvailable: Bool,
        availabilityMessage: String,
        enabled: Bool,
        applying: Bool,
        collapseActive: Bool,
        reading: Bool,
        accessibilityGranted: Bool,
        coverageComplete: Bool,
        eventPostingGranted: Bool,
        hasChanges: Bool
    ) -> String? {
        if !featureAvailable { return availabilityMessage }
        if !enabled { return "请先启用菜单栏整理；启用本身不会隐藏或移动图标。" }
        if applying { return "排序正在执行。" }
        if collapseActive { return "请先展开左侧图标，再应用排序。" }
        if reading { return "菜单栏仍在读取。" }
        if !accessibilityGranted { return "应用排序前需要读取图标权限。" }
        if !coverageComplete { return "完整性尚未通过，请先重新读取。" }
        if !eventPostingGranted { return "应用排序需要模拟拖动权限。" }
        if !hasChanges { return "草稿与真实顺序相同，无需应用。" }
        return nil
    }

    var canApplyDraft: Bool { applyBlockingReason == nil }

    var restoreBlockingReason: String? {
        if isTerminating { return "应用正在退出。" }
        if !isFeatureAvailable { return featureAvailabilityMessage }
        if !isEnabled { return "请先启用菜单栏整理。" }
        if isBusy { return "当前操作结束后才能恢复顺序。" }
        if !hasRecovery { return "没有可恢复的应用前顺序。" }
        if !permissionStatus.canSort { return "恢复顺序需要读取图标和模拟拖动权限。" }
        return nil
    }

    var canRestoreOrder: Bool { restoreBlockingReason == nil }

    var recoverySummary: String {
        guard let recovery = try? MenuBarOrderJournal.load(from: journalURL) else {
            return "没有可读取的恢复记录。"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return "保存于 \(formatter.string(from: recovery.savedAt))，屏幕 \(recovery.displayID)，共 \(recovery.originalItemIDs.count) 项。"
    }

    var collapseBlockingReason: String? {
        if isTerminating { return "应用正在退出。" }
        if nativeSafetyBlocked { return "本程序入口状态异常，本次运行已停止隐藏并请求展开；原有设置未更改。" }
        if !isCollapseAvailable { return featureAvailabilityMessage }
        if !isEnabled { return "请先启用菜单栏整理。" }
        if isApplying || isReading { return "请等待当前读取或排序结束。" }
        if isPreparingCollapse { return "正在保存收起计划并等待系统确认。" }
        if hasChanges { return "当前还有未应用草稿；请先应用或重置，再按真实顺序收起。" }
        if !permissionStatus.accessibilityGranted { return "收起前需要读取完整菜单栏，请先授权辅助功能。" }
        guard let inventory, coverageIsComplete else {
            return "请先重新读取，并确认菜单栏完整性通过。"
        }
        let applications = collapseRuntime.applications()
        if applications.contains(where: {
            $0.processIdentifier != ownPID
                && MenuBarTargetProtectionPolicy.isKnownManager(
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.name
                )
        }) {
            return "检测到其他菜单栏管理器仍在运行，请先自行退出后重新读取。"
        }
        do {
            let targets = try inventory.collapseTargetBundleIdentifiers(
                protectionPolicy: collapseProtectionPolicy
            )
            if targets.isEmpty { return "分界左侧没有可安全收起的第三方应用。" }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    var canToggleCollapse: Bool {
        isPreparingCollapse || isCollapsed || (!nativeSafetyBlocked
            && (canBootstrapCurrentPhysicalRead || collapseBlockingReason == nil))
    }

    private var canBootstrapCurrentPhysicalRead: Bool {
        guard !isTerminating, !nativeSafetyBlocked, isEnabled, isCollapseAvailable,
              environmentAllowsRecollapse, permissionStatus.accessibilityGranted,
              collapseRuntime.rawStructureGuardEnabled,
              ownedStatusItemEvidence()?.mainEntryVisible == true,
              !isApplying, !isReading, !isPreparingCollapse, !hasChanges,
              temporaryRevealInteractionIDs.isEmpty else { return false }
        return !collapseRuntime.applications().contains {
            $0.processIdentifier != ownPID && MenuBarTargetProtectionPolicy.isKnownManager(
                bundleIdentifier: $0.bundleIdentifier, name: $0.name)
        }
    }

    var collapseSummary: String {
        if nativeSafetyBlocked { return collapseBlockingReason ?? message }
        if isCollapsed { return "左侧图标已长期收起。左键 Display Monitor 可按所选方式查看；系统环境变化时会先展开并重新校验。" }
        if isPreparingCollapse { return "正在保存可恢复计划；系统确认前不会显示为已收起。" }
        guard let inventory,
              let targets = try? inventory.collapseTargetBundleIdentifiers(
                protectionPolicy: collapseProtectionPolicy
              ) else {
            return "重新读取后，这里会显示按真实菜单栏计算出的收起范围。"
        }
        return targets.isEmpty
            ? "真实分界左侧没有可收起的第三方图标。"
            : "按真实顺序收起左侧 \(targets.count) 个应用的图标；其他系统项目和本程序入口保持可见。"
    }

    private var ownPID: Int32 {
        Int32(ProcessInfo.processInfo.processIdentifier)
    }

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        refreshPermissions()
        hasRecovery = FileManager.default.fileExists(atPath: journalURL.path)
        if FileManager.default.fileExists(atPath: collapseRecordURL.path) {
            note("发现上次收起记录。旧进程的系统断言已经结束；正在安全重建长期收起状态。")
            expandLeftSide(reason: nil)
        }
        installLifecycleObservers()
        if wantsPersistentCollapse {
            scheduleSafeRecollapse(
                trigger: "应用启动",
                delay: .milliseconds(900)
            )
        }
    }

    func refreshPermissions() {
        let current = permissionClient.snapshot()
        guard current != permissionStatus else { return }
        if current.accessibilityGranted != permissionStatus.accessibilityGranted {
            invalidateInstantPreparation()
        }
        permissionStatus = current
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled {
            setUserVisibilityIntent(.revealed)
            cancel(reason: "菜单栏整理已关闭，正在停止排序并释放输入。")
            cancelAutomaticRecollapse()
            isEnabled = false
            wantsPersistentCollapse = false
            expandLeftSide(reason: "菜单栏整理已关闭，左侧图标已展开。")
            do {
                try saveSettings(
                    isEnabled: false,
                    wantsPersistentCollapse: false,
                    primaryPresentationMode: primaryPresentationMode
                )
            } catch {
                message = "菜单栏整理已关闭，但设置未能保存：\(error.localizedDescription)"
                note(message)
                return
            }
            message = "菜单栏整理已关闭，左侧图标保持展开。"
            note(message)
            return
        }

        do {
            try saveSettings(
                isEnabled: true,
                wantsPersistentCollapse: true,
                primaryPresentationMode: primaryPresentationMode
            )
        } catch {
            message = "菜单栏整理设置未能保存，尚未启用：\(error.localizedDescription)"
            note(message)
            return
        }
        isEnabled = true
        wantsPersistentCollapse = true
        setUserVisibilityIntent(.collapsed)
        message = "菜单栏整理已启用；正在读取真实菜单栏并准备长期收起。"
        note(message)
        scheduleSafeRecollapse(trigger: "启用菜单栏整理")
    }

    /// Updates the durable resting-state preference. Turning it off is the only
    /// user action that converts a temporary reveal into a permanent expansion.
    func setPersistentCollapseDesired(_ desired: Bool) {
        guard !desired || isEnabled else {
            message = "请先启用菜单栏整理，再开启长期收起。"
            note(message)
            return
        }
        guard desired != wantsPersistentCollapse else {
            if desired, !isCollapsed, !isPreparingCollapse {
                scheduleSafeRecollapse(trigger: "恢复长期收起")
            }
            return
        }
        if desired {
            do {
                try saveSettings(
                    isEnabled: isEnabled,
                    wantsPersistentCollapse: true,
                    primaryPresentationMode: primaryPresentationMode
                )
            } catch {
                message = "长期收起设置未能保存，当前保持展开：\(error.localizedDescription)"
                note(message)
                return
            }
            wantsPersistentCollapse = true
            setUserVisibilityIntent(.collapsed)
            scheduleSafeRecollapse(trigger: "启用长期收起")
        } else {
            wantsPersistentCollapse = false
            setUserVisibilityIntent(.revealed)
            cancelAutomaticRecollapse()
            expandLeftSide(reason: "长期收起已关闭，左侧图标保持展开。")
            do {
                try saveSettings(
                    isEnabled: isEnabled,
                    wantsPersistentCollapse: false,
                    primaryPresentationMode: primaryPresentationMode
                )
            } catch {
                message = "长期收起已关闭，但设置未能保存：\(error.localizedDescription)"
                note(message)
            }
        }
    }

    func setPrimaryPresentationMode(_ mode: MenuBarPrimaryPresentationMode) {
        guard mode != primaryPresentationMode else { return }
        do {
            try saveSettings(
                isEnabled: isEnabled,
                wantsPersistentCollapse: wantsPersistentCollapse,
                primaryPresentationMode: mode
            )
        } catch {
            message = "显示方式未能保存：\(error.localizedDescription)"
            note(message)
            return
        }
        primaryPresentationMode = mode
        message = mode == .nativeMenuBar
            ? "左键入口时，将在顶部菜单栏展开真实图标。"
            : "左键入口时，将在图标下方显示快捷栏。"
        note(message)
    }

    func setIconStyle(_ style: MenuBarIconStyle) {
        guard style != iconStyle else { return }
        do {
            try saveSettings(isEnabled: isEnabled,
                             wantsPersistentCollapse: wantsPersistentCollapse,
                             primaryPresentationMode: primaryPresentationMode,
                             iconStyle: style)
            iconStyle = style
        } catch {
            message = "图标样式未能保存：\(error.localizedDescription)"
            note(message)
        }
    }

    func setAutoHideDelaySeconds(_ seconds: Int) {
        let seconds = MenuBarAutoHideDelay.clamped(seconds)
        guard seconds != autoHideDelaySeconds else { return }
        do {
            try saveSettings(isEnabled: isEnabled,
                             wantsPersistentCollapse: wantsPersistentCollapse,
                             primaryPresentationMode: primaryPresentationMode,
                             autoHideDelaySeconds: seconds)
            autoHideDelaySeconds = seconds
            if userVisibilityIntent == .revealed {
                scheduleRevealedAutoRecollapse()
            }
        } catch {
            message = "自动隐藏时长未能保存：\(error.localizedDescription)"
            note(message)
        }
    }

    func setShowQuickBarOnHover(_ enabled: Bool) {
        guard enabled != showQuickBarOnHover else { return }
        do {
            try saveSettings(
                isEnabled: isEnabled,
                wantsPersistentCollapse: wantsPersistentCollapse,
                primaryPresentationMode: primaryPresentationMode,
                showQuickBarOnHover: enabled
            )
            showQuickBarOnHover = enabled
            message = enabled ? "悬停在入口片刻后显示图标条。" : "已关闭悬停展开，点击入口仍可显示图标条。"
        } catch {
            message = "悬停偏好未能保存：\(error.localizedDescription)"
        }
        note(message)
    }

    var quickBarItems: [MenuBarQuickBarItem] {
        guard let inventory,
              let hiddenBundleIdentifiers = try? inventory.collapseTargetBundleIdentifiers(
                  protectionPolicy: collapseProtectionPolicy
              ) else { return [] }
        let items = layouts
            .sorted { $0.displayID < $1.displayID }
            .flatMap { layout in
                layout.leftItems.sorted { $0.frame.minX < $1.frame.minX }
            }
        return MenuBarQuickBarCatalog.makeItems(
            from: items,
            hiddenBundleIdentifiers: Set(hiddenBundleIdentifiers),
            iconSnapshots: quickBarIconSnapshots,
            movableItemIDs: Set(items.filter(canMove).map(\.id))
        )
    }

    func requestNextPermission() {
        guard isOrderingAvailable, !isApplying, !isPreparingCollapse else { return }
        let response = permissionClient.request()
        permissionStatus = response.status
        switch response.requested {
        case .none:
            message = "读取与模拟拖动权限均已授权。"
        case .accessibility:
            message = "已申请辅助功能权限；授权后返回并点“重新读取”。"
        case .eventPosting:
            message = "已申请模拟拖动权限；授权后返回并重新检测。"
        }
        note(message)
    }

    func displayName(_ id: UInt32) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }.map(\.localizedName) ?? "屏幕 \(id)"
    }

    func selectDisplay(_ id: UInt32) {
        guard !isBusy, displayIDs.contains(id) else { return }
        guard !hasChanges else {
            message = "请先应用或放弃当前草稿，再切换显示器。"
            return
        }
        selectedDisplayID = id
        resetDraft()
    }

    func readInventory(preferCurrentPhysical: Bool = false) {
        refreshPermissions()
        guard let blockingReason = readBlockingReason else {
            beginInventoryRead(preferCurrentPhysical: preferCurrentPhysical)
            return
        }
        message = blockingReason
        note(blockingReason)
    }

    private func beginInventoryRead(preferCurrentPhysical: Bool = false) {
        cancelAutomaticRecollapse()
        invalidateInstantPreparation()
        readTask?.cancel()
        let applications = collapseRuntime.applications()
        let anchorIdentity = Self.anchorIdentity
        let ownPID = ownPID
        let protectionPolicy = protectionPolicy
        let runtime = collapseRuntime
        let ownedBefore = preferCurrentPhysical && runtime.rawStructureGuardEnabled
            ? ownedStatusItemEvidence() : nil
        let readsCurrentPhysical = preferCurrentPhysical && runtime.rawStructureGuardEnabled
            && ownedBefore?.mainEntryVisible == true
        isReading = true
        message = "正在读取物理菜单栏，并核对每块屏幕的固定分界…"
        let operationID = UUID()
        readTask = startTrackedTask { [weak self] in
            let result: AnchoredMenuBarDiscoveryResult
            var physicalReadRejected = false
            if readsCurrentPhysical {
                let before = await runtime.rawPhysicalStructure(applications)
                guard !Task.isCancelled else { return }
                let after = await runtime.rawPhysicalStructure(runtime.applications())
                guard let self, !Task.isCancelled, !self.isTerminating else { return }
                let currentApplications = runtime.applications()
                let ownedAfter = self.ownedStatusItemEvidence()
                let owned = ownedBefore == ownedAfter ? ownedAfter : nil
                let firstInventory = owned.flatMap {
                    MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: before,
                        applicationsBefore: applications, applicationsAfter: currentApplications,
                        anchor: anchorIdentity, ownedStatusItems: $0,
                        protectionPolicy: self.collapseProtectionPolicy)
                }
                let secondInventory = owned.flatMap {
                    MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: after,
                        applicationsBefore: applications, applicationsAfter: currentApplications,
                        anchor: anchorIdentity, ownedStatusItems: $0,
                        protectionPolicy: self.collapseProtectionPolicy)
                }
                let firstTargets = firstInventory.flatMap {
                    try? $0.collapseTargetBundleIdentifiers(protectionPolicy: self.collapseProtectionPolicy)
                }
                let secondTargets = secondInventory.flatMap {
                    try? $0.collapseTargetBundleIdentifiers(protectionPolicy: self.collapseProtectionPolicy)
                }
                if before.model.displays == after.model.displays,
                   let firstTargets, let secondTargets, Set(firstTargets) == Set(secondTargets),
                   let secondInventory {
                    result = .init(inventory: secondInventory, physicalItems: secondInventory.items,
                        messages: ["已通过两次当前物理菜单栏读取，固定分界与收起范围一致。"])
                } else {
                    physicalReadRejected = true
                    let displayIDs = Set(before.model.displays.map(\.id) + after.model.displays.map(\.id)).sorted()
                    result = .init(inventory: .init(items: [], coverage: .init(
                        expectedDisplayIDs: displayIDs, observedCandidateCount: 1,
                        resolvedItemCount: 0, unexplainedSkippedItemCount: 1), anchorIdentity: anchorIdentity),
                        physicalItems: [], messages: ["当前物理菜单栏未能通过两次完整读取，已保持展开；请稍后再读取图标。"])
                }
            } else {
                result = await runtime.discover(applications, anchorIdentity, ownPID, protectionPolicy)
            }
            guard let self, !Task.isCancelled, !self.isTerminating else { return }
            self.readTask = nil
            self.isReading = false
            self.acceptInventory(result, operationID: operationID)
            if physicalReadRejected {
                self.message = "当前物理菜单栏未能通过两次完整读取，已保持展开；请稍后再读取图标。"
                return
            }
            if self.userVisibilityIntent == .revealed {
                // The collapse page already obtained its current physical proof.
                // A logical warmup must not replace it with the older AX scan.
                if !readsCurrentPhysical { self.startInstantPreparationWarmup() }
                self.scheduleRevealedAutoRecollapse()
            }
        }
    }

    private func acceptInventory(
        _ result: AnchoredMenuBarDiscoveryResult,
        operationID: UUID
    ) {
        instantPreparation = nil
        instantStructurePreparation = nil
        inventory = result.inventory
        let validated = try? result.inventory.validatedLayouts()
        if let validated, !validated.isEmpty {
            if !validated.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = validated.map(\.displayID).sorted().first ?? 0
            }
            resetDraft()
            message = "读取完成。当前显示的左右分组来自真实菜单栏。"
        } else {
            draftIDs = []
            message = validationMessage(for: result.inventory)
        }
        result.messages.forEach(note)
        note("读取 \(operationID.uuidString.prefix(8))：\(message)")
    }

    func resetDraft() {
        guard !isApplying, !isPreparingCollapse, !isCollapsed else { return }
        draftIDs = selectedLayout?.orderedItems.map(\.id) ?? []
    }

    func discardDraft() {
        guard hasChanges, !isBusy else { return }
        resetDraft()
        message = "已放弃排序草稿，真实菜单栏未改变。"
        note(message)
    }

    func canMove(_ item: MenuBarOrderItem) -> Bool {
        guard item.id != selectedLayout?.anchorID else { return false }
        return protectionPolicy.reason(
            bundleIdentifier: item.bundleIdentifier,
            applicationName: item.applicationName
        ) == nil
    }

    func moveAcross(_ id: String) {
        guard !isBusy,
              let layout = selectedLayout,
              let item = rowsByID[id],
              canMove(item),
              let sourceIndex = draftIDs.firstIndex(of: id),
              let anchorIndex = draftIDs.firstIndex(of: layout.anchorID) else { return }
        let wasLeft = sourceIndex < anchorIndex
        draftIDs.remove(at: sourceIndex)
        guard let updatedAnchorIndex = draftIDs.firstIndex(of: layout.anchorID) else {
            resetDraft()
            return
        }
        let destination = wasLeft ? draftIDs.index(after: updatedAnchorIndex) : updatedAnchorIndex
        draftIDs.insert(id, at: destination)
        invalidateInstantPreparation()
        message = "草稿已调整；真实菜单栏尚未改变。"
    }

    func moveWithinSide(_ id: String, by offset: Int) {
        guard !isBusy,
              offset != 0,
              let item = rowsByID[id],
              canMove(item),
              let source = draftIDs.firstIndex(of: id),
              let anchor = draftIDs.firstIndex(of: selectedLayout?.anchorID ?? "") else { return }
        let destination = source + offset
        guard draftIDs.indices.contains(destination), destination != anchor else { return }
        let remainsOnSameSide = (source < anchor) == (destination < anchor)
        guard remainsOnSameSide else { return }
        draftIDs.swapAt(source, destination)
        invalidateInstantPreparation()
        message = "草稿已调整；真实菜单栏尚未改变。"
    }

    func applyDraft() {
        refreshPermissions()
        if let reason = applyBlockingReason {
            message = reason
            note(reason)
            return
        }
        guard let layout = selectedLayout else { return }
        let recovery = MenuBarOrderRecovery(
            savedAt: Date(),
            displayID: layout.displayID,
            anchorIdentity: Self.anchorIdentity,
            originalItems: layout.orderedItems,
            desiredItemIDs: draftIDs
        )
        beginOrderExecution(
            ids: draftIDs,
            seedItems: layout.orderedItems,
            displayID: layout.displayID,
            movableItemIDs: movableItemIDs(in: layout),
            recovery: recovery,
            restoring: false
        )
    }

    /// The bar's drag operation edits only a local draft. This method runs
    /// solely after its explicit Apply button, then uses the existing verified
    /// order executor, input lease and recovery journal.
    func applyQuickBarOrder(originalIDs: [String], proposedIDs: [String]) {
        guard !isTerminating, isEnabled, wantsPersistentCollapse, isCollapsed,
              !isApplying, !isReading, !isPreparingCollapse, !hasChanges,
              quickBarItems.map(\.id) == originalIDs,
              let inventory else {
            message = "当前图标条已变化或有其他任务，请重新打开后再排序。"
            note(message)
            return
        }
        do {
            let candidates = try inventory.validatedLayouts().filter { layout in
                originalIDs.contains { id in layout.leftIDs.contains(id) }
            }
            guard candidates.count == 1, let baseline = candidates.first else {
                message = "图标条跨越多个显示器，请在设置中选择显示器后排序。"
                note(message)
                return
            }
            _ = try MenuBarQuickBarOrderPlanner.desiredFullOrder(
                layout: baseline,
                originalQuickBarIDs: originalIDs,
                proposedQuickBarIDs: proposedIDs,
                movableItemIDs: movableItemIDs(in: baseline)
            )
            guard let interaction = beginTemporaryRevealInteraction() else { return }
            let applications = collapseRuntime.applications()
            let anchorIdentity = Self.anchorIdentity
            let ownPID = ownPID
            let protectionPolicy = protectionPolicy
            let runtime = collapseRuntime
            isReading = true
            message = "正在展开并重新核对真实图标，确认后应用图标条排序…"
            readTask = startTrackedTask { [weak self] in
                let result = await runtime.discover(
                    applications, anchorIdentity, ownPID, protectionPolicy
                )
                guard let self else { return }
                self.isReading = false
                self.readTask = nil
                defer {
                    self.endTemporaryRevealInteraction(
                        interaction,
                        shouldRecollapse: !self.isApplying,
                        delay: .milliseconds(900)
                    )
                }
                guard !Task.isCancelled, !self.isTerminating,
                      self.temporaryRevealInteractionIDs.contains(interaction),
                      self.isEnabled, self.wantsPersistentCollapse else { return }
                self.acceptInventory(result, operationID: UUID())
                do {
                    let layouts = try result.inventory.validatedLayouts()
                    guard let fresh = layouts.first(where: { $0.displayID == baseline.displayID }),
                          fresh.orderedItems.map(\.id) == baseline.orderedItems.map(\.id) else {
                        throw MenuBarQuickBarOrderError.staleCatalog
                    }
                    let fullOrder = try MenuBarQuickBarOrderPlanner.desiredFullOrder(
                        layout: fresh,
                        originalQuickBarIDs: originalIDs,
                        proposedQuickBarIDs: proposedIDs,
                        movableItemIDs: self.movableItemIDs(in: fresh)
                    )
                    self.selectedDisplayID = fresh.displayID
                    self.draftIDs = fullOrder
                    self.applyDraft()
                } catch {
                    self.message = "排序尚未开始：\(error.localizedDescription)"
                    self.note(self.message)
                }
            }
        } catch {
            message = "排序尚未开始：\(error.localizedDescription)"
            note(message)
        }
    }

    func restoreOrder() {
        refreshPermissions()
        if let reason = restoreBlockingReason {
            message = reason
            note(reason)
            return
        }
        let recovery: MenuBarOrderRecovery
        do {
            recovery = try MenuBarOrderJournal.load(from: journalURL)
        } catch {
            message = "恢复记录无法读取：\(error.localizedDescription)"
            note(message)
            return
        }

        let applications = collapseRuntime.applications()
        let anchorIdentity = Self.anchorIdentity
        let ownPID = ownPID
        let protectionPolicy = protectionPolicy
        let runtime = collapseRuntime
        isReading = true
        message = "正在重新读取真实菜单栏，为恢复应用前顺序做准备…"
        readTask = startTrackedTask { [weak self] in
            let result = await runtime.discover(
                applications, anchorIdentity, ownPID, protectionPolicy
            )
            guard let self, !Task.isCancelled else { return }
            self.readTask = nil
            self.isReading = false
            self.inventory = result.inventory
            do {
                let layouts = try result.inventory.validatedLayouts()
                guard let layout = layouts.first(where: { $0.displayID == recovery.displayID }),
                      recovery.anchorIdentity == Self.anchorIdentity,
                      Set(layout.orderedItems.map(\.id)) == Set(recovery.originalItemIDs),
                      layout.orderedItems.count == recovery.originalItemIDs.count else {
                    throw OrderFailure("恢复记录中的图标集合已变化，尚未移动。")
                }
                self.selectedDisplayID = recovery.displayID
                self.draftIDs = recovery.originalItemIDs
                let restoreUndo = MenuBarOrderRecovery(
                    savedAt: Date(),
                    displayID: layout.displayID,
                    anchorIdentity: Self.anchorIdentity,
                    originalItems: layout.orderedItems,
                    desiredItemIDs: recovery.originalItemIDs
                )
                try self.saveHistory(
                    restoreUndo,
                    label: "before-restore"
                )
                self.beginOrderExecution(
                    ids: recovery.originalItemIDs,
                    seedItems: layout.orderedItems,
                    displayID: recovery.displayID,
                    movableItemIDs: self.movableItemIDs(in: layout),
                    recovery: nil,
                    restoring: true
                )
            } catch {
                self.message = "恢复未开始：\(error.localizedDescription)"
                self.note(self.message)
            }
        }
    }

    func cancel(reason: String = "正在停止排序并释放输入。") {
        guard isApplying else { return }
        cancellation?.cancel(reason: reason)
        orderTask?.cancel()
        message = reason
        note(reason)
    }

    private func beginOrderExecution(
        ids: [String],
        seedItems: [MenuBarOrderItem],
        displayID: UInt32,
        movableItemIDs: Set<String>,
        recovery: MenuBarOrderRecovery?,
        restoring: Bool
    ) {
        guard !isTerminating, !isApplying else { return }
        let operationID = UUID()
        guard let lease = acquireInputLease(operationID) else {
            message = "其他输入操作正在进行，菜单栏排序未开始。"
            note(message)
            return
        }
        activeLeaseToken = lease

        if let recovery {
            do {
                try FileManager.default.createDirectory(
                    at: storageRootURL,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    let previous = try MenuBarOrderJournal.load(from: journalURL)
                    try saveHistory(previous, label: "replaced")
                }
                try MenuBarOrderJournal.save(recovery, to: journalURL)
                hasRecovery = true
            } catch {
                releaseActiveLease(reason: .cancelled)
                message = "应用前顺序保存失败，尚未移动：\(error.localizedDescription)"
                note(message)
                return
            }
        }

        let token = OrderCancellation()
        guard installInputMonitors(for: token) else {
            releaseActiveLease(reason: .cancelled)
            message = "无法安装人工输入监听，排序未开始；恢复记录仍保留。"
            note(message)
            return
        }

        cancellation = token
        executionID = operationID
        isApplying = true
        message = restoring
            ? "正在恢复上次应用前顺序…"
            : "已保存应用前顺序，正在按草稿移动真实图标…"
        note(message)

        let anchorIdentity = Self.anchorIdentity
        let ownPID = ownPID
        let protectionPolicy = protectionPolicy
        orderTask = startTrackedTask { [weak self] in
            let result = await AnchoredMenuBarOrderExecutor.apply(
                desiredIDs: ids,
                seedItems: seedItems,
                displayID: displayID,
                anchorIdentity: anchorIdentity,
                ownPID: ownPID,
                protectionPolicy: protectionPolicy,
                movableItemIDs: movableItemIDs,
                cancellation: token
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.executionID == operationID,
                          self.isApplying else { return }
                    self.message = progress
                    self.note(progress)
                }
            }
            guard let self else { return }
            self.finishOrderExecution(
                result,
                operationID: operationID,
                displayID: displayID,
                restoring: restoring
            )
        }
    }

    private func finishOrderExecution(
        _ result: AnchoredOrderExecutionResult,
        operationID: UUID,
        displayID: UInt32,
        restoring: Bool
    ) {
        guard executionID == operationID else { return }
        isApplying = false
        executionID = nil
        cancellation = nil
        orderTask = nil
        removeInputMonitors()
        releaseActiveLease(reason: result.success ? .completed : .cancelled)
        message = result.message
        note(result.message)

        if result.success, let verifiedInventory = result.verifiedInventory {
            inventory = verifiedInventory
            selectedDisplayID = displayID
            resetDraft()
            if restoring {
                do {
                    let completed = try MenuBarOrderJournal.load(from: journalURL)
                    try saveHistory(completed, label: "restored")
                    try MenuBarOrderJournal.remove(at: journalURL)
                    hasRecovery = false
                } catch {
                    note("顺序已恢复，但恢复记录未能删除：\(error.localizedDescription)")
                }
            }
        }
        if wantsPersistentCollapse, !isTerminating {
            scheduleSafeRecollapse(
                trigger: result.success ? "排序完成" : "排序已停止",
                delay: .milliseconds(900)
            )
        }
    }

    @discardableResult
    private func setUserVisibilityIntent(
        _ intent: MenuBarUserVisibilityIntent
    ) -> UInt64 {
        guard userVisibilityIntent != intent else { return visibilityIntentGeneration }
        visibilityIntentGeneration &+= 1
        userVisibilityIntent = intent
        changePresentation = nil
        if intent == .collapsed { cancelRevealedAutoRecollapse() }
        if intent == .revealed {
            explicitRecollapseGeneration = nil
            applicationTopologyDebounceTask?.cancel()
            applicationTopologyDebounceTask = nil
        }
        return visibilityIntentGeneration
    }

    private func collapseIntentIsCurrent(_ generation: UInt64) -> Bool {
        userVisibilityIntent == .collapsed
            && !nativeSafetyBlocked
            && visibilityIntentGeneration == generation
            && wantsPersistentCollapse
            && isEnabled
            && !isTerminating
    }

    /// Toggles the currently visible state while preserving the durable
    /// "keep collapsed" preference.
    func toggleCurrentCollapseVisibility() {
        switch userVisibilityIntent {
        case .collapsed:
            revealTemporarily()
        case .revealed:
            if wantsPersistentCollapse {
                guard !hasChanges else {
                    message = "当前还有未应用草稿；请先应用或重置，再按真实顺序收起。"
                    note(message)
                    return
                }
                setUserVisibilityIntent(.collapsed)
                requestImmediateRecollapse()
            } else {
                setPersistentCollapseDesired(true)
            }
        }
    }

    /// The settings/menu command label describes the actual execution state,
    /// unlike the entry's rapid-click intent toggle. A failed startup must not
    /// turn a button labelled "collapse" into another reveal action.
    func toggleCollapseFromSettings() {
        if isCollapsed || isPreparingCollapse {
            revealTemporarily()
        } else if wantsPersistentCollapse {
            setUserVisibilityIntent(.collapsed)
            requestImmediateRecollapse()
        } else {
            setPersistentCollapseDesired(true)
        }
    }

    /// Shows the real menu-bar items without changing the user's durable preference.
    /// The status item and popover call this before the user interacts with hidden items.
    func revealTemporarily() {
        guard wantsPersistentCollapse else { return }
        setUserVisibilityIntent(.revealed)
        cancelAutomaticRecollapse()
        expandLeftSide(
            reason: "左侧图标已临时展开。",
            preserveInstantPreparation: true
        )
        startInstantPreparationWarmup()
        scheduleRevealedAutoRecollapse()
    }

    func prepareForSystemPanelAccess() {
        guard !isTerminating, isEnabled, visibilityAssertion != nil,
              userVisibilityIntent == .collapsed else { return }
        revealTemporarily()
    }

    private func invalidateInstantPreparation(preservePhysicalBaseline: Bool = false) {
        // Topology polling while collapsed may omit the very icons we hid.
        // Retain only an independently proven physical baseline, never an
        // executable plan: the next click must renew a complete physical proof.
        let retainPhysical = preservePhysicalBaseline
            && (instantStructurePreparation?.hasIndependentPhysicalBaseline == true || directPhysicalTopology != nil)
        if !retainPhysical {
            instantContextRevision &+= 1
            instantStructurePreparation = nil
            directPhysicalTopology = nil
        }
        instantPreparation = nil
        instantPreparationTask?.cancel()
    }

    /// Full verification runs away from the click path. A prepared result is
    /// executable only after another complete, fresh physical-window guard.
    private func startInstantPreparationWarmup(attempt: Int = 0) {
        guard collapseRuntime.instantPrewarmingEnabled,
              !isTerminating, isEnabled, wantsPersistentCollapse,
              userVisibilityIntent == .revealed, environmentAllowsRecollapse,
              temporaryRevealInteractionIDs.isEmpty, !isApplying, !hasChanges else { return }
        let previous = instantPreparationTask
        previous?.cancel()
        let taskID = UUID()
        let generation = visibilityIntentGeneration
        let revision = instantContextRevision
        let runtime = collapseRuntime
        let anchor = Self.anchorIdentity
        let ownPID = ownPID
        let discoveryPolicy = protectionPolicy
        let collapsePolicy = collapseProtectionPolicy
        instantPreparationTaskID = taskID
        instantPreparationTask = startTrackedTask { [weak self, previous] in
            defer {
                if self?.instantPreparationTaskID == taskID {
                    self?.instantPreparationTask = nil
                    self?.instantPreparationTaskID = nil
                }
            }
            if let previous { await previous.value }
            do { try await Task.sleep(for: runtime.instantPreparationWarmupDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            // Keep topology outside the raw discovery fence. Reading it first
            // also gives the system's reveal animation time to settle, without
            // adding a delay or weakening either before/after comparison.
            let before = await runtime.topologySnapshot(runtime.applications())
            guard !Task.isCancelled else { return }
            let rawApplicationsBefore = runtime.applications()
            let rawBefore = runtime.rawStructureGuardEnabled
                ? await runtime.rawPhysicalStructure(rawApplicationsBefore) : nil
            guard !Task.isCancelled else { return }
            let applications = runtime.applications()
            let discovery = await runtime.discover(applications, anchor, ownPID, discoveryPolicy)
            guard !Task.isCancelled else { return }
            let after = await runtime.topologySnapshot(runtime.applications())
            guard !Task.isCancelled else { return }
            let rawApplicationsAfter = runtime.applications()
            let rawAfter = runtime.rawStructureGuardEnabled
                ? await runtime.rawPhysicalStructure(rawApplicationsAfter) : nil
            let physical = runtime.rawStructureGuardEnabled ? nil
                : await runtime.physicalGuard(applications, anchor, ownPID, discoveryPolicy)
            guard let self, !Task.isCancelled, !self.isTerminating,
                  self.instantPreparationTaskID == taskID,
                  self.visibilityIntentGeneration == generation,
                  self.userVisibilityIntent == .revealed,
                  self.instantContextRevision == revision,
                  self.wantsPersistentCollapse, self.isEnabled,
                  self.environmentAllowsRecollapse,
                  !self.isApplying, !self.isReading, !self.isPreparingCollapse,
                  !self.hasChanges,
                  self.temporaryRevealInteractionIDs.isEmpty,
                  MenuBarCollapsePreparationValidation.isUnchanged(
                    before: discovery.inventory, after: discovery.inventory,
                    initialTopology: before, finalTopology: after
                  ) else { return }
            let prepared = physical.flatMap {
                MenuBarInstantCollapsePreparation(
                    discovery: discovery, physicalGuard: $0, topology: after,
                    applications: applications, contextRevision: revision,
                    protectionPolicy: collapsePolicy
                )
            }
            let rawPrepared: MenuBarInstantStructureCollapsePreparation?
            if let rawBefore, let rawAfter {
                rawPrepared = MenuBarInstantStructureCollapsePreparation(
                    discovery: discovery, before: rawBefore, after: rawAfter, topology: after,
                    applicationsBefore: rawApplicationsBefore, applicationsDuring: applications,
                    applicationsAfter: rawApplicationsAfter, contextRevision: revision,
                    protectionPolicy: collapsePolicy
                )
            } else { rawPrepared = nil }
            if prepared != nil || rawPrepared != nil {
                self.acceptInventory(discovery, operationID: UUID())
                self.instantPreparation = prepared
                self.instantStructurePreparation = rawPrepared
            }
            self.logger.info(
                "menuBar.instant.prewarmed ready=\(prepared != nil || rawPrepared != nil, privacy: .public) fullItems=\(discovery.inventory.items.count, privacy: .public) physicalItems=\(discovery.physicalItems.count, privacy: .public) rawComplete=\(rawBefore?.isComplete == true && rawAfter?.isComplete == true, privacy: .public) rawStable=\(rawBefore != nil && rawBefore?.revision == rawAfter?.revision, privacy: .public) rawNodes=\(rawAfter?.nodeCount ?? 0, privacy: .public) rawReasons=\(rawAfter?.diagnostics.summary ?? "disabled", privacy: .public)"
            )
            // One animation retry, never an unbounded polling loop. The new
            // tracked task joins this one; all lifecycle/intent guards above
            // must pass again before publishing anything.
            if attempt == 0, prepared == nil, rawPrepared == nil,
               let rawBefore, let rawAfter,
               rawBefore.isComplete, rawAfter.isComplete,
               rawBefore.revision != rawAfter.revision {
                self.startInstantPreparationWarmup(attempt: 1)
            }
        }
    }

    private func requestImmediateRecollapse(continuingRecovery: Bool = false) {
        guard !nativeSafetyBlocked else {
            setUserVisibilityIntent(.revealed)
            message = "未能确认入口和保留图标仍可见，已请求恢复展开；本次运行不再尝试隐藏。"
            return
        }
        guard isCollapseAvailable else {
            setUserVisibilityIntent(.revealed)
            message = featureAvailabilityMessage
            return
        }
        guard !hasChanges else {
            setUserVisibilityIntent(.revealed)
            message = "当前还有未应用草稿；请先应用或重置，再按真实顺序收起。"
            note(message)
            scheduleRevealedAutoRecollapse()
            return
        }
        explicitRecollapseGeneration = visibilityIntentGeneration
        cancelAutomaticRecollapse(cancelRecovery: !continuingRecovery)
        instantPreparationTask?.cancel()
        refreshPermissions()
        let prepared = instantPreparation
        let rawPrepared = instantStructurePreparation
        let ownedBefore = ownedStatusItemEvidence()
        let canReadCurrentPhysical = collapseRuntime.rawStructureGuardEnabled
            && ownedBefore?.mainEntryVisible == true
        guard prepared != nil || rawPrepared != nil || canReadCurrentPhysical,
              environmentAllowsRecollapse, permissionStatus.accessibilityGranted,
              !isApplying, !isReading, !isPreparingCollapse,
              temporaryRevealInteractionIDs.isEmpty else {
            requestRecollapseAfterInteraction(delay: .zero, preferRetainedInventoryFastPath: true)
            return
        }
        if !continuingRecovery { automaticRecovery.begin() }
        let generation = visibilityIntentGeneration
        let revision = instantContextRevision
        let runtime = collapseRuntime
        let applications = runtime.applications()
        let anchor = Self.anchorIdentity
        let ownPID = ownPID
        let discoveryPolicy = protectionPolicy
        let retainedTopology = rawPrepared?.topology ?? directPhysicalTopology
        isPreparingCollapse = true
        collapsePreparationTask = startTrackedTask { [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            // Only a cold bootstrap needs a logical monitoring baseline. Every
            // subsequent click still reads the full current physical inventory.
            let physicalTopology: MenuBarTopologySnapshot?
            if canReadCurrentPhysical {
                if let retainedTopology { physicalTopology = retainedTopology }
                else { physicalTopology = await runtime.topologySnapshot(applications) }
            } else { physicalTopology = nil }
            guard !Task.isCancelled else { return }
            let firstRaw = rawPrepared != nil || canReadCurrentPhysical
                ? await runtime.rawPhysicalStructure(applications) : nil
            guard !Task.isCancelled else { return }
            let raw = canReadCurrentPhysical
                ? await runtime.rawPhysicalStructure(runtime.applications()) : firstRaw
            let physical = rawPrepared == nil && !canReadCurrentPhysical
                ? await runtime.physicalGuard(applications, anchor, ownPID, discoveryPolicy) : nil
            guard let self, !Task.isCancelled,
                  self.collapseIntentIsCurrent(generation),
                  self.isPreparingCollapse else { return }
            self.collapsePreparationTask = nil
            self.refreshPermissions()
            let currentApplications = runtime.applications()
            let ownedAfter = self.ownedStatusItemEvidence()
            let owned = ownedBefore == ownedAfter ? ownedAfter : nil
            let firstInventory = canReadCurrentPhysical && owned != nil ? firstRaw.flatMap {
                MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: $0,
                    applicationsBefore: applications, applicationsAfter: currentApplications,
                    anchor: anchor, ownedStatusItems: owned, protectionPolicy: self.collapseProtectionPolicy,
                    onReject: { reason in self.logger.notice("menuBar.instant.physicalRejected stage=before reason=\(reason, privacy: .public)") })
            } : nil
            let beforeTargets = firstInventory.flatMap { try? $0.collapseTargetBundleIdentifiers(protectionPolicy: self.collapseProtectionPolicy) }
            let directInventory = canReadCurrentPhysical && owned != nil && firstRaw?.model.displays == raw?.model.displays ? raw.flatMap {
                MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: $0,
                    applicationsBefore: applications, applicationsAfter: currentApplications,
                    anchor: anchor, ownedStatusItems: owned, protectionPolicy: self.collapseProtectionPolicy,
                    onReject: { reason in self.logger.notice("menuBar.instant.physicalRejected stage=after reason=\(reason, privacy: .public)") })
            } : nil
            let directPlan = directInventory.flatMap { inventory -> MenuBarCollapsePlan? in
                guard let targets = try? inventory.collapseTargetBundleIdentifiers(protectionPolicy: self.collapseProtectionPolicy)
                    , let beforeTargets, Set(targets) == Set(beforeTargets)
                else { return nil }
                return try? MenuBarCollapsePlan(runningBundleIdentifiers: Set(currentApplications.map(\.bundleIdentifier)),
                    targetBundleIdentifiers: Set(targets), protectionPolicy: self.collapseProtectionPolicy)
            }
            let plan: MenuBarCollapsePlan?
            let preparedInventory: AnchoredMenuBarInventory?
            let preparedTopology: MenuBarTopologySnapshot?
            if let directPlan, let directInventory, let physicalTopology {
                plan = directPlan
                preparedInventory = directInventory
                preparedTopology = physicalTopology
            } else if !canReadCurrentPhysical, let rawPrepared, let raw {
                let currentPhysical = rawPrepared.currentPhysicalPlan(
                    structure: raw, applicationsBeforeRead: applications,
                    applications: currentApplications, contextRevision: self.instantContextRevision,
                    protectionPolicy: self.collapseProtectionPolicy,
                    ownedStatusItems: owned,
                    onReject: { reason in
                        self.logger.notice("menuBar.instant.currentPhysicalRejected reason=\(reason, privacy: .public)")
                    }
                )
                let legacyPlan = rawPrepared.hasIndependentPhysicalBaseline ? nil : rawPrepared.planIfUnchanged(
                    structure: raw, applicationsBeforeRead: applications,
                    applications: currentApplications,
                    contextRevision: self.instantContextRevision,
                    protectionPolicy: self.collapseProtectionPolicy
                )
                plan = currentPhysical?.plan ?? legacyPlan
                preparedInventory = currentPhysical?.inventory ?? (legacyPlan != nil ? rawPrepared.inventory : nil)
                if let currentPhysical {
                    self.logger.info("menuBar.instant.currentPhysicalAccepted items=\(currentPhysical.inventory.items.count, privacy: .public)")
                }
                preparedTopology = rawPrepared.topology
            } else if !canReadCurrentPhysical, let prepared, let physical {
                plan = prepared.planIfUnchanged(
                    physicalGuard: physical, applications: currentApplications,
                    contextRevision: self.instantContextRevision,
                    protectionPolicy: self.collapseProtectionPolicy
                )
                preparedInventory = prepared.inventory
                preparedTopology = prepared.topology
            } else {
                plan = nil; preparedInventory = nil; preparedTopology = nil
            }
            guard revision == self.instantContextRevision,
                  self.permissionStatus.accessibilityGranted,
                  self.environmentAllowsRecollapse, self.temporaryRevealInteractionIDs.isEmpty,
                  !self.isApplying, !self.isReading, !self.hasChanges,
                  !currentApplications.contains(where: {
                    $0.processIdentifier != ownPID
                        && MenuBarTargetProtectionPolicy.isKnownManager(
                            bundleIdentifier: $0.bundleIdentifier, name: $0.name
                        )
                  }),
                  let plan, let preparedInventory, let preparedTopology else {
                self.isPreparingCollapse = false
                self.invalidateInstantPreparation()
                self.logger.notice(
                    "menuBar.instant.guardRejected rawComplete=\(raw?.isComplete ?? false, privacy: .public) rawNodes=\(raw?.nodeCount ?? 0, privacy: .public) reasons=\(raw?.diagnostics.summary ?? physical?.physicalGuardDiagnostics.summary ?? "missing", privacy: .public)"
                )
                self.scheduleSafeRecollapse(
                    trigger: "重新校验菜单栏", delay: .zero,
                    continuingRecovery: true, preferRetainedInventoryFastPath: true
                )
                return
            }
            self.inventory = preparedInventory
            // The physical source has fresh item IDs. We already rejected any
            // unapplied user draft above; reconcile the untouched draft now so
            // the next click is not falsely blocked as an unsaved reorder.
            if let layouts = try? preparedInventory.validatedLayouts(),
               !layouts.contains(where: { $0.displayID == self.selectedDisplayID }) {
                self.selectedDisplayID = layouts.first?.displayID ?? 0
            }
            self.draftIDs = self.selectedLayout?.orderedItems.map(\.id) ?? []
            if canReadCurrentPhysical { self.directPhysicalTopology = preparedTopology }
            self.logger.info(
                "menuBar.instant.guardAccepted durationMs=\(Self.elapsedMilliseconds(since: startedAt), privacy: .public)"
            )
            self.beginPersistentCollapse(
                topology: preparedTopology, plan: plan, intentGeneration: generation
            )
        }
    }

    private func cancelRevealedAutoRecollapse() {
        revealedAutoRecollapseID = nil
        revealedAutoRecollapseTask?.cancel()
        revealedAutoRecollapseTask = nil
    }

    private func scheduleRevealedAutoRecollapse() {
        cancelRevealedAutoRecollapse()
        guard !nativeSafetyBlocked, wantsPersistentCollapse, isEnabled, !isTerminating,
              environmentAllowsRecollapse else { return }
        let operationID = UUID()
        let generation = visibilityIntentGeneration
        let runtime = collapseRuntime
        revealedAutoRecollapseID = operationID
        revealedAutoRecollapseTask = startTrackedTask { [weak self] in
            var delay = Duration.seconds(self?.autoHideDelaySeconds ?? MenuBarAutoHideDelay.defaultSeconds)
            var lastActivity: MenuBarAutomaticRecollapseActivitySnapshot?
            while !Task.isCancelled {
                do { try await runtime.revealSleep(delay) }
                catch { return }
                guard let self, !Task.isCancelled,
                      self.revealedAutoRecollapseID == operationID,
                      self.visibilityIntentGeneration == generation,
                      self.userVisibilityIntent == .revealed,
                      self.wantsPersistentCollapse, self.isEnabled,
                      !self.isTerminating, self.environmentAllowsRecollapse else { return }
                delay = runtime.revealActivityPollingDelay
                guard !self.isApplying, !self.isReading, !self.isPreparingCollapse, !self.hasChanges,
                      self.temporaryRevealInteractionIDs.isEmpty else { continue }
                let activity = await runtime.revealActivity()
                guard !Task.isCancelled,
                      self.revealedAutoRecollapseID == operationID,
                      self.visibilityIntentGeneration == generation else { return }
                guard !self.isApplying, !self.isReading, !self.isPreparingCollapse, !self.hasChanges,
                      self.temporaryRevealInteractionIDs.isEmpty else { continue }
                guard activity.isReadable, !activity.pointerInsideMenuBar,
                      !activity.hasPressedMouseButtons,
                      !activity.hasOpenMenuOrPopover else {
                    if activity.deferralSignature != lastActivity?.deferralSignature {
                        self.logger.info(
                            "menuBar.reveal.autoDeferred readable=\(activity.isReadable, privacy: .public) pointer=\(activity.pointerInsideMenuBar, privacy: .public) buttons=\(activity.hasPressedMouseButtons, privacy: .public) menu=\(activity.hasOpenMenuOrPopover, privacy: .public) windowClasses=\(activity.diagnostics.summary, privacy: .public)"
                        )
                        lastActivity = activity
                    }
                    continue
                }
                self.revealedAutoRecollapseID = nil
                self.revealedAutoRecollapseTask = nil
                self.setUserVisibilityIntent(.collapsed)
                self.logger.info("menuBar.reveal.autoRecollapse")
                self.requestImmediateRecollapse()
                return
            }
        }
    }

    func prepareForOrderEditing() {
        guard !isTerminating, !isApplying else { return }
        cancelAutomaticRecollapse()
        expandLeftSide(reason: nil)
        message = "已暂停本轮自动收起，可调整菜单栏左右分组。"
        note(message)
    }

    /// Prevents lifecycle observers from rebuilding the hiding assertion while
    /// a proxy item is opening and tracking its real menu.
    func beginTemporaryRevealInteraction() -> UUID? {
        guard wantsPersistentCollapse, userVisibilityIntent == .collapsed,
              isEnabled, !isTerminating else { return nil }
        if temporaryRevealInteractionIDs.isEmpty {
            pendingTemporaryRevealResolution = PendingTemporaryRevealResolution()
        }
        let token = UUID()
        temporaryRevealInteractionIDs.insert(token)
        cancelAutomaticRecollapse()
        expandLeftSide(reason: "左侧图标已临时展开。")
        return token
    }

    func endTemporaryRevealInteraction(
        _ token: UUID,
        shouldRecollapse: Bool,
        keepExpandedAsUserIntent: Bool = false,
        delay: Duration = .milliseconds(350)
    ) {
        guard temporaryRevealInteractionIDs.remove(token) != nil else { return }
        pendingTemporaryRevealResolution.merge(
            shouldRecollapse: shouldRecollapse,
            keepExpanded: keepExpandedAsUserIntent,
            delay: delay
        )
        guard temporaryRevealInteractionIDs.isEmpty else { return }
        let resolution = pendingTemporaryRevealResolution
        pendingTemporaryRevealResolution = PendingTemporaryRevealResolution()
        let trigger = pendingRecollapseTrigger ?? "交互结束"
        pendingRecollapseTrigger = nil
        if resolution.keepExpanded {
            setUserVisibilityIntent(.revealed)
            cancelAutomaticRecollapse()
            return
        }
        guard resolution.shouldRecollapse else { return }
        scheduleSafeRecollapse(
            trigger: trigger,
            delay: resolution.recollapseDelay ?? delay
        )
    }

    func dismissChangePresentation(id: UUID?) {
        guard let id, changePresentation?.id == id else { return }
        changePresentation = nil
    }

    /// Rebuilds the collapse plan from a fresh, complete inventory after an interaction.
    /// An explicit click may retain the pre-reveal inventory only as the exact
    /// `before` baseline; the executable plan is always rebuilt from fresh data.
    func requestRecollapseAfterInteraction(
        delay: Duration = .seconds(4),
        preferRetainedInventoryFastPath: Bool = false
    ) {
        scheduleSafeRecollapse(
            trigger: "交互结束",
            delay: delay,
            preferRetainedInventoryFastPath: preferRetainedInventoryFastPath
        )
    }

    private func collapseLeftSide(
        intentGeneration: UInt64,
        captureOptionalQuickBarIcons: Bool = true
    ) {
        guard collapseIntentIsCurrent(intentGeneration) else { return }
        refreshPermissions()
        if let reason = collapseBlockingReason {
            message = reason
            note(reason)
            recoverAutomaticCollapseIfNeeded(reason: reason, retryable: hasTransientCollapseBlocker)
            return
        }
        guard let inventory else { return }

        do {
            let targets = Set(try inventory.collapseTargetBundleIdentifiers(
                protectionPolicy: collapseProtectionPolicy
            ))
            let applications = collapseRuntime.applications()
            let anchorIdentity = Self.anchorIdentity
            let ownPID = ownPID
            let collapseProtectionPolicy = collapseProtectionPolicy
            let discoveryProtectionPolicy = protectionPolicy
            let captureQuickBarIcons = captureQuickBarIcons
            let runtime = collapseRuntime
            let logger = logger
            let instantRevision = instantContextRevision
            let snapshotItems = (try? inventory.validatedLayouts())?
                .flatMap(\.leftItems)
                .filter { targets.contains($0.bundleIdentifier) } ?? []
            // Never reuse an older visual after a fresh scan. A failed capture
            // falls back to application icons without blocking the hide request.
            quickBarIconSnapshots = [:]
            isPreparingCollapse = true
            message = "正在复核拓扑并保存收起计划；尚未调用系统隐藏。"
            collapsePreparationTask = startTrackedTask { [weak self] in
                let preparationStartedAt = ProcessInfo.processInfo.systemUptime
                let beforeTopologyStartedAt = ProcessInfo.processInfo.systemUptime
                let initialTopology = await runtime.topologySnapshot(applications)
                let beforeTopologyMilliseconds = Self.elapsedMilliseconds(
                    since: beforeTopologyStartedAt
                )
                guard !Task.isCancelled else { return }
                let snapshots: [String: MenuBarQuickBarIconSnapshot]
                if captureOptionalQuickBarIcons {
                    snapshots = await captureQuickBarIcons(snapshotItems)
                } else {
                    snapshots = [:]
                }
                guard !Task.isCancelled else { return }
                let rawApplicationsBefore = runtime.applications()
                let rawBefore = runtime.rawStructureGuardEnabled
                    ? await runtime.rawPhysicalStructure(rawApplicationsBefore) : nil
                guard !Task.isCancelled else { return }
                let freshApplications = runtime.applications()
                let freshDiscoverStartedAt = ProcessInfo.processInfo.systemUptime
                let freshResult = await runtime.discover(
                    freshApplications, anchorIdentity, ownPID, discoveryProtectionPolicy
                )
                let freshDiscoverMilliseconds = Self.elapsedMilliseconds(
                    since: freshDiscoverStartedAt
                )
                let afterTopologyStartedAt = ProcessInfo.processInfo.systemUptime
                let topology = await runtime.topologySnapshot(runtime.applications())
                let afterTopologyMilliseconds = Self.elapsedMilliseconds(
                    since: afterTopologyStartedAt
                )
                guard !Task.isCancelled else { return }
                let rawApplicationsAfter = runtime.applications()
                let rawAfter = runtime.rawStructureGuardEnabled
                    ? await runtime.rawPhysicalStructure(rawApplicationsAfter) : nil
                let physical = runtime.rawStructureGuardEnabled ? nil
                    : await runtime.physicalGuard(
                        freshApplications, anchorIdentity, ownPID, discoveryProtectionPolicy
                    )
                guard let self,
                      !Task.isCancelled,
                      self.isPreparingCollapse,
                      self.collapseIntentIsCurrent(intentGeneration),
                      anchorIdentity == Self.anchorIdentity,
                      ownPID == self.ownPID,
                      collapseProtectionPolicy.ownBundleIdentifier == AppConstants.bundleIdentifier else { return }
                self.collapsePreparationTask = nil
                self.isPreparingCollapse = false
                guard self.instantContextRevision == instantRevision else {
                    self.expandLeftSide(reason: nil)
                    self.message = "收起准备期间应用或会话状态已变化，保持展开并重新复核。"
                    self.note(self.message)
                    self.recoverAutomaticCollapseIfNeeded(reason: self.message, retryable: true)
                    return
                }
                self.acceptInventory(freshResult, operationID: UUID())
                guard MenuBarCollapsePreparationValidation.isUnchanged(
                    before: inventory,
                    after: freshResult.inventory,
                    initialTopology: initialTopology,
                    finalTopology: topology
                ) else {
                    self.expandLeftSide(reason: nil)
                    self.message = "收起准备期间菜单栏发生变化，已保持展开；请核对新清单后重试。"
                    self.note(self.message)
                    self.recoverAutomaticCollapseIfNeeded(reason: self.message, retryable: true)
                    return
                }
                if let reason = self.collapseBlockingReason {
                    self.expandLeftSide(reason: nil)
                    self.message = "收起未开始：\(reason)"
                    self.note(self.message)
                    self.recoverAutomaticCollapseIfNeeded(
                        reason: self.message, retryable: self.hasTransientCollapseBlocker
                    )
                    return
                }
                do {
                    // Build the native allow-list only from the final verified
                    // inventory and current applications, never from the plan
                    // that existed before optional visual capture.
                    let freshTargets = Set(try freshResult.inventory.collapseTargetBundleIdentifiers(
                        protectionPolicy: collapseProtectionPolicy
                    ))
                    let currentApplications = runtime.applications()
                    let providerIsCurrent = !runtime.rawStructureGuardEnabled || (
                        MenuBarInstantStructureCollapsePreparation.providerPID(currentApplications) != nil
                            && MenuBarInstantStructureCollapsePreparation.providerPID(currentApplications)
                                == MenuBarInstantStructureCollapsePreparation.providerPID(freshApplications)
                    )
                    guard let currentTargetProcesses = MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                        applications: currentApplications, targetBundleIdentifiers: freshTargets
                    ), currentTargetProcesses == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                        applications: freshApplications, targetBundleIdentifiers: freshTargets
                    ), MenuBarInstantCollapsePreparation.targetItemsBelongToRunningProcesses(
                        freshResult.inventory.items, targetProcessIdentifiers: currentTargetProcesses
                    ), providerIsCurrent, !currentApplications.contains(where: {
                        $0.processIdentifier != ownPID
                            && MenuBarTargetProtectionPolicy.isKnownManager(
                                bundleIdentifier: $0.bundleIdentifier, name: $0.name
                            )
                    }) else {
                        self.expandLeftSide(reason: nil)
                        self.message = "收起准备期间应用进程已变化，保持展开并重新复核。"
                        self.note(self.message)
                        self.recoverAutomaticCollapseIfNeeded(reason: self.message, retryable: true)
                        return
                    }
                    let plan = try MenuBarCollapsePlan(
                        runningBundleIdentifiers: Set(currentApplications.map(\.bundleIdentifier)),
                        targetBundleIdentifiers: freshTargets,
                        protectionPolicy: collapseProtectionPolicy
                    )
                    if self.instantContextRevision == instantRevision {
                        self.instantPreparation = physical.flatMap {
                            MenuBarInstantCollapsePreparation(
                                discovery: freshResult, physicalGuard: $0, topology: topology,
                                applications: freshApplications, contextRevision: instantRevision,
                                protectionPolicy: collapseProtectionPolicy
                            )
                        }
                        if let rawBefore, let rawAfter {
                            self.instantStructurePreparation = MenuBarInstantStructureCollapsePreparation(
                                discovery: freshResult, before: rawBefore, after: rawAfter,
                                topology: topology, applicationsBefore: rawApplicationsBefore,
                                applicationsDuring: freshApplications,
                                applicationsAfter: rawApplicationsAfter,
                                contextRevision: instantRevision,
                                protectionPolicy: collapseProtectionPolicy
                            )
                        }
                    }
                    logger.info(
                        "menuBar.instant.prepared ready=\(self.instantPreparation != nil || self.instantStructurePreparation != nil, privacy: .public) fullItems=\(freshResult.inventory.items.count, privacy: .public) physicalItems=\(freshResult.physicalItems.count, privacy: .public) rawComplete=\(rawBefore?.isComplete == true && rawAfter?.isComplete == true, privacy: .public) rawStable=\(rawBefore != nil && rawBefore?.revision == rawAfter?.revision, privacy: .public) rawNodes=\(rawAfter?.nodeCount ?? 0, privacy: .public) rawReasons=\(rawAfter?.diagnostics.summary ?? "disabled", privacy: .public)"
                    )
                    self.quickBarIconSnapshots = snapshots
                    self.isPreparingCollapse = true
                    logger.info(
                        "menuBar.collapse.phase phase=preparationComplete durationMs=\(Self.elapsedMilliseconds(since: preparationStartedAt), privacy: .public) beforeTopologyMs=\(beforeTopologyMilliseconds, privacy: .public) freshDiscoverMs=\(freshDiscoverMilliseconds, privacy: .public) afterTopologyMs=\(afterTopologyMilliseconds, privacy: .public) explicitFast=\(!captureOptionalQuickBarIcons, privacy: .public)"
                    )
                    self.beginPersistentCollapse(
                        topology: topology,
                        plan: plan,
                        intentGeneration: intentGeneration
                    )
                } catch {
                    self.expandLeftSide(reason: nil)
                    self.message = "收起未开始：\(error.localizedDescription)"
                    self.note(self.message)
                    self.automaticRecovery.cancel()
                }
            }
        } catch {
            message = "收起未开始：\(error.localizedDescription)"
            note(message)
            automaticRecovery.cancel()
        }
    }

    private func beginPersistentCollapse(
        topology: MenuBarTopologySnapshot,
        plan: MenuBarCollapsePlan,
        intentGeneration: UInt64
    ) {
        guard isCollapseAvailable, isPreparingCollapse,
              collapseIntentIsCurrent(intentGeneration),
              let token = persistentSession.begin(
                topologyRevision: topology.structuralRevision
              ) else {
            expandLeftSide(reason: "收起准备已失效，保持展开。")
            return
        }

        let record = PersistentMenuBarCollapseRecord(
            savedAt: Date(),
            topologyRevision: topology.structuralRevision,
            plan: plan
        )
        do {
            try FileManager.default.createDirectory(
                at: storageRootURL,
                withIntermediateDirectories: true
            )
            try PersistentMenuBarCollapseJournal.save(record, to: collapseRecordURL)
        } catch {
            _ = persistentSession.planPersistenceCompleted(
                token: token,
                succeeded: false,
                failureReason: "收起计划保存失败：\(error.localizedDescription)"
            )
            expandLeftSide(reason: "收起计划保存失败，保持展开。")
            automaticRecovery.cancel()
            return
        }

        guard persistentSession.planPersistenceCompleted(token: token, succeeded: true)
                == .beginNative(token: token) else {
            expandLeftSide(reason: "收起状态已变化，保持展开。")
            return
        }

        activeCollapsePlan = plan
        activeTopologySnapshot = topology
        lastTopologyIssueSummary = nil

        let nativeStartedAt = ProcessInfo.processInfo.systemUptime
        let ownedBeforeActivation = ownedStatusItemEvidence()
        logger.info("menuBar.collapse.native.begin targets=\(plan.targetBundleIdentifiers.count, privacy: .public) allowed=\(plan.allowedBundleIdentifiers.count, privacy: .public) ownAllowed=\(plan.allowedBundleIdentifiers.contains(AppConstants.bundleIdentifier), privacy: .public) ownTarget=\(plan.targetBundleIdentifiers.contains(AppConstants.bundleIdentifier), privacy: .public)")
        visibilityAssertion = collapseRuntime.begin(plan) { [weak self] error in
            guard let self else { return }
            self.startTrackedTask { [weak self] in
                guard let self,
                      self.collapseIntentIsCurrent(intentGeneration) else { return }
                if let error {
                    let action = self.persistentSession.fail(
                        token: token,
                        reason: "收起失败：\(error.localizedDescription)"
                    )
                    if action == .releaseNativeAssertion {
                        self.releasePersistentAssertion(
                            reason: "收起失败：\(error.localizedDescription)"
                        )
                        self.recoverAutomaticCollapseIfNeeded(reason: self.message, retryable: true)
                    }
                } else {
                    guard !Task.isCancelled, self.collapseIntentIsCurrent(intentGeneration),
                          self.persistentSession.isCurrent(token) else { return }
                    // DEMO parity: native acknowledgement owns the assertion's
                    // lifetime. Post-activation AX nodes are not screen proof
                    // and must not undo a successful request. Only a definite
                    // loss reported by our actual local entry owner is fatal.
                    let localEntryWasRemoved = ownedBeforeActivation?.mainEntryVisible == true
                        && self.ownedStatusItemEvidence()?.mainEntryVisible == false
                    guard !localEntryWasRemoved else {
                        self.nativeSafetyBlocked = true
                        self.logger.error("menuBar.collapse.localEntryRemoved restoreRequested=true retryBlocked=true")
                        self.cancelAutomaticRecollapse()
                        self.automaticRecovery.cancel()
                        self.setUserVisibilityIntent(.revealed)
                        self.expandLeftSide(reason: "未能确认入口和保留图标仍可见，已请求恢复展开；本次运行不再尝试隐藏。")
                        return
                    }
                    guard self.persistentSession.confirm(token: token) else { return }
                    self.collapseTimeoutTask?.cancel()
                    self.collapseTimeoutTask = nil
                    self.isPreparingCollapse = false
                    self.isCollapsed = true
                    self.automaticRecovery.succeeded()
                    self.message = "系统已接受持续收起请求；从入口或本页可随时展开，实际图标以屏幕显示为准。"
                    self.note(self.message)
                    self.logger.info("menuBar.collapse.nativeAcknowledged visualVerified=false demoParity=true durationMs=\(Self.elapsedMilliseconds(since: nativeStartedAt), privacy: .public)")
                    self.startTopologyMonitoring(token: token)
                }
            }
        }
        guard visibilityAssertion != nil else {
            _ = persistentSession.fail(token: token, reason: "系统没有创建持续收起请求。")
            releasePersistentAssertion(reason: "系统没有创建持续收起请求，保持展开。")
            recoverAutomaticCollapseIfNeeded(reason: message, retryable: true)
            return
        }

        systemPanelAccessMonitor.start(
            clockFrames: inventory?.items.filter {
                $0.accessibilityIdentifier == "com.apple.menuextra.clock"
            }.map(\.frame) ?? []
        ) { [weak self] in
            self?.prepareForSystemPanelAccess()
        }

        collapseTimeoutTask?.cancel()
        let confirmationTimeout = collapseRuntime.nativeConfirmationTimeout
        collapseTimeoutTask = startTrackedTask { [weak self] in
            try? await Task.sleep(for: confirmationTimeout)
            guard let self,
                  !Task.isCancelled,
                  self.persistentSession.isCurrent(token),
                  self.isPreparingCollapse,
                  self.collapseIntentIsCurrent(intentGeneration) else { return }
            _ = self.persistentSession.fail(
                token: token,
                reason: "系统收起请求 3 秒内没有确认。"
            )
            self.releasePersistentAssertion(reason: "系统收起请求超时，已展开。")
            self.recoverAutomaticCollapseIfNeeded(reason: self.message, retryable: true)
        }
    }

    func expandLeftSide(
        reason: String? = "已展开分界左侧图标。",
        preserveInstantPreparation: Bool = false
    ) {
        systemPanelAccessMonitor.stop()
        cancelRevealedAutoRecollapse()
        if !preserveInstantPreparation { invalidateInstantPreparation() }
        collapsePreparationTask?.cancel()
        collapsePreparationTask = nil
        collapseTimeoutTask?.cancel()
        collapseTimeoutTask = nil
        applicationTopologyDebounceTask?.cancel()
        applicationTopologyDebounceTask = nil
        _ = persistentSession.endCurrent()
        visibilityAssertion?.invalidate()
        visibilityAssertion = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
        topologyReadTask?.cancel()
        activeCollapsePlan = nil
        activeTopologySnapshot = nil
        changePresentation = nil
        lastTopologyIssueSummary = nil
        let wasActive = isPreparingCollapse || isCollapsed
        isPreparingCollapse = false
        isCollapsed = false
        do {
            try PersistentMenuBarCollapseJournal.remove(at: collapseRecordURL)
        } catch {
            note("系统隐藏已释放，但收起记录未能删除：\(error.localizedDescription)")
        }
        if let reason, wasActive {
            message = reason
            note(reason)
        }
    }

    private func scheduleSafeRecollapse(
        trigger: String,
        delay: Duration = .milliseconds(850),
        continuingRecovery: Bool = false,
        preferRetainedInventoryFastPath: Bool = false
    ) {
        cancelAutomaticRecollapse(cancelRecovery: !continuingRecovery)
        guard !nativeSafetyBlocked, wantsPersistentCollapse,
              userVisibilityIntent == .collapsed,
              isEnabled,
              isCollapseAvailable,
              !isTerminating,
              environmentAllowsRecollapse else { return }
        guard temporaryRevealInteractionIDs.isEmpty else {
            pendingRecollapseTrigger = trigger
            return
        }
        pendingRecollapseTrigger = nil
        if !continuingRecovery { automaticRecovery.begin() }

        let operationID = UUID()
        let intentGeneration = visibilityIntentGeneration
        let sleep = collapseRuntime.sleep
        automaticRecollapseID = operationID
        automaticRecollapseTask = startTrackedTask { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.automaticRecollapseID == operationID,
                  self.collapseIntentIsCurrent(intentGeneration) else { return }
            if preferRetainedInventoryFastPath,
               self.canUseRetainedInventoryForExplicitRecollapse {
                self.logger.info("menuBar.collapse.explicitFastPath selected=true")
                self.finishAutomaticRecollapse(operationID: operationID)
                self.collapseLeftSide(
                    intentGeneration: intentGeneration,
                    captureOptionalQuickBarIcons: false
                )
                return
            }
            if preferRetainedInventoryFastPath {
                self.logger.info("menuBar.collapse.explicitFastPath selected=false")
            }
            await self.performSafeRecollapse(
                operationID: operationID,
                trigger: trigger,
                intentGeneration: intentGeneration
            )
        }
    }

    /// A retained inventory is only a baseline for the exact validation in
    /// `collapseLeftSide`; it never authorizes a native plan by itself.
    private var canUseRetainedInventoryForExplicitRecollapse: Bool {
        refreshPermissions()
        guard environmentAllowsRecollapse,
              !isApplying,
              !isReading,
              !isPreparingCollapse,
              !isCollapsed,
              permissionStatus.accessibilityGranted,
              let inventory,
              inventory.coverage.isComplete,
              let layouts = try? inventory.validatedLayouts(),
              !layouts.isEmpty else { return false }
        return collapseBlockingReason == nil
    }

    private nonisolated static func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private func performSafeRecollapse(
        operationID: UUID,
        trigger: String,
        intentGeneration: UInt64
    ) async {
        guard automaticRecollapseID == operationID,
              collapseIntentIsCurrent(intentGeneration),
              isEnabled,
              isCollapseAvailable,
              !isTerminating,
              environmentAllowsRecollapse else {
            finishAutomaticRecollapse(operationID: operationID)
            return
        }
        refreshPermissions()
        guard permissionStatus.accessibilityGranted else {
            failAutomaticRecollapse(
                operationID: operationID,
                reason: "长期收起等待辅助功能权限；当前保持展开。",
                retryable: true
            )
            return
        }
        guard !isApplying, !isReading else {
            failAutomaticRecollapse(
                operationID: operationID,
                reason: "当前操作尚未结束，长期收起暂时保持展开。",
                retryable: true
            )
            return
        }
        if isCollapsed {
            finishAutomaticRecollapse(operationID: operationID)
            return
        }
        if isPreparingCollapse {
            expandLeftSide(reason: nil)
        }

        // Our own AppKit menu can no longer be read off-main (crash fix).
        // Bootstrap with the same TWO fresh physical proofs as an entry click,
        // once per bounded recovery attempt. A rejected startup proxy must be
        // sampled afresh on the next retry, without resetting the retry budget.
        if canBootstrapCurrentPhysicalRead,
           physicalBootstrapGeneration != intentGeneration {
            physicalBootstrapGeneration = intentGeneration
            finishAutomaticRecollapse(operationID: operationID)
            requestImmediateRecollapse(continuingRecovery: true)
            return
        }

        inventory = nil
        draftIDs = []
        isReading = true
        automaticReadID = operationID
        message = "\(trigger)：正在重新读取真实菜单栏，确认安全后恢复长期收起。"
        note(message)

        let applications = collapseRuntime.applications()
        let anchorIdentity = Self.anchorIdentity
        let ownPID = ownPID
        let protectionPolicy = protectionPolicy
        let result = await collapseRuntime.discover(
            applications, anchorIdentity, ownPID, protectionPolicy
        )

        guard !Task.isCancelled,
              automaticRecollapseID == operationID,
              automaticReadID == operationID,
              collapseIntentIsCurrent(intentGeneration) else { return }
        automaticReadID = nil
        isReading = false
        acceptInventory(result, operationID: operationID)

        guard collapseIntentIsCurrent(intentGeneration),
              environmentAllowsRecollapse,
              !isTerminating else {
            finishAutomaticRecollapse(operationID: operationID)
            return
        }
        if let reason = collapseBlockingReason {
            failAutomaticRecollapse(
                operationID: operationID,
                reason: "长期收起未恢复：\(reason) 当前保持展开。",
                retryable: hasTransientCollapseBlocker
            )
            return
        }
        finishAutomaticRecollapse(operationID: operationID)
        collapseLeftSide(intentGeneration: intentGeneration,
            captureOptionalQuickBarIcons: explicitRecollapseGeneration != intentGeneration)
    }

    private func failAutomaticRecollapse(
        operationID: UUID, reason: String, retryable: Bool
    ) {
        guard automaticRecollapseID == operationID else { return }
        finishAutomaticRecollapse(operationID: operationID)
        expandLeftSide(reason: nil)
        message = reason
        note(reason)
        recoverAutomaticCollapseIfNeeded(reason: reason, retryable: retryable)
    }

    private var hasTransientCollapseBlocker: Bool {
        if !permissionStatus.accessibilityGranted || isApplying || isReading { return true }
        guard let inventory else { return true }
        return (try? inventory.validatedLayouts()) == nil
    }

    private func recoverAutomaticCollapseIfNeeded(reason: String, retryable: Bool) {
        guard automaticRecovery.isActive else { return }
        guard retryable, wantsPersistentCollapse, isEnabled, isCollapseAvailable,
              userVisibilityIntent == .collapsed,
              environmentAllowsRecollapse, !isTerminating,
              temporaryRevealInteractionIDs.isEmpty, !isCollapsed else {
            automaticRecovery.cancel()
            return
        }
        guard let delay = automaticRecovery.nextRetryDelay() else {
            message = "\(reason) 自动重试 3 次仍未就绪，当前保持展开；可在设置中查看原因并重新收起。"
            note(message)
            logger.notice("menuBar.collapseRecovery.exhausted")
            return
        }
        message = "\(reason) 将于 \(delay.components.seconds) 秒后自动重试（\(automaticRecovery.retryCount)/3）。"
        physicalBootstrapGeneration = nil
        note(message)
        logger.notice("menuBar.collapseRecovery.retry attempt=\(self.automaticRecovery.retryCount, privacy: .public)")
        scheduleSafeRecollapse(
            trigger: "等待菜单栏稳定后重试", delay: delay, continuingRecovery: true,
            preferRetainedInventoryFastPath: explicitRecollapseGeneration == visibilityIntentGeneration
        )
    }

    private func finishAutomaticRecollapse(operationID: UUID) {
        guard automaticRecollapseID == operationID else { return }
        if automaticReadID == operationID {
            automaticReadID = nil
            isReading = false
        }
        automaticRecollapseID = nil
        automaticRecollapseTask = nil
    }

    private func cancelAutomaticRecollapse(cancelRecovery: Bool = true) {
        if cancelRecovery { automaticRecovery.cancel() }
        automaticRecollapseTask?.cancel()
        automaticRecollapseTask = nil
        if let readID = automaticReadID, readID == automaticRecollapseID {
            automaticReadID = nil
            isReading = false
        }
        automaticRecollapseID = nil
    }

    func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        removeLifecycleObservers()
        activeTrackedTasks.values.forEach { $0.cancel() }
        invalidateInstantPreparation()
        cancelRevealedAutoRecollapse()
        setUserVisibilityIntent(.revealed)
        temporaryRevealInteractionIDs.removeAll()
        pendingTemporaryRevealResolution = PendingTemporaryRevealResolution()
        pendingRecollapseTrigger = nil
        readTask?.cancel()
        cancelAutomaticRecollapse()
        collapsePreparationTask?.cancel()
        collapseTimeoutTask?.cancel()
        lifecycleRecoveryTask?.cancel()
        if isApplying {
            cancellation?.cancel(reason: "应用正在退出")
            orderTask?.cancel()
            if activeLeaseToken != nil {
                MenuBarCommandDrag.releaseSyntheticInputForRecovery()
            }
        }
        isReading = false
        isApplying = false
        automaticReadID = nil
        executionID = nil
        cancellation = nil
        expandLeftSide(reason: nil)
        removeInputMonitors()
    }

    func shutdown() async {
        beginTermination()
        while !activeTrackedTasks.isEmpty {
            let activeTasks = Array(activeTrackedTasks.values)
            activeTasks.forEach { $0.cancel() }
            for task in activeTasks {
                await task.value
            }
        }
        if activeLeaseToken != nil {
            MenuBarCommandDrag.releaseSyntheticInputForRecovery()
            releaseActiveLease(reason: .applicationTermination)
        }
        removeLifecycleObservers()
        readTask = nil
        orderTask = nil
        collapsePreparationTask = nil
        collapseTimeoutTask = nil
        automaticRecollapseTask = nil
        applicationTopologyDebounceTask = nil
        lifecycleRecoveryTask = nil
        instantPreparationTask = nil
        instantPreparationTaskID = nil
        instantPreparation = nil
        instantStructurePreparation = nil
        directPhysicalTopology = nil
        revealedAutoRecollapseTask = nil
        revealedAutoRecollapseID = nil
        topologyReadTask = nil
        topologyReadID = nil
        automaticRecollapseID = nil
        automaticReadID = nil
        isReading = false
        isApplying = false
        isPreparingCollapse = false
        isCollapsed = false
    }

    private func startTopologyMonitoring(token: UUID) {
        topologyTimer?.invalidate()
        let timer = Timer(
            timeInterval: max(0.01, collapseRuntime.topologyMonitoringInterval),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkTopology(token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        topologyTimer = timer
    }

    private func checkTopology(token: UUID) {
        guard !isTerminating,
              persistentSession.isCurrent(token),
              isCollapsed,
              topologyReadID == nil,
              topologyReadTask == nil else { return }
        let readID = UUID()
        topologyReadID = readID
        let applications = collapseRuntime.applications()
        let runtime = collapseRuntime
        topologyReadTask = startTrackedTask { [weak self] in
            let snapshot = await runtime.topologySnapshot(applications)
            let wasCancelled = Task.isCancelled
            guard let self else { return }
            guard self.topologyReadID == readID else { return }
            self.topologyReadTask = nil
            self.topologyReadID = nil
            guard !wasCancelled else { return }
            guard self.persistentSession.isCurrent(token) else { return }
            self.acceptTopologySnapshot(snapshot, token: token)
        }
    }

    private func scheduleTopologyCheckAfterApplicationChange(token: UUID) {
        applicationTopologyDebounceTask?.cancel()
        let intentGeneration = visibilityIntentGeneration
        applicationTopologyDebounceTask = startTrackedTask { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.collapseIntentIsCurrent(intentGeneration),
                  self.persistentSession.isCurrent(token) else { return }
            self.applicationTopologyDebounceTask = nil
            self.checkTopology(token: token)
        }
    }

    private func acceptTopologySnapshot(
        _ snapshot: MenuBarTopologySnapshot,
        token: UUID
    ) {
        guard persistentSession.isCurrent(token), isCollapsed,
              let previous = activeTopologySnapshot else { return }

        // Each provider read is accepted atomically. Preserve old items only
        // for the exact unreadable process instance; a same-bundle helper must
        // not mask confirmed changes from its healthy sibling.
        let acceptedSnapshot = snapshot.preservingConfirmedItemsForUnreadableProviders(
            from: previous
        )
        let knownProviderKeys = Set(previous.items.map(\.provider.instanceKey))
        if snapshot.unreadableProviders.union(snapshot.ambiguousProviders).contains(where: {
            knownProviderKeys.contains($0.instanceKey)
        }) {
            invalidateInstantPreparation(preservePhysicalBaseline: true)
        }
        if snapshot.unreadableProviders.isEmpty {
            lastTopologyIssueSummary = nil
        } else {
            let providerKeys = snapshot.unreadableProviders
                .map(\.instanceKey)
                .sorted()
                .joined(separator: ",")
            let previousProviderKeys = Set(previous.items.map(\.provider.instanceKey))
            let retainedCount = snapshot.unreadableProviders.filter {
                previousProviderKeys.contains($0.instanceKey)
            }.count
            let summary = "状态项提供者暂不可读（\(providerKeys)）；已按进程实例保留 \(retainedCount) 个旧基线，其他增量继续处理。"
            if summary != lastTopologyIssueSummary {
                lastTopologyIssueSummary = summary
                note(summary)
                logger.notice(
                    "menuBar.topology.uncertain providers=\(snapshot.unreadableProviders.count, privacy: .public) retained=\(retainedCount, privacy: .public)"
                )
            }
        }
        let delta = MenuBarTopologyDelta.between(previous, acceptedSnapshot)
        activeTopologySnapshot = acceptedSnapshot
        if !delta.added.isEmpty || !delta.removed.isEmpty
            || !delta.restartedBundleIdentifiers.isEmpty {
            invalidateInstantPreparation(preservePhysicalBaseline: true)
        }
        guard !delta.isEmpty else { return }

        if !delta.weakMetadataChanged.isEmpty {
            logger.debug(
                "menuBar.topology.weakMetadataIgnored count=\(delta.weakMetadataChanged.count, privacy: .public)"
            )
        }
        let candidates = delta.presentationCandidates.filter(isHiddenByActivePlan)
        let proxies = candidates.map(makeChangeProxy)
        mergeChangePresentation(proxies: proxies, removed: delta.removed)
        if proxies.isEmpty {
            // Removals, ordinary weak-title refreshes, and changes to already
            // visible allow-listed providers never release the assertion or
            // erase an unrelated change batch that the user has not dismissed.
            return
        }

        message = "检测到 \(proxies.count) 个新增或状态变化项目；原隐藏项目继续收起，已在入口下方显示变化代理。"
        note(message)
        logger.info(
            "menuBar.topology.changeProxy items=\(proxies.count, privacy: .public) added=\(delta.added.count, privacy: .public) content=\(delta.contentChanged.count, privacy: .public)"
        )
    }

    private func mergeChangePresentation(
        proxies: [MenuBarQuickBarItem],
        removed: [MenuBarTopologyItemSnapshot]
    ) {
        let existing = changePresentation?.items ?? []
        let surviving = existing.filter { proxy in
            !removed.contains { removedItem in
                proxyRepresents(proxy, topologyItem: removedItem)
            }
        }
        var mergedByID = Dictionary(
            surviving.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var orderedIDs = surviving.map(\.id)
        for proxy in proxies {
            if mergedByID[proxy.id] == nil { orderedIDs.append(proxy.id) }
            mergedByID[proxy.id] = proxy
        }
        let merged = orderedIDs.compactMap { mergedByID[$0] }
        guard merged != existing else { return }
        changePresentation = merged.isEmpty
            ? nil
            : MenuBarChangePresentation(id: UUID(), items: merged)
    }

    private func proxyRepresents(
        _ proxy: MenuBarQuickBarItem,
        topologyItem: MenuBarTopologyItemSnapshot
    ) -> Bool {
        guard proxy.bundleIdentifier == topologyItem.provider.bundleIdentifier,
              proxy.processIdentifier == topologyItem.provider.processIdentifier else {
            return false
        }
        if let proxyIdentifier = proxy.accessibilityIdentifier,
           let itemIdentifier = topologyItem.accessibilityIdentifier {
            return proxyIdentifier == itemIdentifier
        }
        return proxy.id == "topology:\(topologyItem.key)"
    }

    private func isHiddenByActivePlan(_ item: MenuBarTopologyItemSnapshot) -> Bool {
        guard let plan = activeCollapsePlan else { return false }
        return plan.targetBundleIdentifiers.contains(item.provider.bundleIdentifier)
            || !plan.allowedBundleIdentifiers.contains(item.provider.bundleIdentifier)
    }

    private func makeChangeProxy(
        _ item: MenuBarTopologyItemSnapshot
    ) -> MenuBarQuickBarItem {
        let knownItems = (try? inventory?.validatedLayouts())?
            .flatMap(\.orderedItems) ?? []
        let exactKnown: MenuBarOrderItem? = {
            guard let identifier = item.accessibilityIdentifier else { return nil }
            let matches = knownItems.filter {
                $0.processIdentifier == item.provider.processIdentifier
                    && $0.bundleIdentifier == item.provider.bundleIdentifier
                    && $0.accessibilityIdentifier == identifier
            }
            return matches.count == 1 ? matches[0] : nil
        }()
        let weakReason = item.identityStrength == .weak
            ? "该项目缺少唯一 AX 标识；这里只显示应用级变化提示，不会猜测并点击某个真实图标。"
            : "当前原生接口不能只释放这一项；为避免点击时让整组图标出现，该变化代理仅用于提示。请单击入口显示全部后再操作。"
        return MenuBarQuickBarItem(
            id: exactKnown?.id ?? "topology:\(item.key)",
            bundleIdentifier: item.provider.bundleIdentifier,
            applicationName: item.provider.applicationName,
            itemTitle: item.displayLabel,
            processIdentifier: item.provider.processIdentifier,
            accessibilityIdentifier: item.accessibilityIdentifier,
            iconSnapshot: exactKnown.flatMap { quickBarIconSnapshots[$0.id] },
            isReorderable: false,
            isChangeProxy: true,
            activationBlockReason: weakReason
        )
    }

    private func releasePersistentAssertion(reason: String) {
        systemPanelAccessMonitor.stop()
        visibilityAssertion?.invalidate()
        visibilityAssertion = nil
        collapseTimeoutTask?.cancel()
        collapseTimeoutTask = nil
        topologyTimer?.invalidate()
        topologyTimer = nil
        topologyReadTask?.cancel()
        activeCollapsePlan = nil
        activeTopologySnapshot = nil
        changePresentation = nil
        lastTopologyIssueSummary = nil
        isPreparingCollapse = false
        isCollapsed = false
        try? PersistentMenuBarCollapseJournal.remove(at: collapseRecordURL)
        message = reason
        note(reason)
    }

    private func movableItemIDs(in layout: AnchoredMenuBarLayout) -> Set<String> {
        Set(layout.orderedItems.filter(canMove).map(\.id))
    }

    private func saveHistory(
        _ recovery: MenuBarOrderRecovery,
        label: String
    ) throws {
        try FileManager.default.createDirectory(
            at: historyRootURL,
            withIntermediateDirectories: true
        )
        let safeLabel = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let name = "\(safeLabel)-\(recovery.operationID.uuidString).json"
        try MenuBarOrderJournal.save(
            recovery,
            to: historyRootURL.appendingPathComponent(name)
        )
    }

    private func releaseActiveLease(reason: InputLeaseReleaseReason) {
        guard let lease = activeLeaseToken else { return }
        activeLeaseToken = nil
        if !releaseInputLease(lease, reason) {
            logger.error("menuBar.inputLease.releaseRejected operation=\(lease.operationID.uuidString, privacy: .public)")
        }
    }

    private func installInputMonitors(for token: OrderCancellation) -> Bool {
        removeInputMonitors()
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .flagsChanged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
        ]
        let observe: @Sendable (NSEvent) -> Void = { event in
            let kind: MenuBarOrderInputKind
            switch event.type {
            case .keyDown: kind = .keyDown
            case .flagsChanged: kind = .modifierChanged
            case .mouseMoved: kind = .mouseMoved
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                kind = .mouseDragged
            case .scrollWheel: kind = .scroll
            default: kind = .mouseButton
            }
            let cgEvent = event.cgEvent
            let sourcePID = cgEvent.flatMap {
                Int32(exactly: $0.getIntegerValueField(.eventSourceUnixProcessID))
            }
            if let reason = MenuBarOrderInputPolicy.cancellationReason(
                kind: kind,
                sourcePID: sourcePID,
                userData: cgEvent?.getIntegerValueField(.eventSourceUserData),
                keyCode: event.type == .keyDown ? event.keyCode : nil,
                ownPID: Int32(ProcessInfo.processInfo.processIdentifier),
                ownTag: OrderInputTag.value
            ) {
                token.cancel(humanInput: true, reason: reason)
            }
        }

        guard let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: observe
        ) else { return false }
        inputMonitors.append(global)
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            observe(event)
            return event
        }) {
            inputMonitors.append(local)
        }
        return true
    }

    private func removeInputMonitors() {
        inputMonitors.forEach(NSEvent.removeMonitor)
        inputMonitors.removeAll()
    }

    private func scheduleLifecycleRecoveryAfterWake() {
        guard !isTerminating else { return }
        lifecycleRecoveryTask?.cancel()
        lifecycleRecoveryTask = startTrackedTask { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isTerminating else { return }
            self.environmentAllowsRecollapse = true
            self.refreshPermissions()
            self.inventory = nil
            self.draftIDs = []
            if self.wantsPersistentCollapse {
                if self.userVisibilityIntent == .revealed {
                    self.startInstantPreparationWarmup()
                    self.scheduleRevealedAutoRecollapse()
                } else {
                    self.scheduleSafeRecollapse(
                        trigger: "会话已恢复",
                        delay: .milliseconds(350)
                    )
                }
            } else {
                self.message = "会话已恢复，真实菜单栏需要重新读取。"
            }
        }
    }

    private func installLifecycleObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let applicationEvents: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in applicationEvents {
            let observer = workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isTerminating else { return }
                    self.invalidateInstantPreparation()
                    if self.isApplying {
                        self.cancel(reason: "应用状态变化，正在停止排序并释放输入。")
                    }
                    if self.isCollapsed, let token = self.persistentSession.token {
                        self.scheduleTopologyCheckAfterApplicationChange(token: token)
                    } else if !self.isPreparingCollapse {
                        // An expanded inventory is now stale, but an application
                        // notification alone never overrides a user's reveal.
                        self.inventory = nil
                        self.draftIDs = []
                        self.startInstantPreparationWarmup()
                    }
                }
            }
            observers.append((workspace, observer))
        }

        let suspendingEvents: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in suspendingEvents {
            let observer = workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isTerminating else { return }
                    if self.isApplying {
                        self.cancel(reason: "应用或系统状态变化，正在停止排序并释放输入。")
                    }
                    self.environmentAllowsRecollapse = false
                    self.lifecycleRecoveryTask?.cancel()
                    self.lifecycleRecoveryTask = nil
                    self.invalidateInstantPreparation()
                    self.cancelRevealedAutoRecollapse()
                    self.cancelAutomaticRecollapse()
                    if self.isPreparingCollapse || self.isCollapsed {
                        self.expandLeftSide(reason: "系统会话暂停，已自动展开。")
                    }
                    self.inventory = nil
                    self.draftIDs = []
                }
            }
            observers.append((workspace, observer))
        }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let observer = workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isTerminating else { return }
                    self.scheduleLifecycleRecoveryAfterWake()
                }
            }
            observers.append((workspace, observer))
        }

        let center = NotificationCenter.default
        let activeObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTerminating else { return }
                let previouslyGranted = self.permissionStatus.accessibilityGranted
                self.refreshPermissions()
                if MenuBarAutomaticCollapseRecovery.shouldResumeAfterPermissionChange(
                    previouslyGranted: previouslyGranted,
                    nowGranted: self.permissionStatus.accessibilityGranted,
                    wantsPersistentCollapse: self.wantsPersistentCollapse,
                    isEnabled: self.isEnabled,
                    isExpanded: !self.isCollapsed && !self.isPreparingCollapse,
                    hasInteraction: !self.temporaryRevealInteractionIDs.isEmpty,
                    isTerminating: self.isTerminating
                ) {
                    self.scheduleSafeRecollapse(trigger: "辅助功能权限已恢复")
                }
            }
        }
        observers.append((center, activeObserver))

        let screenObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTerminating else { return }
                self.cancel(reason: "显示器状态变化，正在停止排序并释放输入。")
                self.expandLeftSide(reason: "显示器状态变化，已自动展开。")
                self.inventory = nil
                self.draftIDs = []
                if self.wantsPersistentCollapse {
                    if self.userVisibilityIntent == .revealed {
                        self.startInstantPreparationWarmup()
                        self.scheduleRevealedAutoRecollapse()
                    } else {
                        self.scheduleSafeRecollapse(
                            trigger: "显示器状态变化",
                            delay: .milliseconds(1_100)
                        )
                    }
                }
            }
        }
        observers.append((center, screenObserver))
    }

    private func removeLifecycleObservers() {
        observers.forEach { center, observer in center.removeObserver(observer) }
        observers.removeAll()
    }

    private func validationMessage(for inventory: AnchoredMenuBarInventory) -> String {
        if inventory.coverage.expectedDisplayIDs.isEmpty
            || !inventory.coverage.unreadableDisplayIDs.isEmpty {
            return "系统菜单栏暂不可读；常见于锁屏、熄屏或唤醒重建。解锁后请重新读取。"
        }
        do {
            _ = try inventory.validatedLayouts()
            return "菜单栏读取完成。"
        } catch {
            return "菜单栏完整性未通过：\(error.localizedDescription)"
        }
    }

    private func note(_ value: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        notes.append("\(formatter.string(from: Date()))  \(value)")
        if notes.count > 100 {
            notes.removeFirst(notes.count - 100)
        }
    }

    private func saveSettings(
        isEnabled: Bool,
        wantsPersistentCollapse: Bool,
        primaryPresentationMode: MenuBarPrimaryPresentationMode,
        showQuickBarOnHover: Bool? = nil,
        iconStyle: MenuBarIconStyle? = nil,
        autoHideDelaySeconds: Int? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: storageRootURL,
            withIntermediateDirectories: true
        )
        let settings = MenuBarFeatureSettings(
            isEnabled: isEnabled,
            wantsPersistentCollapse: wantsPersistentCollapse,
            primaryPresentationMode: primaryPresentationMode,
            showQuickBarOnHover: showQuickBarOnHover ?? self.showQuickBarOnHover,
            iconStyle: iconStyle ?? self.iconStyle,
            autoHideDelaySeconds: autoHideDelaySeconds ?? self.autoHideDelaySeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    private static func loadSettings(from storageRootURL: URL) -> MenuBarFeatureSettings {
        let url = storageRootURL.appendingPathComponent("settings-v1.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(
                MenuBarFeatureSettings.self,
                from: data
              ),
              settings.schemaVersion == 1 else {
            return MenuBarFeatureSettings(
                isEnabled: false,
                wantsPersistentCollapse: false,
                primaryPresentationMode: .nativeMenuBar
            )
        }
        return settings
    }
}

private struct MenuBarFeatureSettings: Codable {
    let schemaVersion: Int
    let isEnabled: Bool
    let wantsPersistentCollapse: Bool
    let primaryPresentationMode: MenuBarPrimaryPresentationMode
    let showQuickBarOnHover: Bool
    let iconStyle: MenuBarIconStyle
    let autoHideDelaySeconds: Int

    init(
        isEnabled: Bool,
        wantsPersistentCollapse: Bool,
        primaryPresentationMode: MenuBarPrimaryPresentationMode,
        showQuickBarOnHover: Bool = false,
        iconStyle: MenuBarIconStyle = .display,
        autoHideDelaySeconds: Int = MenuBarAutoHideDelay.defaultSeconds
    ) {
        schemaVersion = 1
        self.isEnabled = isEnabled
        self.wantsPersistentCollapse = isEnabled && wantsPersistentCollapse
        self.primaryPresentationMode = primaryPresentationMode
        self.showQuickBarOnHover = showQuickBarOnHover
        self.iconStyle = iconStyle
        self.autoHideDelaySeconds = MenuBarAutoHideDelay.clamped(autoHideDelaySeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case wantsPersistentCollapse
        case primaryPresentationMode
        case showQuickBarOnHover
        case iconStyle
        case autoHideDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        // Existing enabled installations predate this field. Migrate them to the
        // requested resting state while still requiring a fresh safe scan at launch.
        wantsPersistentCollapse = try values.decodeIfPresent(
            Bool.self,
            forKey: .wantsPersistentCollapse
        ) ?? isEnabled
        primaryPresentationMode = try values.decodeIfPresent(
            MenuBarPrimaryPresentationMode.self,
            forKey: .primaryPresentationMode
        ) ?? .nativeMenuBar
        showQuickBarOnHover = try values.decodeIfPresent(Bool.self, forKey: .showQuickBarOnHover) ?? false
        let savedStyle = try values.decodeIfPresent(String.self, forKey: .iconStyle)
        iconStyle = savedStyle.flatMap(MenuBarIconStyle.init(rawValue:)) ?? .display
        autoHideDelaySeconds = MenuBarAutoHideDelay.clamped(
            try values.decodeIfPresent(Int.self, forKey: .autoHideDelaySeconds)
                ?? MenuBarAutoHideDelay.defaultSeconds
        )
    }
}
