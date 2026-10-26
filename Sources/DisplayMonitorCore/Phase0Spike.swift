import CoreGraphics
import Foundation

/// The Phase 0 probe is deliberately a contract and evidence layer. It does
/// not move third-party menu-bar items, own a real Shelf, or replace the
/// existing Monitor implementation.
public enum Phase0SpikeContract {
    public static let fixtureVersion = "shelf-spike-fixture-v1"
    public static let optionChordWindowMilliseconds = 150
    public static let minimumInputIterations = 100
    public static let safeVisibilityMode = "Shelf Safe Visibility Mode"
}

public enum Phase0Gate: String, CaseIterable, Codable, Sendable {
    case shelfRecovery
    case inputArbitration
    case regionPipelines
    case releaseTCC
    case statusItemLifecycle
}

// MARK: - Shelf classification and recovery contract

public struct MenuItemIdentity: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var titleFingerprint: String
    public var iconFingerprint: String?
    public var menuExtraIdentifier: String?

    public init(
        bundleID: String,
        titleFingerprint: String,
        iconFingerprint: String? = nil,
        menuExtraIdentifier: String? = nil
    ) {
        self.bundleID = bundleID
        self.titleFingerprint = titleFingerprint
        self.iconFingerprint = iconFingerprint
        self.menuExtraIdentifier = menuExtraIdentifier
    }
}

public enum ShelfZone: String, Codable, CaseIterable, Sendable {
    case visible
    case hidden
    case alwaysHidden
}

public enum ShelfItemClassification: String, Codable, CaseIterable, Sendable {
    case supported
    case protected
    case unsupported

    public var allowsMove: Bool {
        self == .supported
    }
}

public enum ShelfAXFailure: String, Codable, CaseIterable, Sendable {
    case none
    case apiDisabled
    case cannotComplete
    case identityUnstable
    case verificationFailed
}

public enum ShelfClassifier {
    public static func classify(
        isSystemItem: Bool,
        isToolSuiteItem: Bool,
        axAvailable: Bool,
        identityStable: Bool,
        canReadPosition: Bool,
        canWritePosition: Bool,
        failure: ShelfAXFailure = .none
    ) -> ShelfItemClassification {
        if isSystemItem || isToolSuiteItem {
            return .protected
        }
        if !axAvailable || failure == .apiDisabled || failure == .cannotComplete {
            return .unsupported
        }
        if !identityStable || failure == .identityUnstable || failure == .verificationFailed {
            return .unsupported
        }
        if !canReadPosition || !canWritePosition {
            return .protected
        }
        return .supported
    }
}

public struct ShelfSpikeFixture: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var shape: String
    public var expectedClassification: ShelfItemClassification

    public init(id: String, shape: String, expectedClassification: ShelfItemClassification) {
        self.id = id
        self.shape = shape
        self.expectedClassification = expectedClassification
    }
}

public enum ShelfSpikeFixtureCatalog {
    public static let version = Phase0SpikeContract.fixtureVersion

    public static let fixtures: [ShelfSpikeFixture] = [
        ShelfSpikeFixture(
            id: "F-1",
            shape: "一个可读写位置的单状态项",
            expectedClassification: .supported
        ),
        ShelfSpikeFixture(
            id: "F-2",
            shape: "同一进程两个可区分状态项",
            expectedClassification: .supported
        ),
        ShelfSpikeFixture(
            id: "F-3",
            shape: "延迟出现/重启后 PID 改变的状态项",
            expectedClassification: .supported
        ),
        ShelfSpikeFixture(
            id: "F-4",
            shape: "可枚举但位置属性不可写的状态项",
            expectedClassification: .protected
        ),
        ShelfSpikeFixture(
            id: "F-5",
            shape: "AX 返回 APIDisabled/CannotComplete 的模拟项目",
            expectedClassification: .unsupported
        ),
        ShelfSpikeFixture(
            id: "F-6",
            shape: "Apple 系统/Control Center 类项目",
            expectedClassification: .protected
        ),
        ShelfSpikeFixture(
            id: "F-7",
            shape: "ToolSuite Anchor + Monitor Activity Item",
            expectedClassification: .protected
        )
    ]
}

