import CoreGraphics
import Foundation

public enum DirectControlModifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case option
    case control
    case shift
    case command

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .option:
            return "⌥"
        case .control:
            return "⌃"
        case .shift:
            return "⇧"
        case .command:
            return "⌘"
        }
    }

    public var label: String {
        switch self {
        case .option:
            return "Option（Alt）"
        case .control:
            return "Control"
        case .shift:
            return "Shift"
        case .command:
            return "Command"
        }
    }

    public var menuTitle: String {
        "\(symbol) \(label)"
    }
}

public struct CaptureError: Error, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public var description: String {
        if let detail, !detail.isEmpty {
            return "\(message) (\(detail))"
        }
        return message
    }
}

public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum DisplayCaptureAvailability: Codable, Equatable, Hashable, Sendable {
    case mirrored
    case notShareable
    case candidate
    case available
    case captureFailed(CaptureError)

    public var isSelectable: Bool {
        switch self {
        case .candidate, .available, .captureFailed:
            return true
        case .mirrored, .notShareable:
            return false
        }
    }

    public var label: String {
        switch self {
        case .mirrored:
            return "镜像"
        case .notShareable:
            return "不可采集"
        case .candidate:
            return "待验证"
        case .available:
            return "可采集"
        case .captureFailed:
            return "采集失败"
        }
    }
}

public enum CanaryValidationResult: Equatable, Sendable {
    case notRun
    case succeeded
    case failed(CaptureError)
}

public enum DisplayAvailabilityClassifier {
    public static func classify(
        isOnline: Bool,
        isActive: Bool,
        isMirrored: Bool,
        isShareable: Bool,
        canary: CanaryValidationResult = .notRun
    ) -> DisplayCaptureAvailability {
        guard isOnline, isActive else {
            return .notShareable
        }
        if isMirrored {
            return .mirrored
        }
        guard isShareable else {
            return .notShareable
        }
        switch canary {
        case .notRun:
            return .candidate
        case .succeeded:
            return .available
        case .failed(let error):
            return .captureFailed(error)
        }
    }
}

public struct PersistentDisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public var vendorID: UInt32
    public var modelID: UInt32
    public var serialNumber: UInt32?
    public var localizedName: String
    public var lastKnownPixelWidth: Int
    public var lastKnownPixelHeight: Int
    public var isBuiltin: Bool

    public init(
        vendorID: UInt32,
        modelID: UInt32,
        serialNumber: UInt32?,
        localizedName: String,
        lastKnownPixelWidth: Int,
        lastKnownPixelHeight: Int,
        isBuiltin: Bool
    ) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.localizedName = localizedName
        self.lastKnownPixelWidth = lastKnownPixelWidth
        self.lastKnownPixelHeight = lastKnownPixelHeight
        self.isBuiltin = isBuiltin
    }
}

public struct DisplayDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: CGDirectDisplayID
    public var localizedName: String
    public var logicalSize: PixelSize
    public var pixelSize: PixelSize
    public var isPrimary: Bool
    public var isOnline: Bool
    public var isBuiltin: Bool
    public var isMirrored: Bool
    public var captureAvailability: DisplayCaptureAvailability
    public var persistentIdentity: PersistentDisplayIdentity

    public init(
        id: CGDirectDisplayID,
        localizedName: String,
        logicalSize: PixelSize,
        pixelSize: PixelSize,
        isPrimary: Bool,
        isOnline: Bool,
        isBuiltin: Bool,
        isMirrored: Bool,
        captureAvailability: DisplayCaptureAvailability,
        persistentIdentity: PersistentDisplayIdentity
    ) {
        self.id = id
        self.localizedName = localizedName
        self.logicalSize = logicalSize
        self.pixelSize = pixelSize
        self.isPrimary = isPrimary
        self.isOnline = isOnline
        self.isBuiltin = isBuiltin
        self.isMirrored = isMirrored
        self.captureAvailability = captureAvailability
        self.persistentIdentity = persistentIdentity
    }

    public var menuTitle: String {
        let role = isPrimary ? "主屏" : "扩展"
        return "\(localizedName) \(pixelSize.width)x\(pixelSize.height) \(role)"
    }
}

