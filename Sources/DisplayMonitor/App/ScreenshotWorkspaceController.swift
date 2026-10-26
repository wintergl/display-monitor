import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureAction: CaseIterable, Hashable {
    case still
    case pinStill
    case scroll
    case recording

    var label: String {
        switch self {
        case .still: return "截图"
        case .pinStill: return "贴图"
        case .scroll: return "滚动截图"
        case .recording: return "区域录屏"
        }
    }

    var symbolName: String {
        switch self {
        case .still: return "camera"
        case .pinStill: return "pin.fill"
        case .scroll: return "rectangle.portrait.on.rectangle.portrait"
        case .recording: return "record.circle"
        }
    }
}

private final class ScreenshotSelectionActionBar: NSView {
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityLabel("截图操作")
        applyVisualState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        applyVisualState()
    }

    private func applyVisualState() {
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.88).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 0.30
    }
}

private enum ScreenshotSelectionActionButtonRole {
    case primary
    case secondary
    case recording
}

@MainActor
enum ScreenshotSelectionIconFactory {
    static func scrollCaptureImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { bounds in
            let centerX = bounds.midX
            NSColor.black.setFill()
            for centerY in [14.5, 11.5, 8.5] as [CGFloat] {
                NSBezierPath(
                    ovalIn: CGRect(x: centerX - 0.85, y: centerY - 0.85, width: 1.7, height: 1.7)
                ).fill()
            }

            let arrow = NSBezierPath()
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: CGPoint(x: centerX, y: 6.8))
            arrow.line(to: CGPoint(x: centerX, y: 3.2))
            arrow.move(to: CGPoint(x: centerX - 3.1, y: 6.1))
            arrow.line(to: CGPoint(x: centerX, y: 3.0))
            arrow.line(to: CGPoint(x: centerX + 3.1, y: 6.1))
            NSColor.black.setStroke()
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class ScreenshotSelectionActionButton: NSButton {
    private let visualRole: ScreenshotSelectionActionButtonRole
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerHovering = false

    override var allowsVibrancy: Bool { false }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    init(
        title: String,
        symbol: String,
        customImage: NSImage? = nil,
        role: ScreenshotSelectionActionButtonRole
    ) {
        visualRole = role
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        bezelStyle = .regularSquare
        controlSize = .large
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        self.title = ""
        alignment = .center
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = customImage ?? NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        toolTip = title
        setAccessibilityLabel(title)
        focusRingType = .none
        applyVisualState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        applyVisualState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerHovering = false
        needsDisplay = true
    }

    private func applyVisualState() {
        let isPressed = isHighlighted && isEnabled
        let backgroundAlpha: CGFloat = isPressed ? 0.18 : (isPointerHovering ? 0.11 : 0)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(backgroundAlpha).cgColor
        layer?.borderColor = NSColor.clear.cgColor

        switch visualRole {
        case .primary:
            contentTintColor = NSColor.white.withAlphaComponent(isEnabled ? 0.96 : 0.38)
        case .secondary:
            contentTintColor = NSColor.white.withAlphaComponent(isEnabled ? 0.82 : 0.34)
        case .recording:
            contentTintColor = NSColor.systemRed.withAlphaComponent(isEnabled ? 0.92 : 0.38)
        }
        layer?.borderWidth = 0
        alphaValue = 1
    }
}

enum WindowCaptureGeometry {
    static func appKitFrame(quartzFrame: CGRect, mainDisplayMaxY: CGFloat) -> CGRect {
        CGRect(
            x: quartzFrame.minX,
            y: mainDisplayMaxY - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

enum FrozenScreenshotGeometry {
    static func cropRect(
        imageSize: CGSize,
        displayFrame: CGRect,
        selectionRect: CGRect
    ) -> CGRect? {
        let displayFrame = displayFrame.standardized
        guard imageSize.width > 0,
              imageSize.height > 0,
              displayFrame.width > 0,
              displayFrame.height > 0 else {
            return nil
        }

        let clippedSelection = selectionRect.standardized.intersection(displayFrame)
        guard !clippedSelection.isNull,
              clippedSelection.width > 0,
              clippedSelection.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let minX = floor((clippedSelection.minX - displayFrame.minX) * scaleX)
        let minY = floor((displayFrame.maxY - clippedSelection.maxY) * scaleY)
        let maxX = ceil((clippedSelection.maxX - displayFrame.minX) * scaleX)
        let maxY = ceil((displayFrame.maxY - clippedSelection.minY) * scaleY)
        let requested = CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let bounded = requested.intersection(imageBounds).integral
        guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else {
            return nil
        }
        return bounded
    }
}

struct FrozenScreenshotFrame: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let image: CGImage

    func croppedImage(for region: CaptureRegion) -> CGImage? {
        guard let cropRect = FrozenScreenshotGeometry.cropRect(
            imageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
            displayFrame: displayFrame,
            selectionRect: region.selectionRectInAppKitGlobalPoints
        ) else {
            return nil
        }
        return image.cropping(to: cropRect)
    }
}

/// A ScreenCaptureKit callback may outlive cancellation. Resolve our waiter
/// independently so shutdown never waits for that callback, and ignore its late result.
@MainActor
final class ScreenshotSelectionPreparation<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    func value(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !isFinished else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                workTask = Task { @MainActor [weak self] in
                    do {
                        let value = try await operation()
                        self?.finish(.success(value))
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        self?.finish(.failure(CaptureError(
                            code: "screenshot_selection_prepare_timeout",
                            message: "截图画面加载超时，请重试"
                        )))
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Swift.Result<Value, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        workTask?.cancel()
        timeoutTask?.cancel()
        workTask = nil
        timeoutTask = nil
        continuation?.resume(with: result)
    }
}

private struct WindowCaptureCandidate: @unchecked Sendable {
    let window: SCWindow
    let appKitFrame: CGRect
    let ownerName: String
    let title: String
    let zIndex: Int
}

@MainActor
final class ScreenshotWorkspaceController {
    struct Result {
        let artifact: ArtifactManifest
        let canonicalURL: URL
        let displayID: CGDirectDisplayID
        let region: CaptureRegion
        let pixelSize: PixelSize
    }

    struct SelectedRegion {
        let displayID: CGDirectDisplayID
        let region: CaptureRegion
    }

    struct CaptureRequest {
        let selectedRegion: SelectedRegion
        let action: CaptureAction
        let frozenFrame: FrozenScreenshotFrame?
    }

    private enum SelectionOutcome {
        case selected(
            displayID: CGDirectDisplayID,
            displayFrame: CGRect,
            pixelScale: CGFloat,
            rect: CGRect,
            action: CaptureAction
        )
        case cancelled
        case unavailable(CaptureError)
    }

    private enum WindowSelectionOutcome {
        case selected(WindowCaptureCandidate)
        case cancelled
        case unavailable(CaptureError)
    }

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ScreenshotWorkspace")
    private let service: ScreenshotService
    private let artifactStore: ArtifactStore
    private let onSelectionWillBegin: () -> Void
    private let frozenFrameProvider: (@MainActor ([NSScreen]) async -> [CGDirectDisplayID: FrozenScreenshotFrame])?
    private let preparationTimeoutNanoseconds: UInt64
    private var selectionPanels: [ScreenshotSelectionPanel] = []
    private var selectionContinuation: CheckedContinuation<SelectionOutcome, Never>?
    private var windowSelectionPanels: [WindowSelectionPanel] = []
    private var windowSelectionContinuation: CheckedContinuation<WindowSelectionOutcome, Never>?
    private var toastPanel: NSPanel?
    private var selectionID: UUID?
    private var selectionWasCancelled = false
    private var cancelPreparation: (() -> Void)?
    private let focusSession = ScreenshotFocusSession()

    private(set) var isSelecting = false

    init(
        artifactStore: ArtifactStore,
        service: ScreenshotService = ScreenshotService(),
        onSelectionWillBegin: @escaping () -> Void = {},
        frozenFrameProvider: (@MainActor ([NSScreen]) async -> [CGDirectDisplayID: FrozenScreenshotFrame])? = nil,
        preparationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.artifactStore = artifactStore
        self.service = service
        self.onSelectionWillBegin = onSelectionWillBegin
        self.frozenFrameProvider = frozenFrameProvider
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
    }

    func captureSelectedRegion(operationID: UUID = UUID()) async throws -> Result {
        let request = try await selectCaptureAction(
            showsActionChoices: false,
            capturesFrozenFrame: true
        )
        return try await captureSelectedRegion(
            selected: request.selectedRegion,
            frozenFrame: request.frozenFrame,
            operationID: operationID
        )
    }

    func captureSelectedRegion(
        selected: SelectedRegion,
        frozenFrame: FrozenScreenshotFrame? = nil,
        operationID: UUID = UUID()
    ) async throws -> Result {
        try Task.checkCancellation()
        let image: CGImage
        if let frozenFrame,
           frozenFrame.displayID == selected.displayID,
           let croppedImage = frozenFrame.croppedImage(for: selected.region) {
            image = croppedImage
            logger.info(
                "screenshot.freeze.used display=\(selected.displayID, privacy: .public) width=\(croppedImage.width, privacy: .public) height=\(croppedImage.height, privacy: .public)"
            )
        } else {
            if frozenFrame != nil {
                logger.error(
                    "screenshot.freeze.cropFailed display=\(selected.displayID, privacy: .public) fallback=live"
                )
            }
            image = try await service.capture(region: selected.region, displayID: selected.displayID)
        }
        return try await store(image: image, selected: selected, operationID: operationID)
    }

    func resolveRepeatSelection(_ saved: SelectedRegion) throws -> SelectedRegion {
        let savedRect = saved.region.selectionRectInAppKitGlobalPoints
        let matchingDisplay = NSScreen.screens.first { Self.displayID(for: $0) == saved.displayID }
        guard let screen = matchingDisplay ?? Self.screen(withLargestIntersection: savedRect),
              let displayID = Self.displayID(for: screen) else {
            throw CaptureError(
                code: "screenshot_repeat_display_unavailable",
                message: "上一次截图所在显示器当前不可用"
            )
        }
        let selectionRect = savedRect.intersection(screen.frame)
        guard !selectionRect.isNull, selectionRect.width > 0, selectionRect.height > 0 else {
            throw CaptureError(
                code: "screenshot_repeat_region_offscreen",
                message: "上一次截图区域当前不在可见显示器内"
            )
        }
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: screen.frame,
            selectionRect: selectionRect,
            pixelScale: Double(screen.backingScaleFactor)
        )
        return SelectedRegion(displayID: displayID, region: region)
    }

    func captureSelectedRegionAfterCountdown(
        seconds: Int,
        operationID: UUID = UUID()
    ) async throws -> Result {
        let selected = try await selectRegion()
        try await runCountdown(seconds: seconds)
        return try await captureSelectedRegion(selected: selected, operationID: operationID)
    }

    func captureDisplayUnderPointer(operationID: UUID = UUID()) async throws -> Result {
        guard let screen = Self.screen(at: NSEvent.mouseLocation),
              let displayID = Self.displayID(for: screen) else {
            throw CaptureError(code: "screenshot_no_pointer_display", message: "无法确定鼠标所在显示器")
        }
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: screen.frame,
            selectionRect: screen.frame,
            pixelScale: Double(screen.backingScaleFactor)
        )
        let selected = SelectedRegion(displayID: displayID, region: region)
        let image = try await service.capture(region: region, displayID: displayID)
        return try await store(image: image, selected: selected, operationID: operationID)
    }

    func captureWindow(operationID: UUID = UUID()) async throws -> Result {
        let candidate = try await selectWindow()
        let selected = try selectedRegion(for: candidate)
        let scale = Self.screen(withLargestIntersection: candidate.appKitFrame)?.backingScaleFactor ?? 2
        let image = try await service.capture(window: candidate.window, pixelScale: scale)
        return try await store(image: image, selected: selected, operationID: operationID)
    }

    private func store(
        image: CGImage,
        selected: SelectedRegion,
        operationID: UUID
    ) async throws -> Result {
        try Task.checkCancellation()
        let pngData = try Self.pngData(for: image)
        let pixelSize = PixelSize(width: image.width, height: image.height)

        let session = try await artifactStore.beginArtifact(
            kind: .still,
            fileExtension: "png",
            dimensions: pixelSize,
            displayID: UInt32(selected.displayID),
            captureRegion: selected.region,
            operationID: operationID
        )
        let completed: ArtifactManifest
        do {
            completed = try await artifactStore.finalizeData(pngData, for: session)
        } catch {
            _ = try? await artifactStore.markFailed(
                for: session,
                error: CaptureError(
                    code: "screenshot_artifact_finalize_failed",
                    message: "截图产物写入失败",
                    detail: String(describing: error)
                )
            )
            throw error
        }

        logger.info("screenshot.completed canonical=\(completed.canonicalURL.path, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)")

        return Result(
            artifact: completed,
            canonicalURL: completed.canonicalURL,
            displayID: selected.displayID,
            region: selected.region,
            pixelSize: pixelSize
        )
    }

    func selectRegion() async throws -> SelectedRegion {
        let request = try await selectCaptureAction(
            showsActionChoices: false,
            capturesFrozenFrame: false
        )
        return request.selectedRegion
    }

    func selectCaptureAction() async throws -> CaptureRequest {
        try await selectCaptureAction(
            showsActionChoices: true,
            capturesFrozenFrame: true
        )
    }

    private func selectCaptureAction(
        showsActionChoices: Bool,
        capturesFrozenFrame: Bool
    ) async throws -> CaptureRequest {
        guard !isSelecting else {
            throw CaptureError(code: "screenshot_selection_busy", message: "当前已有截图选区")
        }

        focusSession.begin()
        onSelectionWillBegin()
        logger.info("screenshot.selection.requested")
        isSelecting = true
        let operationID = UUID()
        selectionID = operationID
        selectionWasCancelled = false
        defer { finishSelectionLifecycle(operationID: operationID) }

        return try await withTaskCancellationHandler {
            try checkSelectionCancellation(operationID: operationID)
            let screens = NSScreen.screens
            var frozenFrames: [CGDirectDisplayID: FrozenScreenshotFrame] = [:]
            if capturesFrozenFrame {
                let preparation = ScreenshotSelectionPreparation<[CGDirectDisplayID: FrozenScreenshotFrame]>()
                cancelPreparation = { preparation.cancel() }
                do {
                    frozenFrames = try await preparation.value(timeoutNanoseconds: preparationTimeoutNanoseconds) { [self] in
                        if let frozenFrameProvider { return await frozenFrameProvider(screens) }
                        return await captureFrozenFrames(for: screens)
                    }
                } catch is CancellationError {
                    throw CaptureError(code: "screenshot_cancelled", message: "截图已取消")
                }
                cancelPreparation = nil
            }
            try checkSelectionCancellation(operationID: operationID)
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<SelectionOutcome, Never>) in
                selectionContinuation = continuation
                presentSelectionPanels(
                    screens: screens,
                    showsActionChoices: showsActionChoices,
                    frozenFrames: frozenFrames
                )
            }
            try checkSelectionCancellation(operationID: operationID)
            if case let .unavailable(error) = outcome { throw error }
            guard case let .selected(displayID, displayFrame, pixelScale, selectionRect, action) = outcome else {
                throw CaptureError(code: "screenshot_cancelled", message: "截图已取消")
            }

            let region = try ScreenCoordinateAdapter.makeRegion(
                displayFrame: displayFrame,
                selectionRect: selectionRect,
                pixelScale: Double(pixelScale)
            )
            removeSelectionPanels()
            focusSession.restore()
            // Dynamic actions take their first live frame only after the overlay
            // is gone. Cancellation during this gap must not launch a new session.
            try await Task.sleep(nanoseconds: 100_000_000)
            try checkSelectionCancellation(operationID: operationID)
            let frozenFrame: FrozenScreenshotFrame?
            switch action {
            case .still, .pinStill: frozenFrame = frozenFrames[displayID]
            case .scroll, .recording: frozenFrame = nil
            }
            return CaptureRequest(
                selectedRegion: SelectedRegion(displayID: displayID, region: region),
                action: action,
                frozenFrame: frozenFrame
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSelection(operationID: operationID)
            }
        }
    }