public struct MenuBarLayoutSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var visibleItems: [MenuItemIdentity]
    public var hiddenItems: [MenuItemIdentity]
    public var alwaysHiddenItems: [MenuItemIdentity]
    public var protectedItems: [MenuItemIdentity]
    public var anchorIdentity: MenuItemIdentity
    public var calibratedAt: Date

    public init(
        schemaVersion: Int = 1,
        visibleItems: [MenuItemIdentity] = [],
        hiddenItems: [MenuItemIdentity] = [],
        alwaysHiddenItems: [MenuItemIdentity] = [],
        protectedItems: [MenuItemIdentity] = [],
        anchorIdentity: MenuItemIdentity,
        calibratedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.visibleItems = visibleItems
        self.hiddenItems = hiddenItems
        self.alwaysHiddenItems = alwaysHiddenItems
        self.protectedItems = protectedItems
        self.anchorIdentity = anchorIdentity
        self.calibratedAt = calibratedAt
    }
}

public struct ShelfMoveOperation: Codable, Equatable, Sendable {
    public var itemIdentity: MenuItemIdentity
    public var from: ShelfZone
    public var to: ShelfZone
    public var inverseFrom: ShelfZone
    public var inverseTo: ShelfZone

    public init(itemIdentity: MenuItemIdentity, from: ShelfZone, to: ShelfZone) {
        self.itemIdentity = itemIdentity
        self.from = from
        self.to = to
        self.inverseFrom = to
        self.inverseTo = from
    }
}

public enum ShelfTransactionStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case applying
    case verifying
    case committed
    case rollbackRequired
    case rolledBack
}

public struct ShelfTransactionJournal: Codable, Equatable, Sendable {
    public var transactionID: UUID
    public var startedAt: Date
    public var beforeSnapshot: MenuBarLayoutSnapshot
    public var operations: [ShelfMoveOperation]
    public var nextOperationIndex: Int
    public var status: ShelfTransactionStatus

    public init(
        transactionID: UUID = UUID(),
        startedAt: Date = Date(),
        beforeSnapshot: MenuBarLayoutSnapshot,
        operations: [ShelfMoveOperation],
        nextOperationIndex: Int = 0,
        status: ShelfTransactionStatus = .planned
    ) {
        self.transactionID = transactionID
        self.startedAt = startedAt
        self.beforeSnapshot = beforeSnapshot
        self.operations = operations
        self.nextOperationIndex = nextOperationIndex
        self.status = status
    }

    public var requiresSafeStartup: Bool {
        switch status {
        case .applying, .verifying, .rollbackRequired:
            return true
        case .planned, .committed, .rolledBack:
            return false
        }
    }

    public var hasInverseForEveryOperation: Bool {
        operations.allSatisfy { $0.from == $0.inverseTo && $0.to == $0.inverseFrom }
    }
}

public enum ShelfStartupMode: String, Codable, Sendable {
    case normal
    case safeStartup
}

public enum ShelfRecoveryDecision: Equatable, Sendable {
    case normal
    case safeStartup(reason: String)
    case repairNeeded(reason: String)
}

public enum ShelfRecoveryPolicy {
    public static func decision(
        journal: ShelfTransactionJournal?,
        accessibilityAvailable: Bool
    ) -> ShelfRecoveryDecision {
        guard accessibilityAvailable else {
            return .repairNeeded(reason: "Accessibility 不可用，禁止继续拖动")
        }
        guard let journal else {
            return .normal
        }
        guard journal.hasInverseForEveryOperation else {
            return .repairNeeded(reason: "journal 缺少完整逆操作")
        }
        if journal.requiresSafeStartup {
            return .safeStartup(reason: "发现未完成 Shelf 事务，启动只读恢复")
        }
        return .normal
    }
}

/// The explicit No-Go fallback. It is a policy object only; it performs no
/// third-party menu-bar mutation.
public struct ShelfSafeVisibilityPolicy: Codable, Equatable, Sendable {
    public let reason: String
    public let allowsThirdPartyMoves: Bool
    public let exposesReadOnlyInventory: Bool
    public let preservesRecoveryActions: Bool

    public init(reason: String = "shelfNoGo") {
        self.reason = reason
        self.allowsThirdPartyMoves = false
        self.exposesReadOnlyInventory = true
        self.preservesRecoveryActions = true
    }
}

// MARK: - Input arbitration contract

public enum Phase0InputKey: String, Codable, CaseIterable, Sendable {
    case a
    case f1
    case unregistered
}