public enum ScreenRecordingPermissionState: Equatable, Sendable {
    case unknown
    case checking
    case notGranted
    case granted
    case revoked
}

public enum TargetDisplayState: Equatable, Sendable {
    case noneSelected
    case online(DisplayDescriptor)
    case disconnected(PersistentDisplayIdentity)
    case ambiguous(PersistentDisplayIdentity)
    case unsupported(String)
}

public enum CapturePhase: Equatable, Sendable {
    case idle
    case starting
    case capturing
    case pausing
    case paused
    case stopping
    case retrying(attempt: Int)
    case failed(CaptureError)
}

public enum MonitorDesiredState: String, Codable, Equatable, CaseIterable, Sendable {
    case off
    case on

    public var label: String {
        switch self {
        case .off:
            return "OFF"
        case .on:
            return "ON"
        }
    }
}

public enum MonitorRuntimeState: Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
    case suspended(String)
    case stopping
    case failed(CaptureError)

    public var label: String {
        switch self {
        case .idle:
            return "IDLE"
        case .starting:
            return "STARTING"
        case .running:
            return "RUNNING"
        case .paused:
            return "PAUSED"
        case .suspended(let reason):
            return "SUSPENDED：\(reason)"
        case .stopping:
            return "STOPPING"
        case .failed(let error):
            return "FAILED：\(error.message)"
        }
    }

    public var keepsActivityEntryVisible: Bool {
        switch self {
        case .idle:
            return false
        case .starting, .running, .paused, .suspended, .stopping, .failed:
            return true
        }
    }
}

public enum ShelfSafeReason: String, Codable, Equatable, CaseIterable, Sendable {
    case shelfNoGo
    case accessibilityUnavailable
    case unsupportedItems
    case recoveryPending

    public var label: String {
        switch self {
        case .shelfNoGo:
            return "Shelf No-Go"
        case .accessibilityUnavailable:
            return "辅助功能不可用"
        case .unsupportedItems:
            return "存在未管理项目"
        case .recoveryPending:
            return "等待恢复"
        }
    }
}

public enum ShelfState: Equatable, Sendable {
    case unavailable(String)
    case calibrating
    case ready
    case expanded
    case safeVisibility(ShelfSafeReason)
    case repairNeeded(CaptureError)

    public var label: String {
        switch self {
        case .unavailable(let reason):
            return "不可用：\(reason)"
        case .calibrating:
            return "校准中"
        case .ready:
            return "已就绪"
        case .expanded:
            return "已展开"
        case .safeVisibility(let reason):
            return "Safe Visibility（\(reason.label)）"
        case .repairNeeded(let error):
            return "需要修复：\(error.message)"
        }
    }

    public var isSafeVisibility: Bool {
        if case .safeVisibility = self {
            return true
        }
        return false
    }
}

public enum PreviewVisibility: Codable, Equatable, Sendable {
    case shown
    case collapsed
    case hidden
}

public enum CaptureResolutionPreset: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case compact = "320x180"
    case small = "480x270"
    case medium = "640x360"
    case large = "960x540"
    case hd = "1280x720"
    case fullHD = "1920x1080"
    case qhd = "2560x1440"

    public static let selectableCases: [CaptureResolutionPreset] = [
        .hd,
        .fullHD,
        .qhd
    ]

    public var id: String {
        rawValue
    }

    public var label: String {
        rawValue
    }

    public var maxPixelSize: PixelSize {
        switch self {
        case .compact:
            return PixelSize(width: 320, height: 180)
        case .small:
            return PixelSize(width: 480, height: 270)
        case .medium:
            return PixelSize(width: 640, height: 360)
        case .large:
            return PixelSize(width: 960, height: 540)
        case .hd:
            return PixelSize(width: 1280, height: 720)
        case .fullHD:
            return PixelSize(width: 1920, height: 1080)
        case .qhd:
            return PixelSize(width: 2560, height: 1440)
        }
    }
}