    private func captureFrozenFrames(
        for screens: [NSScreen]
    ) async -> [CGDirectDisplayID: FrozenScreenshotFrame] {
        let pointer = NSEvent.mouseLocation
        let orderedScreens = screens.sorted { lhs, rhs in
            let lhsPriority = NSMouseInRect(pointer, lhs.frame, false) ? 0 : 1
            let rhsPriority = NSMouseInRect(pointer, rhs.frame, false) ? 0 : 1
            return lhsPriority < rhsPriority
        }
        var frames: [CGDirectDisplayID: FrozenScreenshotFrame] = [:]
        logger.info("screenshot.freeze.requested displays=\(screens.count, privacy: .public)")

        for screen in orderedScreens {
            guard !Task.isCancelled else { break }
            guard let displayID = Self.displayID(for: screen) else { continue }
            do {
                let fullDisplayRegion = try ScreenCoordinateAdapter.makeRegion(
                    displayFrame: screen.frame,
                    selectionRect: screen.frame,
                    pixelScale: Double(screen.backingScaleFactor)
                )
                let image = try await service.capture(
                    region: fullDisplayRegion,
                    displayID: displayID
                )
                guard !Task.isCancelled else { break }
                frames[displayID] = FrozenScreenshotFrame(
                    displayID: displayID,
                    displayFrame: screen.frame,
                    image: image
                )
                logger.info(
                    "screenshot.freeze.captured display=\(displayID, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)"
                )
            } catch {
                logger.error(
                    "screenshot.freeze.failed display=\(displayID, privacy: .public) fallback=live error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        logger.info(
            "screenshot.freeze.ready captured=\(frames.count, privacy: .public) requested=\(screens.count, privacy: .public)"
        )
        return frames
    }

    func cancel() {
        guard let selectionID else { return }
        cancelSelection(operationID: selectionID)
    }

    private func cancelSelection(operationID: UUID) {
        guard selectionID == operationID else { return }
        logger.info("screenshot.selection.cancel.requested")
        selectionWasCancelled = true
        cancelPreparation?()
        cancelPreparation = nil
        if let selectionContinuation {
            self.selectionContinuation = nil
            selectionContinuation.resume(returning: .cancelled)
        }
        if let windowSelectionContinuation {
            self.windowSelectionContinuation = nil
            windowSelectionContinuation.resume(returning: .cancelled)
        }
        removeSelectionPanels()
        removeWindowSelectionPanels()
        focusSession.restore()
    }

    private func checkSelectionCancellation(operationID: UUID) throws {
        guard selectionID == operationID, !selectionWasCancelled, !Task.isCancelled else {
            throw CaptureError(code: "screenshot_cancelled", message: "截图已取消")
        }
    }

    private func finishSelectionLifecycle(operationID: UUID) {
        guard selectionID == operationID else { return }
        cancelPreparation?()
        cancelPreparation = nil
        removeSelectionPanels()
        removeWindowSelectionPanels()
        focusSession.restore()
        selectionID = nil
        selectionWasCancelled = false
        isSelecting = false
    }

    func showNotice(_ message: String) {
        logger.info("screenshot.notice message=\(message, privacy: .public)")
        showToast(message)
    }

    /// Ends the visual overlay retained by a running scroll capture session.
    /// Once an action is chosen, selection is over while the visual guide stays.
    func endCaptureOverlay() {
        guard !selectionPanels.isEmpty else { return }
        removeSelectionPanels()
    }

    private func presentSelectionPanels(
        screens: [NSScreen],
        showsActionChoices: Bool,
        frozenFrames: [CGDirectDisplayID: FrozenScreenshotFrame]
    ) {
        guard !screens.isEmpty else {
            let error = CaptureError(
                code: "screenshot_no_visible_screen",
                message: "当前没有可见显示器，请先唤醒或连接显示器"
            )
            logger.error("screenshot.selection.unavailable reason=noVisibleScreen")
            selectionContinuation?.resume(returning: .unavailable(error))
            selectionContinuation = nil
            return
        }

        selectionPanels = screens.map { screen in
            let displayID = Self.displayID(for: screen)
            let panel = ScreenshotSelectionPanel(
                screen: screen,
                showsActionChoices: showsActionChoices,
                frozenImage: displayID.flatMap { frozenFrames[$0]?.image }
            )
            panel.onSelectionStarted = { [weak self] in
                self?.logger.info("screenshot.selection.mouseDown")
            }
            panel.onSelection = { [weak self] rect, action in
                guard let displayID else {
                    self?.finishSelection(.cancelled)
                    return
                }
                self?.logger.info(
                    "screenshot.selection.completed width=\(rect.width, privacy: .public) height=\(rect.height, privacy: .public)"
                )
                self?.finishSelection(
                    .selected(
                        displayID: displayID,
                        displayFrame: screen.frame,
                        pixelScale: screen.backingScaleFactor,
                        rect: rect,
                        action: action
                    )
                )
            }
            panel.onCancel = { [weak self] in
                self?.finishSelection(.cancelled)
            }
            return panel
        }

        selectionPanels.forEach { panel in
            panel.orderFrontRegardless()
        }
        if let firstPanel = selectionPanels.first {
            firstPanel.makeKeyAndOrderFront(nil)
            firstPanel.makeFirstResponder(firstPanel.contentView)
        }
        logger.info("screenshot.selection.presented screens=\(screens.count, privacy: .public)")
    }

    private func finishSelection(_ outcome: SelectionOutcome) {
        guard let selectionContinuation else {
            return
        }
        self.selectionContinuation = nil
        if case .cancelled = outcome {
            logger.info("screenshot.selection.cancelled")
        }
        selectionContinuation.resume(returning: outcome)
    }

    private func removeSelectionPanels() {
        selectionPanels.forEach { panel in
            panel.orderOut(nil)
            panel.contentView = nil
        }
        selectionPanels.removeAll()
    }

    private func selectWindow() async throws -> WindowCaptureCandidate {
        guard !isSelecting else {
            throw CaptureError(code: "screenshot_selection_busy", message: "当前已有截图选区")
        }
        focusSession.begin()
        onSelectionWillBegin()
        isSelecting = true
        let operationID = UUID()
        selectionID = operationID
        selectionWasCancelled = false
        defer { finishSelectionLifecycle(operationID: operationID) }

        return try await withTaskCancellationHandler {
            try checkSelectionCancellation(operationID: operationID)
            let preparation = ScreenshotSelectionPreparation<[WindowCaptureCandidate]>()
            cancelPreparation = { preparation.cancel() }
            let candidates: [WindowCaptureCandidate]
            do {
                candidates = try await preparation.value(timeoutNanoseconds: preparationTimeoutNanoseconds) { [self] in
                    try await loadWindowCandidates()
                }
            } catch is CancellationError {
                throw CaptureError(code: "screenshot_cancelled", message: "截图已取消")
            }
            cancelPreparation = nil
            try checkSelectionCancellation(operationID: operationID)
            guard !candidates.isEmpty else {
                throw CaptureError(code: "screenshot_no_shareable_window", message: "当前没有可截图的窗口")
            }

            let outcome = await withCheckedContinuation {
                (continuation: CheckedContinuation<WindowSelectionOutcome, Never>) in
                windowSelectionContinuation = continuation
                presentWindowSelectionPanels(candidates: candidates)
            }
            try checkSelectionCancellation(operationID: operationID)
            removeWindowSelectionPanels()
            focusSession.restore()
            try await Task.sleep(nanoseconds: 100_000_000)
            try checkSelectionCancellation(operationID: operationID)
            switch outcome {
            case let .selected(candidate): return candidate
            case .cancelled:
                throw CaptureError(code: "screenshot_cancelled", message: "截图已取消")
            case let .unavailable(error): throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSelection(operationID: operationID)
            }
        }
    }

    private func loadWindowCandidates() async throws -> [WindowCaptureCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let orderedWindowIDs = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]])?.compactMap { info in
            (info[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
        } ?? []
        let order = Dictionary(uniqueKeysWithValues: orderedWindowIDs.enumerated().map { ($0.element, $0.offset) })
        let mainDisplayMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        return content.windows.compactMap { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.owningApplication?.processID != selfPID,
                  window.frame.width >= 80,
                  window.frame.height >= 50 else { return nil }
            let frame = WindowCaptureGeometry.appKitFrame(
                quartzFrame: window.frame,
                mainDisplayMaxY: mainDisplayMaxY
            )
            guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
            return WindowCaptureCandidate(
                window: window,
                appKitFrame: frame,
                ownerName: window.owningApplication?.applicationName ?? "窗口",
                title: window.title ?? "",
                zIndex: order[window.windowID] ?? Int.max
            )
        }.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.window.windowID < rhs.window.windowID
        }
    }