public enum Phase0InputCommand: String, Codable, CaseIterable, Sendable {
    case captureRegion
    case toggleMonitor
}

public enum Phase0PointerKind: String, Codable, Sendable {
    case click
    case scroll
    case mouseDown
    case mouseUp
}

public enum Phase0InputEvent: Equatable, Sendable {
    case modifierDown(DirectControlModifier)
    case modifierUp(DirectControlModifier)
    case keyDown(Phase0InputKey)
    case keyUp(Phase0InputKey)
    case pointerMotion(insidePreviewContent: Bool)
    case pointer(Phase0PointerKind, insidePreviewContent: Bool)
    case selectionMode(active: Bool)
}

public enum Phase0InputEffect: Equatable, Sendable {
    case consumedKeyDown(Phase0InputKey)
    case consumedKeyUp(Phase0InputKey)
    case forwardedKey(Phase0InputKey, modifier: DirectControlModifier?)
    case forwardedPointer(Phase0PointerKind, strippedModifier: Bool)
    case command(Phase0InputCommand)
    case directPointerStarted
    case directPointerStopped
    case directPointerStopDeferred
    case selectionBlocked
}

public struct Phase0InputTrace: Equatable, Sendable {
    public var effects: [Phase0InputEffect]

    public init(effects: [Phase0InputEffect] = []) {
        self.effects = effects
    }

    public var commands: [Phase0InputCommand] {
        effects.compactMap {
            guard case .command(let command) = $0 else { return nil }
            return command
        }
    }

    public var leakedShortcutKeyEvents: Int {
        effects.reduce(into: 0) { result, effect in
            guard case .forwardedKey(let key, _) = effect else { return }
            if key == .a || key == .f1 {
                result += 1
            }
        }
    }

    public var hasStuckButton: Bool {
        effects.contains(.directPointerStopDeferred) &&
            !effects.contains(.directPointerStopped)
    }
}

public struct Phase0InputArbiter: Sendable {
    private var registeredCommands: [Phase0InputCommand: Bool]
    private var currentModifier: DirectControlModifier?
    private var armed = false
    private var directPointerActive = false
    private var selectionActive = false
    private var consumedKey: Phase0InputKey?
    private var pressedMouseButtons = 0
    private var stopDeferred = false
    private var queuedCommand: Phase0InputCommand?

    public init(
        captureRegistered: Bool = true,
        monitorRegistered: Bool = true
    ) {
        registeredCommands = [
            .captureRegion: captureRegistered,
            .toggleMonitor: monitorRegistered
        ]
    }

    public mutating func setRegistration(_ command: Phase0InputCommand, registered: Bool) {
        registeredCommands[command] = registered
    }

    public mutating func process(_ event: Phase0InputEvent) -> Phase0InputTrace {
        var effects: [Phase0InputEffect] = []

        switch event {
        case .modifierDown(let modifier):
            currentModifier = modifier
            armed = !selectionActive && !directPointerActive
            if selectionActive {
                effects.append(.selectionBlocked)
            }

        case .modifierUp(let modifier):
            guard currentModifier == modifier else { break }
            armed = false
            if directPointerActive {
                stopDirectPointer(into: &effects)
            }
            currentModifier = nil

        case .keyDown(let key):
            if directPointerActive, let command = command(for: key), isRegistered(command) {
                consumedKey = key
                if pressedMouseButtons > 0 {
                    stopDeferred = true
                    queuedCommand = command
                    effects.append(.directPointerStopDeferred)
                } else {
                    directPointerActive = false
                    effects.append(.directPointerStopped)
                    effects.append(.command(command))
                }
                return Phase0InputTrace(effects: effects + [.consumedKeyDown(key)])
            }

            guard armed, let modifier = currentModifier else {
                effects.append(.forwardedKey(key, modifier: currentModifier))
                break
            }
            guard let command = command(for: key), isRegistered(command) else {
                armed = false
                effects.append(.forwardedKey(key, modifier: modifier))
                break
            }

            armed = false
            consumedKey = key
            effects.append(.command(command))
            effects.append(.consumedKeyDown(key))

        case .keyUp(let key):
            if consumedKey == key {
                consumedKey = nil
                effects.append(.consumedKeyUp(key))
            } else {
                effects.append(.forwardedKey(key, modifier: currentModifier))
            }

        case .pointerMotion(let insidePreviewContent):
            if armed, !selectionActive, insidePreviewContent {
                armed = false
                directPointerActive = true
                effects.append(.directPointerStarted)
            }

        case .pointer(let kind, let insidePreviewContent):
            let strippedModifier = directPointerActive && insidePreviewContent
            if kind == .mouseDown, directPointerActive, insidePreviewContent {
                pressedMouseButtons += 1
            } else if kind == .mouseUp, directPointerActive, insidePreviewContent {
                pressedMouseButtons = max(0, pressedMouseButtons - 1)
            }
            effects.append(.forwardedPointer(kind, strippedModifier: strippedModifier))
            if kind == .mouseUp, pressedMouseButtons == 0, stopDeferred {
                stopDeferred = false
                directPointerActive = false
                effects.append(.directPointerStopped)
                if let queuedCommand {
                    effects.append(.command(queuedCommand))
                    self.queuedCommand = nil
                }
            }

        case .selectionMode(let active):
            selectionActive = active
            if active {
                armed = false
                if directPointerActive {
                    stopDirectPointer(into: &effects)
                }
                effects.append(.selectionBlocked)
            }
        }

        return Phase0InputTrace(effects: effects)
    }