public enum PreviewWindowSizePreset: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case compact = "240x135"
    case small = "320x180"
    case medium = "480x270"
    case large = "640x360"
    case extraLarge = "960x540"
    case hd = "1280x720"

    public static let selectableCases: [PreviewWindowSizePreset] = [
        .large,
        .extraLarge,
        .hd
    ]

    public var id: String {
        rawValue
    }

    public var label: String {
        rawValue
    }

    public var contentSize: CGSize {
        let size: PixelSize
        switch self {
        case .compact:
            size = PixelSize(width: 240, height: 135)
        case .small:
            size = PixelSize(width: 320, height: 180)
        case .medium:
            size = PixelSize(width: 480, height: 270)
        case .large:
            size = PixelSize(width: 640, height: 360)
        case .extraLarge:
            size = PixelSize(width: 960, height: 540)
        case .hd:
            size = PixelSize(width: 1280, height: 720)
        }
        return CGSize(width: size.width, height: size.height)
    }
}

public struct CaptureSnapshot: Equatable, Sendable {
    public var permission: ScreenRecordingPermissionState
    public var target: TargetDisplayState
    public var phase: CapturePhase
    public var previewVisibility: PreviewVisibility
    public var lastFrameTime: Date?
    public var lastError: CaptureError?

    public init(
        permission: ScreenRecordingPermissionState,
        target: TargetDisplayState,
        phase: CapturePhase,
        previewVisibility: PreviewVisibility,
        lastFrameTime: Date?,
        lastError: CaptureError?
    ) {
        self.permission = permission
        self.target = target
        self.phase = phase
        self.previewVisibility = previewVisibility
        self.lastFrameTime = lastFrameTime
        self.lastError = lastError
    }
}

public enum ScreenshotAnnotationTool: String, Codable, CaseIterable, Sendable {
    case select
    case arrow
    case line
    case rectangle
    case filledRectangle
    case ellipse
    case pen
    case highlighter
    case text
    case blur
    case pixelate
    case spotlight
    case counter
    case crop
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 10