    private func presentWindowSelectionPanels(candidates: [WindowCaptureCandidate]) {
        guard !NSScreen.screens.isEmpty else {
            windowSelectionContinuation?.resume(returning: .unavailable(
                CaptureError(code: "screenshot_no_visible_screen", message: "当前没有可见显示器")
            ))
            windowSelectionContinuation = nil
            return
        }
        windowSelectionPanels = NSScreen.screens.map { screen in
            let panel = WindowSelectionPanel(screen: screen, candidates: candidates)
            panel.onSelection = { [weak self] candidate in
                self?.finishWindowSelection(.selected(candidate))
            }
            panel.onCancel = { [weak self] in
                self?.finishWindowSelection(.cancelled)
            }
            return panel
        }
        windowSelectionPanels.forEach { $0.orderFrontRegardless() }
        if let first = windowSelectionPanels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
        logger.info("screenshot.windowSelection.presented candidates=\(candidates.count, privacy: .public)")
    }

    private func finishWindowSelection(_ outcome: WindowSelectionOutcome) {
        guard let continuation = windowSelectionContinuation else { return }
        windowSelectionContinuation = nil
        continuation.resume(returning: outcome)
    }

    private func removeWindowSelectionPanels() {
        windowSelectionPanels.forEach { panel in
            panel.orderOut(nil)
            panel.contentView = nil
        }
        windowSelectionPanels.removeAll()
    }