    private func command(for key: Phase0InputKey) -> Phase0InputCommand? {
        switch key {
        case .a:
            return .captureRegion
        case .f1:
            return .toggleMonitor
        case .unregistered:
            return nil
        }
    }

    private func isRegistered(_ command: Phase0InputCommand) -> Bool {
        registeredCommands[command] == true
    }

    private mutating func stopDirectPointer(into effects: inout [Phase0InputEffect]) {
        if pressedMouseButtons > 0 {
            stopDeferred = true
            effects.append(.directPointerStopDeferred)
        } else {
            directPointerActive = false
            effects.append(.directPointerStopped)
        }
    }
}

// MARK: - Shared CaptureRegion geometry

public enum DisplayOrientation: String, Codable, CaseIterable, Sendable {
    case none
    case rotate90CW
    case rotate180
    case rotate270CW
}

public struct CapturePixelRect: Codable, Equatable, Sendable {
    public var minX: Int
    public var minY: Int
    public var width: Int
    public var height: Int

    public init(minX: Int, minY: Int, width: Int, height: Int) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

public struct CaptureRegion: Codable, Equatable, Sendable {
    public var displayFrameInAppKitGlobalPoints: CGRect
    public var selectionRectInAppKitGlobalPoints: CGRect
    public var selectionRectInDisplayLocalPoints: CGRect
    public var sourceRectInPlatformLogicalPoints: CGRect
    public var pixelRectInCaptureSpace: CapturePixelRect
    public var pixelScale: Double
    public var displayOrientation: DisplayOrientation
    public var orientationAlreadyApplied: Bool