    public var schemaVersion: Int
    public var selectedDisplay: PersistentDisplayIdentity?
    public var lastSessionDisplayID: CGDirectDisplayID?
    public var frameRate: Int
    public var captureResolution: CaptureResolutionPreset
    public var previewWindowSize: PreviewWindowSizePreset
    public var previewIsPinned: Bool
    public var showsCursor: Bool
    public var directControlModifier: DirectControlModifier
    public var previewContentFrame: CGRect?
    public var collapsedIconFrame: CGRect?
    public var previewIsVisible: Bool
    public var previewIsCollapsed: Bool
    public var captureIsPaused: Bool
    public var permissionGrantPreviouslyObserved: Bool
    public var preferredPreviewPresentation: PreviewVisibility
    public var shelfMode: String
    public var monitorIndicatorPolicy: String
    public var shortcutBindings: [String: String]
    public var scrollCaptureMode: ScrollCaptureMode
    public var artifactShelfAutoPresent: Bool
    public var artifactShelfFollowsActiveDisplay: Bool
    public var artifactShelfRecentLimit: Int
    public var artifactShelfMargin: Double
    public var artifactShelfRestoreOnLaunch: Bool
    /// Nil means the product default: ~/Desktop/Display Monitor Screenshots.
    /// Keeping only a path avoids trying to persist an AppKit bookmark in this
    /// non-sandboxed SwiftPM app while still making the choice durable.
    public var screenshotSaveDirectoryPath: String?
    public var screenshotTimerDelaySeconds: Int
    public var lastScreenshotDisplayID: CGDirectDisplayID?
    public var lastScreenshotRegion: CaptureRegion?
    public var lastScreenshotAnnotationTool: ScreenshotAnnotationTool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedDisplay
        case lastSessionDisplayID
        case frameRate
        case captureResolution
        case previewWindowSize
        case previewIsPinned
        case showsCursor
        case directControlModifier
        case previewContentFrame
        case collapsedIconFrame
        case previewIsVisible
        case previewIsCollapsed
        case captureIsPaused
        case permissionGrantPreviouslyObserved
        case preferredPreviewPresentation
        case shelfMode
        case monitorIndicatorPolicy
        case shortcutBindings
        case scrollCaptureMode
        case artifactShelfAutoPresent
        case artifactShelfFollowsActiveDisplay
        case artifactShelfRecentLimit
        case artifactShelfMargin
        case artifactShelfRestoreOnLaunch
        case screenshotSaveDirectoryPath
        case screenshotTimerDelaySeconds
        case lastScreenshotDisplayID
        case lastScreenshotRegion
        case lastScreenshotAnnotationTool
    }

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        selectedDisplay: PersistentDisplayIdentity? = nil,
        lastSessionDisplayID: CGDirectDisplayID? = nil,
        frameRate: Int = 15,
        captureResolution: CaptureResolutionPreset = .hd,
        previewWindowSize: PreviewWindowSizePreset = .large,
        previewIsPinned: Bool = true,
        showsCursor: Bool = true,
        directControlModifier: DirectControlModifier = .option,
        previewContentFrame: CGRect? = nil,
        collapsedIconFrame: CGRect? = nil,
        previewIsVisible: Bool = true,
        previewIsCollapsed: Bool = false,
        captureIsPaused: Bool = false,
        permissionGrantPreviouslyObserved: Bool = false,
        preferredPreviewPresentation: PreviewVisibility = .shown,
        shelfMode: String = "safeVisibility(shelfNoGo)",
        monitorIndicatorPolicy: String = "activityItemWhenOn",
        shortcutBindings: [String: String] = AppSettings.defaultShortcutBindings,
        scrollCaptureMode: ScrollCaptureMode = .automaticFirstManualFallback,
        artifactShelfAutoPresent: Bool = true,
        artifactShelfFollowsActiveDisplay: Bool = true,
        artifactShelfRecentLimit: Int = 20,
        artifactShelfMargin: Double = 16,
        artifactShelfRestoreOnLaunch: Bool = true,
        screenshotSaveDirectoryPath: String? = nil,
        screenshotTimerDelaySeconds: Int = 5,
        lastScreenshotDisplayID: CGDirectDisplayID? = nil,
        lastScreenshotRegion: CaptureRegion? = nil,
        lastScreenshotAnnotationTool: ScreenshotAnnotationTool = .arrow
    ) {
        self.schemaVersion = schemaVersion
        self.selectedDisplay = selectedDisplay
        self.lastSessionDisplayID = lastSessionDisplayID
        self.frameRate = frameRate
        self.captureResolution = captureResolution
        self.previewWindowSize = previewWindowSize
        self.previewIsPinned = previewIsPinned
        self.showsCursor = showsCursor
        self.directControlModifier = directControlModifier
        self.previewContentFrame = previewContentFrame
        self.collapsedIconFrame = collapsedIconFrame
        self.previewIsVisible = previewIsVisible
        self.previewIsCollapsed = previewIsCollapsed
        self.captureIsPaused = captureIsPaused
        self.permissionGrantPreviouslyObserved = permissionGrantPreviouslyObserved
        self.preferredPreviewPresentation = preferredPreviewPresentation
        self.shelfMode = shelfMode
        self.monitorIndicatorPolicy = monitorIndicatorPolicy
        self.shortcutBindings = shortcutBindings
        self.scrollCaptureMode = scrollCaptureMode
        self.artifactShelfAutoPresent = artifactShelfAutoPresent
        self.artifactShelfFollowsActiveDisplay = artifactShelfFollowsActiveDisplay
        self.artifactShelfRecentLimit = artifactShelfRecentLimit
        self.artifactShelfMargin = artifactShelfMargin
        self.artifactShelfRestoreOnLaunch = artifactShelfRestoreOnLaunch
        self.screenshotSaveDirectoryPath = screenshotSaveDirectoryPath
        self.screenshotTimerDelaySeconds = screenshotTimerDelaySeconds
        self.lastScreenshotDisplayID = lastScreenshotDisplayID
        self.lastScreenshotRegion = lastScreenshotRegion
        self.lastScreenshotAnnotationTool = lastScreenshotAnnotationTool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        selectedDisplay = try container.decodeIfPresent(PersistentDisplayIdentity.self, forKey: .selectedDisplay)
        lastSessionDisplayID = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .lastSessionDisplayID)
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 15
        captureResolution = try container.decodeIfPresent(
            CaptureResolutionPreset.self,
            forKey: .captureResolution
        ) ?? .hd
        previewWindowSize = try container.decodeIfPresent(
            PreviewWindowSizePreset.self,
            forKey: .previewWindowSize
        ) ?? .large
        previewIsPinned = try container.decodeIfPresent(Bool.self, forKey: .previewIsPinned) ?? true
        showsCursor = try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true
        directControlModifier = try container.decodeIfPresent(
            DirectControlModifier.self,
            forKey: .directControlModifier
        ) ?? .option
        previewContentFrame = try container.decodeIfPresent(CGRect.self, forKey: .previewContentFrame)
        collapsedIconFrame = try container.decodeIfPresent(CGRect.self, forKey: .collapsedIconFrame)
        previewIsVisible = try container.decodeIfPresent(Bool.self, forKey: .previewIsVisible) ?? true
        previewIsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .previewIsCollapsed) ?? false
        captureIsPaused = try container.decodeIfPresent(Bool.self, forKey: .captureIsPaused) ?? false
        permissionGrantPreviouslyObserved = try container.decodeIfPresent(
            Bool.self,
            forKey: .permissionGrantPreviouslyObserved
        ) ?? false
        let legacyPreviewPresentation: PreviewVisibility
        if !previewIsVisible {
            legacyPreviewPresentation = .hidden
        } else if previewIsCollapsed {
            legacyPreviewPresentation = .collapsed
        } else {
            legacyPreviewPresentation = .shown
        }
        preferredPreviewPresentation = try container.decodeIfPresent(
            PreviewVisibility.self,
            forKey: .preferredPreviewPresentation
        ) ?? legacyPreviewPresentation
        shelfMode = try container.decodeIfPresent(String.self, forKey: .shelfMode)
            ?? "safeVisibility(shelfNoGo)"
        monitorIndicatorPolicy = try container.decodeIfPresent(String.self, forKey: .monitorIndicatorPolicy)
            ?? "activityItemWhenOn"
        shortcutBindings = try container.decodeIfPresent(
            [String: String].self,
            forKey: .shortcutBindings
        ) ?? AppSettings.defaultShortcutBindings
        scrollCaptureMode = try container.decodeIfPresent(
            ScrollCaptureMode.self,
            forKey: .scrollCaptureMode
        ) ?? .automaticFirstManualFallback
        artifactShelfAutoPresent = try container.decodeIfPresent(
            Bool.self,
            forKey: .artifactShelfAutoPresent
        ) ?? true
        artifactShelfFollowsActiveDisplay = try container.decodeIfPresent(
            Bool.self,
            forKey: .artifactShelfFollowsActiveDisplay
        ) ?? true
        artifactShelfRecentLimit = try container.decodeIfPresent(
            Int.self,
            forKey: .artifactShelfRecentLimit
        ) ?? 20
        artifactShelfMargin = try container.decodeIfPresent(
            Double.self,
            forKey: .artifactShelfMargin
        ) ?? 16
        artifactShelfRestoreOnLaunch = try container.decodeIfPresent(
            Bool.self,
            forKey: .artifactShelfRestoreOnLaunch
        ) ?? true
        screenshotSaveDirectoryPath = try container.decodeIfPresent(
            String.self,
            forKey: .screenshotSaveDirectoryPath
        )
        screenshotTimerDelaySeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .screenshotTimerDelaySeconds
        ) ?? 5
        lastScreenshotDisplayID = try container.decodeIfPresent(
            CGDirectDisplayID.self,
            forKey: .lastScreenshotDisplayID
        )
        lastScreenshotRegion = try container.decodeIfPresent(
            CaptureRegion.self,
            forKey: .lastScreenshotRegion
        )
        lastScreenshotAnnotationTool = try container.decodeIfPresent(
            ScreenshotAnnotationTool.self,
            forKey: .lastScreenshotAnnotationTool
        ) ?? .arrow
    }

    public static let defaultShortcutBindings: [String: String] = [
        "toggleMonitor": "⌥F1",
        "captureRegion": "⌥A",
        "togglePause": "⌥⌘P",
        "moveToTarget": "⌥⌘→",
        "moveToMain": "⌥⌘←"
    ]

    public static var safeDefault: AppSettings {
        AppSettings()
    }

    public var normalized: AppSettings {
        var copy = self
        let decodedSchemaVersion = copy.schemaVersion
        copy.schemaVersion = AppSettings.currentSchemaVersion
        if decodedSchemaVersion < 3 {
            if copy.captureResolution == .large {
                copy.captureResolution = .hd
            }
            copy.previewContentFrame = nil
        }
        if ![5, 10, 15, 30].contains(copy.frameRate) {
            copy.frameRate = 15
        }
        if !CaptureResolutionPreset.selectableCases.contains(copy.captureResolution) {
            copy.captureResolution = .hd
        }
        if !PreviewWindowSizePreset.selectableCases.contains(copy.previewWindowSize) {
            copy.previewWindowSize = .large
        }
        let minimumPreviewSize = PreviewWindowSizePreset.large.contentSize
        if let frame = copy.previewContentFrame,
           frame.width < minimumPreviewSize.width || frame.height < minimumPreviewSize.height {
            copy.previewContentFrame = nil
        }
        if !copy.previewIsVisible {
            copy.previewIsCollapsed = false
        }
        if copy.shortcutBindings.isEmpty {
            copy.shortcutBindings = AppSettings.defaultShortcutBindings
        }
        if copy.shelfMode.isEmpty {
            copy.shelfMode = "safeVisibility(shelfNoGo)"
        }
        if copy.monitorIndicatorPolicy.isEmpty {
            copy.monitorIndicatorPolicy = "activityItemWhenOn"
        }
        if copy.artifactShelfRecentLimit < 1 || copy.artifactShelfRecentLimit > 100 {
            copy.artifactShelfRecentLimit = 20
        }
        if !copy.artifactShelfMargin.isFinite || copy.artifactShelfMargin < 0 || copy.artifactShelfMargin > 80 {
            copy.artifactShelfMargin = 16
        }
        let normalizedSavePath = copy.screenshotSaveDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.screenshotSaveDirectoryPath = normalizedSavePath?.hasPrefix("/") == true
            ? normalizedSavePath
            : nil
        if ![3, 5, 10].contains(copy.screenshotTimerDelaySeconds) {
            copy.screenshotTimerDelaySeconds = 5
        }
        return copy
    }
}