    private func selectedRegion(for candidate: WindowCaptureCandidate) throws -> SelectedRegion {
        guard let screen = Self.screen(withLargestIntersection: candidate.appKitFrame),
              let displayID = Self.displayID(for: screen) else {
            throw CaptureError(code: "screenshot_window_offscreen", message: "所选窗口不在可见显示器内")
        }
        let visibleRect = candidate.appKitFrame.intersection(screen.frame)
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: screen.frame,
            selectionRect: visibleRect,
            pixelScale: Double(screen.backingScaleFactor)
        )
        return SelectedRegion(displayID: displayID, region: region)
    }

    private func runCountdown(seconds: Int) async throws {
        let seconds = max(1, seconds)
        let panel = toastPanel ?? makeToastPanel()
        toastPanel = panel
        positionToast(panel)
        defer { panel.orderOut(nil) }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            (panel.contentView as? NSTextField)?.stringValue = "定时截图：\(remaining)"
            panel.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private static func screen(withLargestIntersection rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(rect)
            let rhsIntersection = rhs.frame.intersection(rect)
            return lhsIntersection.width * lhsIntersection.height
                < rhsIntersection.width * rhsIntersection.height
        }
    }

    static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureError(code: "screenshot_writer_unavailable", message: "无法创建 PNG 输出")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError(code: "screenshot_write_failed", message: "PNG 写入失败")
        }
        return data as Data
    }


    private func showToast(_ message: String) {
        let panel = toastPanel ?? makeToastPanel()
        toastPanel = panel
        positionToast(panel)
        (panel.contentView as? NSTextField)?.stringValue = message
        panel.orderFrontRegardless()
        Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            panel?.orderOut(nil)
        }
    }

    private func positionToast(_ panel: NSPanel) {
        guard let screen = Self.screen(at: NSEvent.mouseLocation) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrame(
            CGRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 36,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func makeToastPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 430, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        label.drawsBackground = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 10
        label.layer?.masksToBounds = true
        panel.contentView = label
        return panel
    }
}