    public init(
        displayFrameInAppKitGlobalPoints: CGRect,
        selectionRectInAppKitGlobalPoints: CGRect,
        selectionRectInDisplayLocalPoints: CGRect,
        sourceRectInPlatformLogicalPoints: CGRect,
        pixelRectInCaptureSpace: CapturePixelRect,
        pixelScale: Double,
        displayOrientation: DisplayOrientation,
        orientationAlreadyApplied: Bool
    ) {
        self.displayFrameInAppKitGlobalPoints = displayFrameInAppKitGlobalPoints
        self.selectionRectInAppKitGlobalPoints = selectionRectInAppKitGlobalPoints
        self.selectionRectInDisplayLocalPoints = selectionRectInDisplayLocalPoints
        self.sourceRectInPlatformLogicalPoints = sourceRectInPlatformLogicalPoints
        self.pixelRectInCaptureSpace = pixelRectInCaptureSpace
        self.pixelScale = pixelScale
        self.displayOrientation = displayOrientation
        self.orientationAlreadyApplied = orientationAlreadyApplied
    }
}

public enum ScreenCoordinateAdapter {
    public static func makeRegion(
        displayFrame: CGRect,
        selectionRect: CGRect,
        pixelScale: Double,
        orientation: DisplayOrientation = .none,
        orientationAlreadyApplied: Bool = false
    ) throws -> CaptureRegion {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              pixelScale.isFinite,
              pixelScale > 0 else {
            throw CaptureError(code: "invalid_capture_region", message: "捕获区域或像素比例无效")
        }

        let clippedSelection = selectionRect.intersection(displayFrame)
        guard !clippedSelection.isNull, clippedSelection.width > 0, clippedSelection.height > 0 else {
            throw CaptureError(code: "empty_capture_region", message: "捕获区域为空")
        }

        let local = CGRect(
            x: clippedSelection.minX - displayFrame.minX,
            y: displayFrame.maxY - clippedSelection.maxY,
            width: clippedSelection.width,
            height: clippedSelection.height
        )
        let source = orientationAlreadyApplied
            ? local
            : orientedRect(local, in: displayFrame.size, orientation: orientation)
        let sourceBounds = CGRect(origin: .zero, size: orientedDisplaySize(displayFrame.size, orientation: orientation, orientationAlreadyApplied: orientationAlreadyApplied))
        let boundedSource = source.intersection(sourceBounds)
        guard !boundedSource.isNull, boundedSource.width > 0, boundedSource.height > 0 else {
            throw CaptureError(code: "invalid_capture_region", message: "平台逻辑坐标区域为空")
        }

        let pixelMinX = Int(floor(boundedSource.minX * pixelScale))
        let pixelMinY = Int(floor(boundedSource.minY * pixelScale))
        let pixelMaxX = Int(ceil(boundedSource.maxX * pixelScale))
        let pixelMaxY = Int(ceil(boundedSource.maxY * pixelScale))
        let pixelRect = CapturePixelRect(
            minX: pixelMinX,
            minY: pixelMinY,
            width: max(1, pixelMaxX - pixelMinX),
            height: max(1, pixelMaxY - pixelMinY)
        )

        return CaptureRegion(
            displayFrameInAppKitGlobalPoints: displayFrame,
            selectionRectInAppKitGlobalPoints: clippedSelection,
            selectionRectInDisplayLocalPoints: local,
            sourceRectInPlatformLogicalPoints: boundedSource,
            pixelRectInCaptureSpace: pixelRect,
            pixelScale: pixelScale,
            displayOrientation: orientation,
            orientationAlreadyApplied: orientationAlreadyApplied
        )
    }

    public static func pipelineRegionsAgree(
        screenshot: CaptureRegion,
        recording: CaptureRegion
    ) -> Bool {
        screenshot == recording
    }

    private static func orientedDisplaySize(
        _ size: CGSize,
        orientation: DisplayOrientation,
        orientationAlreadyApplied: Bool
    ) -> CGSize {
        guard !orientationAlreadyApplied else { return size }
        switch orientation {
        case .rotate90CW, .rotate270CW:
            return CGSize(width: size.height, height: size.width)
        case .none, .rotate180:
            return size
        }
    }

    private static func orientedRect(
        _ rect: CGRect,
        in sourceSize: CGSize,
        orientation: DisplayOrientation
    ) -> CGRect {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ].map { point in
            switch orientation {
            case .none:
                return CGPoint(x: point.x, y: point.y)
            case .rotate90CW:
                return CGPoint(x: sourceSize.height - point.y, y: point.x)
            case .rotate180:
                return CGPoint(x: sourceSize.width - point.x, y: sourceSize.height - point.y)
            case .rotate270CW:
                return CGPoint(x: point.y, y: sourceSize.width - point.x)
            }
        }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Status item lifecycle contract

public enum StatusItemRole: String, Codable, CaseIterable, Hashable, Sendable {
    case toolSuiteAnchor
    case monitorActivity
}

public struct StatusItemLifecycleModel: Codable, Equatable, Sendable {
    public private(set) var liveRoles: Set<StatusItemRole> = []
    public private(set) var visibleRoles: Set<StatusItemRole> = []

    public init() {}

    public mutating func create(_ role: StatusItemRole) {
        liveRoles.insert(role)
        visibleRoles.insert(role)
    }

    public mutating func setVisible(_ role: StatusItemRole, _ visible: Bool) {
        guard liveRoles.contains(role) else { return }
        if visible {
            visibleRoles.insert(role)
        } else {
            visibleRoles.remove(role)
        }
    }

    public mutating func destroy(_ role: StatusItemRole) {
        liveRoles.remove(role)
        visibleRoles.remove(role)
    }

    public var hasIndependentLifecycle: Bool {
        liveRoles == Set(StatusItemRole.allCases) && visibleRoles == liveRoles
    }
}