public enum DisplayMatchResult: Equatable, Sendable {
    case matched(DisplayDescriptor)
    case disconnected
    case ambiguous
}

public enum OutputSizeCalculator {
    public static func calculate(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        maxWidth: Int = 960,
        maxHeight: Int = 540
    ) throws -> PixelSize {
        guard sourcePixelWidth > 0, sourcePixelHeight > 0, maxWidth > 0, maxHeight > 0 else {
            throw CaptureError(
                code: "invalid_source_size",
                message: "源画面尺寸无效",
                detail: "\(sourcePixelWidth)x\(sourcePixelHeight)"
            )
        }

        let scale = min(
            Double(maxWidth) / Double(sourcePixelWidth),
            Double(maxHeight) / Double(sourcePixelHeight),
            1
        )
        let scaledWidth = Double(sourcePixelWidth) * scale
        let scaledHeight = Double(sourcePixelHeight) * scale
        let outputWidth = max(2, Int(floor(scaledWidth / 2)) * 2)
        let outputHeight = max(2, Int(floor(scaledHeight / 2)) * 2)
        return PixelSize(width: outputWidth, height: outputHeight)
    }
}

public enum PreviewCoordinateMapper {
    /// Maps an AppKit point inside an aspect-fitted preview to the target
    /// display's global Quartz coordinate space.
    public static func map(
        localPoint: CGPoint,
        previewBounds: CGRect,
        targetBounds: CGRect,
        contentSize: CGSize
    ) -> CGPoint? {
        guard previewBounds.width > 0,
              previewBounds.height > 0,
              targetBounds.width > 0,
              targetBounds.height > 0,
              targetBounds.minX.isFinite,
              targetBounds.minY.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return nil
        }