@MainActor
final class ScreenshotService {
    func capture(region: CaptureRegion, displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError(code: "display_not_shareable", message: "截图所在显示器不可采集")
        }

        let filter = makeFilter(content: content, display: display)
        let configuration = SCStreamConfiguration()
        configuration.width = region.pixelRectInCaptureSpace.width
        configuration.height = region.pixelRectInCaptureSpace.height
        configuration.sourceRect = region.sourceRectInPlatformLogicalPoints
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false

        if #available(macOS 14.0, *) {
            return try await captureWithScreenshotManager(
                filter: filter,
                configuration: configuration
            )
        }
        return try await captureWithStream(filter: filter, configuration: configuration)
    }

    func capture(window: SCWindow, pixelScale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * pixelScale).rounded()))
        configuration.height = max(1, Int((window.frame.height * pixelScale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = false
            return try await captureWithScreenshotManager(
                filter: filter,
                configuration: configuration
            )
        }
        return try await captureWithStream(filter: filter, configuration: configuration)
    }

    @available(macOS 14.0, *)
    private func captureWithScreenshotManager(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: CaptureError(code: "screenshot_empty", message: "截图返回空图像")
                    )
                }
            }
        }
    }

    private func captureWithStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let receiver = SingleFrameImageReceiver()
        let queue = DispatchQueue(label: "com.hanshuai.DisplayMonitor.screenshot.frame")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        let imageTask = Task { try await receiver.nextImage() }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            receiver.fail(CaptureError(code: "screenshot_timeout", message: "截图采集超时"))
        }

        do {
            try await stream.startCapture()
            let image = try await imageTask.value
            timeoutTask.cancel()
            try await stream.stopCapture()
            try? stream.removeStreamOutput(receiver, type: .screen)
            return image
        } catch {
            timeoutTask.cancel()
            imageTask.cancel()
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(receiver, type: .screen)
            throw error
        }
    }

    private func makeFilter(content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        CurrentProcessCaptureFilter.make(content: content, display: display)
    }
}

private final class SingleFrameImageReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    private let context = CIContext()
    private let stream: AsyncThrowingStream<CGImage, Error>
    private let continuation: AsyncThrowingStream<CGImage, Error>.Continuation

    override init() {
        var continuation: AsyncThrowingStream<CGImage, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    func nextImage() async throws -> CGImage {
        var iterator = stream.makeAsyncIterator()
        guard let image = try await iterator.next() else {
            throw CaptureError(code: "screenshot_empty", message: "截图没有收到有效帧")
        }
        return image
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              frameStatus(for: sampleBuffer) == .complete,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard let image = context.createCGImage(
            CIImage(cvPixelBuffer: imageBuffer),
            from: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            continuation.finish(throwing: CaptureError(code: "screenshot_conversion_failed", message: "无法转换截图帧"))
            return
        }
        continuation.yield(image)
        continuation.finish()
    }

    private func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: rawStatus)
    }
}