        let scale = min(
            previewBounds.width / contentSize.width,
            previewBounds.height / contentSize.height
        )
        let fittedSize = CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
        let fittedRect = CGRect(
            x: previewBounds.midX - fittedSize.width / 2,
            y: previewBounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        guard fittedRect.contains(localPoint) else {
            return nil
        }

        let xFraction = min(max((localPoint.x - fittedRect.minX) / fittedRect.width, 0), 1)
        let yFraction = min(max((localPoint.y - fittedRect.minY) / fittedRect.height, 0), 1)
        let mappedX = targetBounds.minX + targetBounds.width * xFraction
        let mappedY = targetBounds.minY + targetBounds.height * (1 - yFraction)
        return CGPoint(
            x: min(max(mappedX, targetBounds.minX), targetBounds.maxX.nextDown),
            // AppKit views are bottom-up by default, while CGDisplayBounds and
            // CGEvent mouse locations use the Quartz top-down display space.
            y: min(max(mappedY, targetBounds.minY), targetBounds.maxY.nextDown)
        )
    }
}

public enum DisplayIdentityMatcher {
    public static func match(
        lastSessionDisplayID: CGDirectDisplayID?,
        identity: PersistentDisplayIdentity,
        candidates: [DisplayDescriptor]
    ) -> DisplayMatchResult {
        if let lastSessionDisplayID,
           let descriptor = candidates.first(where: { $0.id == lastSessionDisplayID }),
           deviceDescriptionMatches(identity, descriptor.persistentIdentity) {
            return .matched(descriptor)
        }

        if let serialNumber = identity.serialNumber, serialNumber != 0 {
            let serialMatches = candidates.filter {
                $0.persistentIdentity.vendorID == identity.vendorID &&
                    $0.persistentIdentity.modelID == identity.modelID &&
                    $0.persistentIdentity.serialNumber == serialNumber
            }
            if serialMatches.count == 1 {
                return .matched(serialMatches[0])
            }
            if serialMatches.count > 1 {
                return .ambiguous
            }
        }

        let fallbackMatches = candidates.filter {
            $0.persistentIdentity.vendorID == identity.vendorID &&
                $0.persistentIdentity.modelID == identity.modelID &&
                $0.persistentIdentity.localizedName == identity.localizedName &&
                $0.persistentIdentity.lastKnownPixelWidth == identity.lastKnownPixelWidth &&
                $0.persistentIdentity.lastKnownPixelHeight == identity.lastKnownPixelHeight
        }
        if fallbackMatches.count == 1 {
            return .matched(fallbackMatches[0])
        }
        if fallbackMatches.count > 1 {
            return .ambiguous
        }
        return .disconnected
    }