@MainActor
private final class WindowSelectionPanel: NSPanel {
    var onSelection: ((WindowCaptureCandidate) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, candidates: [WindowCaptureCandidate]) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = WindowSelectionView(
            screenFrame: screen.frame,
            candidates: candidates,
            onSelection: { [weak self] candidate in self?.onSelection?(candidate) },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class WindowSelectionView: NSView {
    private let screenFrame: CGRect
    private let candidates: [WindowCaptureCandidate]
    private let onSelection: (WindowCaptureCandidate) -> Void
    private let onCancel: () -> Void
    private var highlightedCandidate: WindowCaptureCandidate?
    private var trackingArea: NSTrackingArea?

    init(
        screenFrame: CGRect,
        candidates: [WindowCaptureCandidate],
        onSelection: @escaping (WindowCaptureCandidate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.candidates = candidates
        self.onSelection = onSelection
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHighlight(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        updateHighlight(at: NSEvent.mouseLocation)
        guard let highlightedCandidate else {
            NSSound.beep()
            return
        }
        onSelection(highlightedCandidate)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let candidate = highlightedCandidate {
            let rect = localRect(for: candidate.appKitFrame.intersection(screenFrame))
            let dimming = NSBezierPath(rect: bounds)
            dimming.append(NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9))
            dimming.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.28).setFill()
            dimming.fill()
            let highlight = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.systemYellow.setStroke()
            highlight.lineWidth = 3
            highlight.stroke()
            drawWindowLabel(candidate, above: rect)
        } else {
            NSColor.black.withAlphaComponent(0.28).setFill()
            bounds.fill()
        }
        drawInstruction()
    }

    private func updateHighlight(at globalPoint: CGPoint) {
        let candidate = candidates.first { $0.appKitFrame.contains(globalPoint) }
        guard candidate?.window.windowID != highlightedCandidate?.window.windowID else { return }
        highlightedCandidate = candidate
        needsDisplay = true
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func drawWindowLabel(_ candidate: WindowCaptureCandidate, above rect: CGRect) {
        let text = candidate.title.isEmpty
            ? candidate.ownerName
            : "\(candidate.ownerName) — \(candidate.title)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .paragraphStyle: paragraph
        ]
        let size = text.size(withAttributes: attributes)
        let width = min(bounds.width - 24, size.width + 22)
        let labelRect = CGRect(
            x: min(max(12, rect.minX), bounds.maxX - width - 12),
            y: max(12, rect.minY - 34),
            width: width,
            height: 28
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 8, yRadius: 8).fill()
        text.draw(
            in: CGRect(
                x: labelRect.minX + 11,
                y: labelRect.midY - size.height / 2,
                width: max(1, labelRect.width - 22),
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func drawInstruction() {
        let text = "移动鼠标选择窗口，单击截图  ·  Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(
            x: bounds.midX - (size.width + 30) / 2,
            y: bounds.maxY - 54,
            width: size.width + 30,
            height: 34
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 17, yRadius: 17).fill()
        text.draw(
            at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

@MainActor
private final class ScreenshotSelectionPanel: NSPanel {
    var onSelection: ((CGRect, CaptureAction) -> Void)?
    var onCancel: (() -> Void)?
    var onSelectionStarted: (() -> Void)?

    init(
        screen: NSScreen,
        showsActionChoices: Bool,
        frozenImage: CGImage?
    ) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = ScreenshotSelectionView(
            showsActionChoices: showsActionChoices,
            frozenImage: frozenImage,
            pixelScale: screen.backingScaleFactor,
            onSelection: { [weak self] rect, action in self?.onSelection?(rect, action) },
            onCancel: { [weak self] in self?.onCancel?() },
            onSelectionStarted: { [weak self] in self?.onSelectionStarted?() }
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum ScreenshotSelectionInteraction {
    case creating(startPoint: CGPoint)
    case editing(
        handle: SelectionHandle,
        startPoint: CGPoint,
        geometry: SelectionGeometry
    )
}

@MainActor
private final class ScreenshotSelectionView: NSView {
    private let onSelection: (CGRect, CaptureAction) -> Void
    private let onCancel: () -> Void
    private let onSelectionStarted: () -> Void
    private let showsActionChoices: Bool
    private let frozenSnapshot: NSImage?
    private let frozenImage: CGImage?
    private let pixelScale: CGFloat
    private let actionBarView = ScreenshotSelectionActionBar()
    private let doneButton = ScreenshotSelectionActionButton(
        title: "截图",
        symbol: CaptureAction.still.symbolName,
        role: .primary
    )
    private let scrollButton = ScreenshotSelectionActionButton(
        title: "滚动截图",
        symbol: CaptureAction.scroll.symbolName,
        customImage: ScreenshotSelectionIconFactory.scrollCaptureImage(),
        role: .secondary
    )
    private let recordingButton = ScreenshotSelectionActionButton(
        title: "区域录屏",
        symbol: CaptureAction.recording.symbolName,
        role: .recording
    )
    private let pinButton = ScreenshotSelectionActionButton(
        title: "截图并固定到桌面",
        symbol: CaptureAction.pinStill.symbolName,
        role: .secondary
    )
    private var selectionGeometry: SelectionGeometry?
    private var interaction: ScreenshotSelectionInteraction?
    private var pointerPoint: CGPoint?
    private var keyboardMagnifierVisible = false
    private var statusText: String?
    private var statusIsWarning = false
    private var trackingArea: NSTrackingArea?

    init(
        showsActionChoices: Bool,
        frozenImage: CGImage?,
        pixelScale: CGFloat = 1,
        onSelection: @escaping (CGRect, CaptureAction) -> Void,
        onCancel: @escaping () -> Void,
        onSelectionStarted: @escaping () -> Void
    ) {
        self.showsActionChoices = showsActionChoices
        self.frozenImage = frozenImage
        self.pixelScale = pixelScale.isFinite && pixelScale > 0 ? pixelScale : 1
        frozenSnapshot = frozenImage.map {
            NSImage(
                cgImage: $0,
                size: CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
            )
        }
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.onSelectionStarted = onSelectionStarted
        super.init(frame: .zero)
        wantsLayer = true
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(completeSelection)
        pinButton.toolTip = "截图并固定到桌面"
        pinButton.target = self
        pinButton.action = #selector(choosePinnedScreenshot)
        scrollButton.target = self
        scrollButton.action = #selector(chooseScrollCapture)
        recordingButton.target = self
        recordingButton.action = #selector(chooseRecording)
        actionBarView.isHidden = true
        addSubview(actionBarView)
        [doneButton, scrollButton, recordingButton, pinButton].forEach {
            $0.isHidden = true
            actionBarView.addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        updateActionButtons()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFrozenSnapshot()
        if let geometry = selectionGeometry,
           geometry.rect.width > 0,
           geometry.rect.height > 0 {
            let dimmingPath = NSBezierPath(rect: bounds)
            dimmingPath.append(NSBezierPath(rect: geometry.rect))
            dimmingPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.38).setFill()
            dimmingPath.fill()
            drawSelection(geometry)
        } else {
            NSColor.black.withAlphaComponent(0.38).setFill()
            bounds.fill()
        }

        if let pointerPoint, shouldDrawCrosshair {
            drawCrosshair(at: pointerPoint)
        }
        if let pointerPoint, shouldDrawCrosshair || interaction != nil || keyboardMagnifierVisible {
            drawMagnifier(at: pointerPoint)
        }

        if let statusText {
            drawInstruction(statusText, isWarning: statusIsWarning)
        } else if selectionGeometry?.isValid != true {
            drawInstruction(
                frozenSnapshot == nil ? "实时画面 · 拖动框选，确认时截取" : "画面已冻结 · 拖动框选",
                isWarning: false
            )
        } else {
            drawInstruction("方向键移 1 像素 · ⇧ 10 像素 · ⌥方向键调右/下边", isWarning: false)
        }
    }

    private func drawFrozenSnapshot() {
        guard let frozenSnapshot else { return }
        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .high
        frozenSnapshot.draw(
            in: bounds,
            from: CGRect(origin: .zero, size: frozenSnapshot.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let previousInterpolation {
            NSGraphicsContext.current?.imageInterpolation = previousInterpolation
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelectionStarted()
        keyboardMagnifierVisible = false
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = clamped(event.locationInWindow)
        pointerPoint = point
        statusText = nil
        statusIsWarning = false

        if let geometry = selectionGeometry, geometry.rect.width > 0, geometry.rect.height > 0 {
            let handle = geometry.hitTest(point)
            if handle == .none {
                interaction = .creating(startPoint: point)
                selectionGeometry = SelectionGeometry(
                    displayBounds: bounds,
                    rect: CGRect(origin: point, size: .zero)
                )
            } else {
                interaction = .editing(
                    handle: handle,
                    startPoint: point,
                    geometry: geometry
                )
            }
        } else {
            interaction = .creating(startPoint: point)
            selectionGeometry = SelectionGeometry(
                displayBounds: bounds,
                rect: CGRect(origin: point, size: .zero)
            )
        }
        refreshDisplay()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(event.locationInWindow)
        pointerPoint = point

        guard let interaction else {
            refreshDisplay()
            return
        }

        switch interaction {
        case let .creating(startPoint):
            selectionGeometry = SelectionGeometry(
                displayBounds: bounds,
                rect: normalizedRect(from: startPoint, to: point)
            )
        case let .editing(handle, startPoint, geometry):
            if handle == .move {
                selectionGeometry = geometry.moved(
                    by: CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
                )
            } else {
                selectionGeometry = geometry.resized(handle: handle, to: point)
            }
        }
        refreshDisplay()
    }

    override func mouseUp(with event: NSEvent) {
        pointerPoint = clamped(event.locationInWindow)
        guard let interaction, let geometry = selectionGeometry else {
            refreshDisplay()
            return
        }
        defer {
            self.interaction = nil
            refreshDisplay()
        }

        switch interaction {
        case .creating:
            guard geometry.isValid else {
                selectionGeometry = nil
                statusText = "选区太小，请重新框选"
                statusIsWarning = true
                return
            }
            statusText = nil
            statusIsWarning = false
        case .editing:
            guard geometry.isValid else { return }
            statusText = nil
            statusIsWarning = false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerPoint = clamped(event.locationInWindow)
        keyboardMagnifierVisible = false
        refreshDisplay()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 || event.charactersIgnoringModifiers == "\r" {
            completeSelection()
            return
        }
        let direction: ScreenshotNudgeDirection?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: direction = nil
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let direction, let geometry = selectionGeometry,
           !modifiers.contains(.command), !modifiers.contains(.control) {
            selectionGeometry = ScreenshotPrecisionGeometry.adjusted(
                geometry,
                direction: direction,
                pixelScale: effectivePixelScale,
                accelerated: modifiers.contains(.shift),
                resize: modifiers.contains(.option)
            )
            pointerPoint = CGPoint(x: selectionGeometry!.rect.maxX, y: selectionGeometry!.rect.minY)
            keyboardMagnifierVisible = true
            statusText = nil
            refreshDisplay()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if let geometry = selectionGeometry,
           geometry.isValid,
           let pointerPoint {
            switch geometry.hitTest(pointerPoint) {
            case .left, .right:
                cursor = .resizeLeftRight
            case .top, .bottom:
                cursor = .resizeUpDown
            case .move:
                cursor = .openHand
            default:
                cursor = .arrow
            }
        } else {
            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    @objc private func completeSelection() {
        finishSelection(action: .still)
    }

    @objc private func chooseScrollCapture() {
        finishSelection(action: .scroll)
    }

    @objc private func choosePinnedScreenshot() {
        finishSelection(action: .pinStill)
    }

    @objc private func chooseRecording() {
        finishSelection(action: .recording)
    }

    private func finishSelection(action: CaptureAction) {
        guard let geometry = selectionGeometry,
              geometry.isValid,
              let window else {
            statusText = "选区太小，请重新框选"
            statusIsWarning = true
            refreshDisplay()
            return
        }
        [doneButton, pinButton, scrollButton, recordingButton].forEach { $0.isEnabled = false }
        onSelection(
            CGRect(
                x: window.frame.minX + geometry.rect.minX,
                y: window.frame.minY + geometry.rect.minY,
                width: geometry.rect.width,
                height: geometry.rect.height
            ),
            action
        )
    }

    private func updateActionButtons() {
        let isValid = selectionGeometry?.isValid == true
        actionBarView.isHidden = !isValid
        doneButton.isHidden = !isValid
        doneButton.isEnabled = isValid
        pinButton.isHidden = !isValid || !showsActionChoices
        pinButton.isEnabled = isValid
        scrollButton.isHidden = !isValid || !showsActionChoices
        scrollButton.isEnabled = isValid
        recordingButton.isHidden = !isValid || !showsActionChoices
        recordingButton.isEnabled = isValid
        guard isValid, let selectionRect = selectionGeometry?.rect else {
            return
        }

        let buttonSize: CGFloat = 36
        let barPadding: CGFloat = 4
        let buttonSpacing: CGFloat = 2
        let barHeight = buttonSize + barPadding * 2
        let visibleButtons = showsActionChoices
            ? [doneButton, scrollButton, recordingButton, pinButton]
            : [doneButton]
        let contentWidth = buttonSize * CGFloat(visibleButtons.count)
            + buttonSpacing * CGFloat(max(0, visibleButtons.count - 1))
        let barWidth = contentWidth + barPadding * 2
        var x = selectionRect.midX - barWidth / 2
        var y = selectionRect.minY - barHeight - 10
        if y < bounds.minY + 8 {
            y = selectionRect.maxY + 10
        }
        x = min(max(x, bounds.minX + 8), bounds.maxX - barWidth - 8)
        y = min(max(y, bounds.minY + 8), bounds.maxY - barHeight - 8)

        actionBarView.frame = CGRect(x: x, y: y, width: barWidth, height: barHeight)

        var buttonX = barPadding
        for button in visibleButtons {
            button.frame = CGRect(
                x: buttonX,
                y: barPadding,
                width: buttonSize,
                height: buttonSize
            )
            buttonX += buttonSize + buttonSpacing
        }
    }

    private func refreshDisplay() {
        updateActionButtons()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func drawSelection(_ geometry: SelectionGeometry) {
        let selectionRect = geometry.rect
        let borderRect = selectionRect.insetBy(dx: 0.75, dy: 0.75)
        let shadowBorder = NSBezierPath(rect: borderRect)
        NSColor.black.withAlphaComponent(0.48).setStroke()
        shadowBorder.lineWidth = 3
        shadowBorder.stroke()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: borderRect)
        border.lineWidth = 1.5
        border.stroke()

        drawSizeBadge(for: selectionRect)

        guard geometry.isValid else { return }
        let handles: [CGPoint] = [
            CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.minX, y: selectionRect.minY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.minY)
        ]
        for center in handles {
            let shadowRect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            NSColor.black.withAlphaComponent(0.38).setFill()
            NSBezierPath(roundedRect: shadowRect, xRadius: 3, yRadius: 3).fill()

            let handleRect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(
                roundedRect: handleRect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 1.5,
                yRadius: 1.5
            )
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private func drawSizeBadge(for selectionRect: CGRect) {
        let imageSize = frozenImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: bounds.width * pixelScale, height: bounds.height * pixelScale)
        let pixels = FrozenScreenshotGeometry.cropRect(
            imageSize: imageSize, displayFrame: bounds, selectionRect: selectionRect
        )?.size ?? .zero
        let sizeText = "\(Int(pixels.width)) × \(Int(pixels.height)) px  ·  \(Int(selectionRect.width.rounded())) × \(Int(selectionRect.height.rounded())) pt"
        let attributedText = NSAttributedString(
            string: sizeText,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            ]
        )
        let textSize = attributedText.size()
        let badgeSize = CGSize(width: textSize.width + 12, height: 20)
        var x = selectionRect.minX
        var y = selectionRect.maxY + 8
        if y + badgeSize.height > bounds.maxY - 8 {
            y = selectionRect.maxY - badgeSize.height - 8
            x += 8
        }
        x = min(max(x, bounds.minX + 8), bounds.maxX - badgeSize.width - 8)
        let badgeRect = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.74).setFill()
        badge.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        badge.lineWidth = 0.5
        badge.stroke()
        attributedText.draw(
            at: CGPoint(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2
            )
        )
    }

    private var shouldDrawCrosshair: Bool {
        guard selectionGeometry?.isValid == true else { return true }
        if case .creating = interaction {
            return true
        }
        return false
    }

    private var effectivePixelScale: CGSize {
        guard let frozenImage, bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: pixelScale, height: pixelScale)
        }
        return CGSize(width: CGFloat(frozenImage.width) / bounds.width, height: CGFloat(frozenImage.height) / bounds.height)
    }

    private func drawMagnifier(at point: CGPoint) {
        guard let frozenImage else { return }
        let imageSize = CGSize(width: frozenImage.width, height: frozenImage.height)
        guard let sampleRect = ScreenshotPrecisionGeometry.magnifierSampleRect(
            at: point, in: bounds, imageSize: imageSize
        ), let crop = frozenImage.cropping(to: sampleRect),
           let pixel = ScreenshotPrecisionGeometry.imagePixel(at: point, in: bounds, imageSize: imageSize) else { return }
        let side: CGFloat = 145
        let boxSize = CGSize(width: side + 10, height: side + 31)
        guard bounds.width >= boxSize.width + 16, bounds.height >= boxSize.height + 16 else { return }
        var origin = CGPoint(x: point.x + 22, y: point.y + 22)
        if origin.x + boxSize.width > bounds.maxX - 8 { origin.x = point.x - boxSize.width - 22 }
        if origin.y + boxSize.height > bounds.maxY - 8 { origin.y = point.y - boxSize.height - 22 }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - boxSize.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - boxSize.height - 8)
        let box = CGRect(origin: origin, size: boxSize)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        let imageRect = CGRect(x: box.minX + 5, y: box.minY + 26, width: side, height: side)
        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: sampleRect.size).draw(in: imageRect)
        if let previousInterpolation { NSGraphicsContext.current?.imageInterpolation = previousInterpolation }
        let pixelRect = CGRect(
            x: imageRect.minX + (pixel.x - sampleRect.minX) * side / sampleRect.width,
            y: imageRect.maxY - (pixel.y - sampleRect.minY + 1) * side / sampleRect.height,
            width: side / sampleRect.width, height: side / sampleRect.height
        )
        NSColor.systemRed.setStroke()
        let outline = NSBezierPath(rect: pixelRect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        let caption = "冻结像素  \(Int(pixel.x)), \(Int(pixel.y))"
        caption.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 8), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ])
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.72).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: point.y))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y))
        path.move(to: CGPoint(x: point.x, y: bounds.minY))
        path.line(to: CGPoint(x: point.x, y: bounds.maxY))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawInstruction(_ text: String, isWarning: Bool) {
        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .font: NSFont.systemFont(ofSize: 12, weight: .regular)
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: primaryAttributes)
        attributed.append(
            NSAttributedString(string: "  ·  Esc 取消", attributes: secondaryAttributes)
        )
        let textSize = attributed.size()
        let pillSize = CGSize(width: textSize.width + 28, height: 34)
        let pillRect = CGRect(
            x: bounds.midX - pillSize.width / 2,
            y: bounds.minY + 18,
            width: pillSize.width,
            height: pillSize.height
        )
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 17, yRadius: 17)
        let fill = isWarning
            ? NSColor.systemRed.withAlphaComponent(0.88)
            : NSColor.black.withAlphaComponent(0.68)
        fill.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        attributed.draw(
            at: CGPoint(
                x: pillRect.midX - textSize.width / 2,
                y: pillRect.midY - textSize.height / 2
            )
        )
    }

    #if DEBUG
    fileprivate var fixtureSelectionRect: CGRect? { selectionGeometry?.rect }

    fileprivate func setFixtureSelection(_ rect: CGRect) {
        selectionGeometry = SelectionGeometry(displayBounds: bounds, rect: rect)
        pointerPoint = CGPoint(x: rect.midX, y: rect.midY)
        interaction = nil
        refreshDisplay()
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }
    #endif
}

#if DEBUG
@MainActor
enum ScreenshotSelectionVisualFixture {
    static let size = CGSize(width: 1_100, height: 700)
    static let selectionRect = CGRect(x: 180, y: 170, width: 600, height: 360)

    static func makeView(frozenImage: CGImage? = nil, pixelScale: CGFloat = 1) -> NSView {
        let root = ScreenshotSelectionFixtureBackgroundView(
            frame: CGRect(origin: .zero, size: size)
        )
        root.appearance = NSAppearance(named: .aqua)

        let selectionView = ScreenshotSelectionView(
            showsActionChoices: true,
            frozenImage: frozenImage,
            pixelScale: pixelScale,
            onSelection: { _, _ in },
            onCancel: {},
            onSelectionStarted: {}
        )
        selectionView.frame = root.bounds
        selectionView.autoresizingMask = [.width, .height]
        root.addSubview(selectionView)
        selectionView.setFixtureSelection(selectionRect)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        return root
    }

    static func selection(in root: NSView) -> CGRect? {
        root.subviews.compactMap { $0 as? ScreenshotSelectionView }.first?.fixtureSelectionRect
    }
}

private final class ScreenshotSelectionFixtureBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        bounds.fill()

        let windowRect = bounds.insetBy(dx: 86, dy: 64)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: windowRect, xRadius: 16, yRadius: 16).fill()

        let sidebarRect = CGRect(
            x: windowRect.minX,
            y: windowRect.minY,
            width: 190,
            height: windowRect.height
        )
        NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: sidebarRect,
            xRadius: 16,
            yRadius: 16
        ).fill()

        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        for index in 0..<5 {
            let row = CGRect(
                x: sidebarRect.minX + 24,
                y: sidebarRect.maxY - 72 - CGFloat(index) * 42,
                width: index == 1 ? 118 : 96,
                height: 10
            )
            NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
        }

        let contentX = sidebarRect.maxX + 34
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: contentX, y: windowRect.maxY - 72, width: 220, height: 18),
            xRadius: 5,
            yRadius: 5
        ).fill()
        NSColor(calibratedWhite: 0.84, alpha: 1).setFill()
        for index in 0..<3 {
            let card = CGRect(
                x: contentX + CGFloat(index) * 208,
                y: windowRect.maxY - 245,
                width: 184,
                height: 124
            )
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        }
    }
}
#endif