    private static func deviceDescriptionMatches(
        _ lhs: PersistentDisplayIdentity,
        _ rhs: PersistentDisplayIdentity
    ) -> Bool {
        guard lhs.vendorID == rhs.vendorID, lhs.modelID == rhs.modelID else {
            return false
        }
        if let lhsSerial = lhs.serialNumber, lhsSerial != 0,
           let rhsSerial = rhs.serialNumber, rhsSerial != 0 {
            return lhsSerial == rhsSerial
        }
        return lhs.localizedName == rhs.localizedName &&
            lhs.lastKnownPixelWidth == rhs.lastKnownPixelWidth &&
            lhs.lastKnownPixelHeight == rhs.lastKnownPixelHeight
    }
}

public enum PermissionStateResolver {
    public static func resolve(preflightGranted: Bool, previouslyObservedGrant: Bool) -> ScreenRecordingPermissionState {
        if preflightGranted {
            return .granted
        }
        return previouslyObservedGrant ? .revoked : .notGranted
    }
}

public enum CaptureRetryPolicy {
    public static let maximumAttempts = 3

    public static func delaySeconds(forAttempt attempt: Int) -> Double? {
        switch attempt {
        case 1:
            return 0.5
        case 2:
            return 1.0
        case 3:
            return 2.0
        default:
            return nil
        }
    }

    public static func shouldRetry(_ error: CaptureError, attempt: Int) -> Bool {
        guard attempt < maximumAttempts else {
            return false
        }
        switch error.code {
        case "display_not_shareable",
             "current_app_not_unique",
             "source_size_mismatch",
             "invalid_source_size",
             "display_not_selectable":
            return false
        default:
            return true
        }
    }
}

public enum WindowFrameResolver {
    public static let defaultContentSize = CGSize(width: 480, height: 270)
    public static let minimumVisibleSize = CGSize(width: 160, height: 90)
    public static let defaultMargin: CGFloat = 16

    public static func defaultFrame(
        in mainVisibleFrame: CGRect,
        contentSize: CGSize = defaultContentSize,
        margin: CGFloat = defaultMargin
    ) -> CGRect {
        let width = min(contentSize.width, max(2, mainVisibleFrame.width - margin * 2))
        let height = min(contentSize.height, max(2, mainVisibleFrame.height - margin * 2))
        return CGRect(
            x: mainVisibleFrame.maxX - width - margin,
            y: mainVisibleFrame.minY + margin,
            width: width,
            height: height
        )
    }

    public static func resolve(
        savedFrame: CGRect?,
        visibleFrames: [CGRect],
        mainVisibleFrame: CGRect,
        contentSize: CGSize = defaultContentSize,
        margin: CGFloat = defaultMargin
    ) -> CGRect {
        guard let savedFrame,
              savedFrame.width >= 2,
              savedFrame.height >= 2,
              hasEnoughVisibleIntersection(savedFrame, visibleFrames: visibleFrames) else {
            return defaultFrame(in: mainVisibleFrame, contentSize: contentSize, margin: margin)
        }
        return savedFrame
    }

    public static func hasEnoughVisibleIntersection(
        _ frame: CGRect,
        visibleFrames: [CGRect],
        minimumVisibleSize: CGSize = minimumVisibleSize
    ) -> Bool {
        visibleFrames.contains { visibleFrame in
            let intersection = frame.intersection(visibleFrame)
            return !intersection.isNull &&
                intersection.width >= minimumVisibleSize.width &&
                intersection.height >= minimumVisibleSize.height
        }
    }
}
