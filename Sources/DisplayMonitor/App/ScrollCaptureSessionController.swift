import AppKit
import ApplicationServices
import DisplayMonitorCore
import Foundation
import OSLog

enum ScrollCaptureFollowStartPolicy {
    static func shouldArmAutomatically(
        captureHasStarted: Bool,
        captureInFlight: Bool,
        pieceCount: Int,
        targetApplicationFrontmost: Bool
    ) -> Bool {
        !captureHasStarted &&
            !captureInFlight &&
            pieceCount == 1 &&
            targetApplicationFrontmost
    }
}

/// Guards an app-driven chunk after a stable retry. A weak image match may
/// have either sign; that sign must never authorize another injected scroll.
/// The returned distance is only the manual review slider's initial hint.
enum ScrollAutomaticChunkReviewPolicy {
    static let minimumChangedSignatureDelta = 1.8

    static func suggestedReviewOffset(
        automaticDriverRunning: Bool,
        expectedOffsetPixels: Double?,
        signatureDelta: Double,
        registration: ScrollVerticalRegistration?,
        viewportHeight: Int
    ) -> Int? {
        guard automaticDriverRunning, viewportHeight > 0,
              let expectedOffsetPixels, expectedOffsetPixels.isFinite, expectedOffsetPixels > 0,
              signatureDelta.isFinite, signatureDelta > minimumChangedSignatureDelta,
              registration?.isReliable(viewportHeight: viewportHeight) != true else { return nil }
        return Int(min(Double(viewportHeight), max(1, expectedOffsetPixels.rounded())))
    }
}

/// Owns one interactive scroll-capture session. The visual selection overlay
/// stays on screen, while real scroll events pass through to the target app.
/// Each settled user scroll is captured, registered, and appended immediately;
/// only the current and previous decoded images are kept in memory.
@MainActor
final class ScrollCaptureSessionController {
    var onArtifactReady: ((ArtifactManifest) -> Void)?
    var onArtifactState: ((ArtifactManifest) -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onTerminal: ((InputLeaseReleaseReason) -> Void)?

    private struct RuntimePiece {
        var url: URL
        var relativeURL: String
        var capturedAt: Date
        var pixelSize: PixelSize
        var estimatedOffset: Int?
        var confirmedOffset: Int?
        var topY: Int
        var registrationConfidence: Double?
        var registrationOverlap: Int?
        var registrationAnchorIndex: Int?
        var sourceCropTop: Int
        var sourceCropBottom: Int
        var registrationResidual: Double?
        var registrationAmbiguityRatio: Double?
        var byteCount: Int64
        var signature: ScrollImageSignature

        func manifestPiece(
            region: CaptureRegion,
            displayID: CGDirectDisplayID
        ) -> ScrollCapturePiece {
            ScrollCapturePiece(
                relativeURL: relativeURL,
                capturedAt: capturedAt,
                sourceRect: region,
                displayID: UInt32(displayID),
                pixelSize: pixelSize,
                estimatedOffset: estimatedOffset,
                confirmedOffset: confirmedOffset,
                topY: topY,
                registrationConfidence: registrationConfidence,
                registrationOverlap: registrationOverlap,
                registrationAnchorIndex: registrationAnchorIndex,
                sourceCropTop: sourceCropTop,
                sourceCropBottom: sourceCropBottom,
                registrationResidual: registrationResidual,
                registrationAmbiguityRatio: registrationAmbiguityRatio
            )
        }

        var stitchPiece: ScrollStitchPiece {
            ScrollStitchPiece(
                url: url,
                topY: topY,
                pixelSize: pixelSize,
                sourceCropTop: sourceCropTop,
                sourceCropBottom: sourceCropBottom
            )
        }
    }

    private struct PendingManualFrame: @unchecked Sendable {
        var image: CGImage
        var signature: ScrollImageSignature
        var estimatedOffset: Int?
        var maximumOffset: Int
        var frameSequence: UInt64
    }

    private let artifactStore: ArtifactStore
    private let artifactShelfController: ArtifactShelfController
    private let resourceCoordinator: CaptureResourceCoordinator
    private let inputModeCoordinator: InputModeCoordinator
    private let monitorActive: () -> Bool
    private let limits: ScrollCaptureLimits
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ScrollCapture")
    private let hud = ScrollCaptureHUDController()
    private let frameSource: ScrollCaptureFrameSource

    private var artifactSession: ArtifactSession?
    private var sessionLeaseToken: InputLeaseToken?
    private var stateMachine = ScrollCaptureSessionStateMachine()
    private var sessionGeneration = 0
    private var selection: ScreenshotWorkspaceController.SelectedRegion?
    private var pieces: [RuntimePiece] = []
    private var registrationEdges: [ScrollRegistrationEdge] = []
    private var previousImage: CGImage?
    private var captureMode: ScrollCaptureMode = .manual
    private var userScrollCaptureStarted = false
    private var automaticFailureReason: String?
    private var startedAt: Date?
    private var targetApplicationPID: Int32?
    private var scrollSetupTask: Task<Void, Never>?
    private var scrollSettleTask: Task<Void, Never>?
    private var scrollEventMonitor: Any?
    private var hasPendingScrollBurst = false
    private var pendingScrollEventCount = 0
    private var pendingScrollDeltaY: CGFloat = 0
    private var pendingScrollStartedAt: Date?
    private var pendingScrollExplicitlyEnded = false
    private var captureInFlight = false
    private var scrollObserverArmed = false
    private var focusLossReported = false
    private var heartbeatTask: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private var targetTerminationObserver: NSObjectProtocol?
    private var targetActivationObserver: NSObjectProtocol?
    private var resourceClaimed = false
    private var isFinalizing = false
    private var previewTask: Task<Void, Never>?
    private var previewWorkTask: Task<PixelSize, Error>?
    private var previewGeneration = 0
    private var progressTracker = ScrollCaptureProgressTracker()
    private var pendingManualFrame: PendingManualFrame?
    private var pendingOffsetCorrectionIndex: Int?
    private var seamReviewResumePhase: ScrollCaptureSessionPhase?
    private var lastAcceptedFrameSequence: UInt64 = 0
    private var pendingScrollStartSequence: UInt64 = 0
    private var automaticScrollTask: Task<Void, Never>?
    private var automaticScrollStartSequence: UInt64?
    private var isAutomaticScrollRunning = false
    private var automaticScrollPointerRestoreLocation: CGPoint?
    private var automaticScrollPointerTargetLocation: CGPoint?
    /// The first stream frame is provisional. Follow mode replaces it with a
    /// fresh baseline as soon as the target application is ready; manual mode
    /// still lets the operator explicitly set the first section.
    private var captureHasStarted = false
    private var startInFlight = false
    private var shutdownRequested = false
    private var startTermination: (error: CaptureError, reason: InputLeaseReleaseReason)?

    init(
        artifactStore: ArtifactStore,
        artifactShelfController: ArtifactShelfController,
        resourceCoordinator: CaptureResourceCoordinator,
        inputModeCoordinator: InputModeCoordinator,
        monitorActive: @escaping () -> Bool,
        limits: ScrollCaptureLimits = .default,
        frameSource: ScrollCaptureFrameSource = ScrollCaptureFrameSource()
    ) {
        self.artifactStore = artifactStore
        self.artifactShelfController = artifactShelfController
        self.resourceCoordinator = resourceCoordinator
        self.inputModeCoordinator = inputModeCoordinator
        self.monitorActive = monitorActive
        self.limits = limits
        self.frameSource = frameSource
        frameSource.onStreamStopped = { [weak self] error in
            guard let self,
                  self.stateMachine.phase != .idle,
                  self.stateMachine.phase != .finalizing else { return }
            let generation = self.sessionGeneration
            Task { @MainActor [weak self] in
                guard self?.sessionGeneration == generation else { return }
                await self?.finish(
                    endReason: .cancelled,
                    terminalError: error,
                    releaseReason: .cancelled
                )
            }
        }
    }

    var isCapturing: Bool {
        stateMachine.phase.acceptsFrames || stateMachine.phase == .reviewingSeam
    }

    var isBusy: Bool {
        stateMachine.phase.isBusy || startInFlight
    }

    func start(
        selection: ScreenshotWorkspaceController.SelectedRegion,
        requestedMode: ScrollCaptureMode,
        targetApplicationPID: Int32?,
        operationID: UUID,
        leaseToken: InputLeaseToken
    ) async throws {
        guard !shutdownRequested else {
            throw CaptureError(code: "scroll_capture_cancelled", message: "应用正在退出，无法启动滚动截图")
        }
        try Task.checkCancellation()
        guard stateMachine.phase == .idle, artifactSession == nil, !startInFlight else {
            throw CaptureError(code: "scroll_capture_already_running", message: "当前已有滚动截图会话")
        }
        guard leaseToken.owner == .scrollCapture,
              leaseToken.operationID == operationID else {
            throw CaptureError(code: "scroll_capture_lease_invalid", message: "滚动截图输入租约无效")
        }
        guard stateMachine.handle(.start) else {
            throw CaptureError(code: "scroll_capture_state_invalid", message: "滚动截图状态无法启动")
        }
        sessionLeaseToken = leaseToken
        sessionGeneration &+= 1
        let generation = sessionGeneration
        startInFlight = true
        startTermination = nil
        defer { startInFlight = false }
        self.selection = selection
        captureMode = requestedMode
        userScrollCaptureStarted = false
        self.targetApplicationPID = targetApplicationPID
        automaticFailureReason = nil
        startedAt = Date()
        pieces.removeAll()
        registrationEdges.removeAll()
        previousImage = nil
        resetPendingScrollBurst()
        captureInFlight = false
        scrollObserverArmed = false
        focusLossReported = false
        progressTracker = ScrollCaptureProgressTracker()
        pendingManualFrame = nil
        pendingOffsetCorrectionIndex = nil
        seamReviewResumePhase = nil
        lastAcceptedFrameSequence = 0
        automaticScrollTask?.cancel()
        automaticScrollTask = nil
        automaticScrollStartSequence = nil
        isAutomaticScrollRunning = false
        automaticScrollPointerRestoreLocation = nil
        automaticScrollPointerTargetLocation = nil
        captureHasStarted = false

        do {
            let resourceDecision = await resourceCoordinator.acquire(.scroll, monitorActive: monitorActive())
            guard case .granted = resourceDecision else {
                let detail: String
                switch resourceDecision {
                case .queued(let reason), .rejected(let reason): detail = reason
                case .granted: detail = "资源不可用"
                }
                throw CaptureError(
                    code: "scroll_capture_resource_unavailable",
                    message: "滚动截图暂不可启动",
                    detail: detail
                )
            }
            resourceClaimed = true
            try validateStarting(generation: generation)

            let initialSize = PixelSize(
                width: selection.region.pixelRectInCaptureSpace.width,
                height: selection.region.pixelRectInCaptureSpace.height
            )
            let session = try await artifactStore.beginArtifact(
                kind: .scrollStill,
                fileExtension: "png",
                dimensions: initialSize,
                displayID: UInt32(selection.displayID),
                captureRegion: selection.region,
                limits: limits.storage,
                operationID: operationID
            )
            artifactSession = session
            try validateStarting(generation: generation)
            onArtifactState?(session.manifest)

            let initialFrame = try await frameSource.start(
                region: selection.region,
                displayID: selection.displayID
            )
            try validateStarting(generation: generation)
            try await appendInitial(initialFrame)
            try validateStarting(generation: generation)
            installDisplayObserver()
            if let targetApplicationPID,
               targetApplicationPID != Int32(ProcessInfo.processInfo.processIdentifier),
               NSRunningApplication(processIdentifier: targetApplicationPID) != nil {
                installTargetTerminationObserver(for: targetApplicationPID)
            }
            beginHeartbeat()
            _ = stateMachine.handle(
                requestedMode == .automaticFirstManualFallback ? .readyFollow : .readyManual
            )
            showHUD()
            do {
                let exclusionStrategy = try await frameSource.refreshOwnWindowExclusions(
                    displayID: selection.displayID
                )
                logger.info(
                    "scroll.capture_filter_refreshed strategy=\(exclusionStrategy, privacy: .public)"
                )
            } catch {
                // The guide is also rendered wholly outside the source rect, so
                // a transient refresh failure does not invalidate the session.
                logger.error(
                    "scroll.capture_filter_refresh_failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
            try validateStarting(generation: generation)
            logger.info(
                "scroll.session.ready_ms=\(Self.elapsedMilliseconds(since: self.startedAt ?? Date()), privacy: .public) mode=\(requestedMode.rawValue, privacy: .public) width=\(initialSize.width, privacy: .public) height=\(initialSize.height, privacy: .public)"
            )
            if requestedMode == .automaticFirstManualFallback {
                beginUserScrollCapture()
                report("滚动截图正在准备")
            } else {
                prepareTargetForManualCapture()
                report("回到原窗口，将页面停在起点")
            }
        } catch {
            let captureError = startTermination?.error ?? (error is CancellationError
                ? CaptureError(code: "scroll_capture_cancelled", message: "滚动截图已取消")
                : Self.captureError(error, code: "scroll_capture_start_failed", message: "滚动截图启动失败"))
            let reason = startTermination?.reason ?? .cancelled
            startInFlight = false
            // Shutdown can arrive after the first strip has been persisted.
            // Keep that recoverable content through the normal partial path.
            if !pieces.isEmpty, reason != .cancelled {
                await finish(endReason: .cancelled, terminalError: captureError, releaseReason: reason)
                throw captureError
            }
            if let session = artifactSession {
                if captureError.code == "scroll_capture_cancelled" {
                    _ = try? await artifactStore.discard(for: session)
                } else {
                    _ = try? await artifactStore.markFailed(for: session, error: captureError)
                }
            }
            await frameSource.stop()
            clearSession(reason: reason)
            throw captureError
        }
    }

    func captureNextManual() {
        Task { @MainActor [weak self] in
            await self?.captureNextManualImpl()
        }
    }

    /// Arms the real scroll observer after the region has been locked. Only a
    /// border-only guide and nonactivating HUD remain while the target
    /// application receives the user's wheel input.
    func beginUserScrollCapture() {
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback,
              !userScrollCaptureStarted else { return }
        guard AXIsProcessTrusted() else {
            pauseFollowingCapture(reason: "scroll_accessibility_permission_unavailable")
            return
        }
        userScrollCaptureStarted = true
        updateHUD(message: "正在准备滚动截图…")
        beginUserDrivenCapture()
    }

    func finishUserStopped() {
        guard canFinishUserCapture() else { return }
        Task { @MainActor [weak self] in
            await self?.finish(
                endReason: .userStopped,
                terminalError: nil,
                releaseReason: .completed
            )
        }
    }

    func toggleAutomaticScroll() {
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback else { return }
        guard captureHasStarted else {
            updateHUD(message: "先点一下原窗口，鼠标滚动就绪后可选自动滚动")
            return
        }
        if isAutomaticScrollRunning {
            stopAutomaticScroll(
                message: "自动滚动已暂停；可直接手动滚动，或再次开始"
            )
        } else {
            startAutomaticScroll()
        }
    }

    func useMouseScroll() {
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback else { return }
        let interruptedStart = automaticScrollStartSequence
        stopAutomaticScroll(restorePointer: false)
        guard captureHasStarted else {
            if !captureInFlight { startPreparedMouseCapture() }
            return
        }
        scrollObserverArmed = scrollEventMonitor != nil
        if let interruptedStart {
            if !hasPendingScrollBurst {
                pendingScrollStartSequence = interruptedStart
                pendingScrollStartedAt = Date()
            } else {
                pendingScrollStartSequence = min(pendingScrollStartSequence, interruptedStart)
            }
            hasPendingScrollBurst = true
            scheduleScrollCapture()
        }
        updateHUD(message: "鼠标滚动采集中：在选区内向下滚动，停下后自动拼接")
    }

    func finishAtUserConfirmedEnd() {
        guard canFinishUserCapture() else { return }
        Task { @MainActor [weak self] in
            await self?.finish(
                endReason: .endConfirmedByUser,
                terminalError: nil,
                releaseReason: .completed
            )
        }
    }

    func cancel() {
        if startInFlight {
            startTermination = (CaptureError(code: "scroll_capture_cancelled", message: "滚动截图已取消"), .cancelled)
            frameSource.cancelPendingStart()
            return
        }
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard self?.sessionGeneration == generation else { return }
            await self?.cancelAndDiscard()
        }
    }

    private func cancelAndDiscard() async {
        guard let session = artifactSession,
              stateMachine.phase != .finalizing,
              stateMachine.phase != .idle else { return }
        _ = stateMachine.handle(.beginFinalizing)
        isFinalizing = true
        stopAutomaticScroll()
        invalidatePreview()
        scrollSetupTask?.cancel()
        scrollSetupTask = nil
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        removeDisplayObserver()
        removeScrollEventObserver()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingManualFrame = nil
        pendingOffsetCorrectionIndex = nil
        seamReviewResumePhase = nil
        hud.setCancelling()
        await frameSource.stop()
        _ = try? await artifactStore.discard(for: session)
        report("滚动截图已取消并丢弃")
        clearSession(reason: .cancelled)
    }

    func stopForPermissionRevocation() async {
        await finish(
            endReason: .cancelled,
            terminalError: CaptureError(
                code: "screen_recording_permission_revoked",
                message: "屏幕录制权限已撤销，滚动截图已停止"
            ),
            releaseReason: .permissionRevoked
        )
    }

    func shutdown() async {
        shutdownRequested = true
        await finish(
            endReason: .cancelled,
            terminalError: CaptureError(
                code: "scroll_capture_application_exit",
                message: "应用退出，滚动截图保留为部分产物"
            ),
            releaseReason: .applicationTermination
        )
        while isBusy, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
    }

    private func appendInitial(_ frame: ScrollCapturedFrame) async throws {
        guard let session = artifactSession else {
            throw CaptureError(code: "scroll_session_missing", message: "滚动截图会话已结束")
        }
        let image = frame.image
        let size = PixelSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else {
            throw CaptureError(code: "scroll_initial_frame_empty", message: "滚动截图没有收到有效视口")
        }
        let generation = sessionGeneration
        let piece = try await writePiece(
            image: image,
            pixelSize: size,
            estimatedOffset: nil,
            confirmedOffset: nil,
            topY: 0,
            signature: frame.signature,
            session: session
        )
        guard generation == sessionGeneration,
              stateMachine.phase == .preparing else {
            try? FileManager.default.removeItem(at: piece.url)
            throw CancellationError()
        }
        pieces = [piece]
        registrationEdges.removeAll()
        previousImage = image
        lastAcceptedFrameSequence = frame.sequence
        let encoderMode = try resourceMode(
            projectedHeight: size.height,
            pieceCount: 1,
            additionalTemporaryBytes: 0
        )
        try await persistLedger(endReason: nil, encoderMode: encoderMode)
        guard generation == sessionGeneration,
              stateMachine.phase != .finalizing,
              stateMachine.phase != .idle else { return }
        scheduleLivePreview()
        updateHUD(message: "将页面停在起点")
    }

    private func captureNextManualImpl() async {
        guard stateMachine.phase == .manual, !captureInFlight else { return }
        guard captureMode == .manual else { return }
        if !captureHasStarted {
            guard let targetApplicationPID,
                  isTargetApplicationFrontmost(targetApplicationPID) else {
                updateHUD(message: "点一下原窗口，将页面停在起点")
                report("逐段确认尚未设定起点：目标应用不在前台")
                return
            }
            captureInFlight = true
            hud.setManualCaptureInFlight(true)
            defer {
                captureInFlight = false
                hud.setManualCaptureInFlight(false)
            }
            do {
                guard let frame = await frameSource.latestFrame() else {
                    updateHUD(message: "画面还没准备好，请稍后再试")
                    return
                }
                try await replaceInitialBaseline(with: frame)
                captureHasStarted = true
                progressTracker = ScrollCaptureProgressTracker()
                logger.info(
                    "scroll.capture.armed input=manual sequence=\(frame.sequence, privacy: .public)"
                )
                updateHUD(message: "向下滚动，再点“采集此段”")
                report("逐段确认已设定起点")
            } catch {
                logger.error(
                    "scroll.baseline.reset_failed error=\(error.localizedDescription, privacy: .public)"
                )
                updateHUD(message: "起点确认失败，请稍后再试")
            }
            return
        }
        guard let targetApplicationPID else {
            updateHUD(message: "点一下原窗口再试")
            report("手动滚动截图未采集：目标应用尚未绑定")
            return
        }
        if !isTargetApplicationFrontmost(targetApplicationPID) {
            updateHUD(message: "已暂停，点一下原窗口继续")
            report("手动滚动截图未采集：目标应用不在前台")
            return
        }
        captureInFlight = true
        hud.setManualCaptureInFlight(true)
        let segmentStartedAt = Date()
        defer {
            captureInFlight = false
            hud.setManualCaptureInFlight(false)
        }
        let generation = sessionGeneration
        do {
            guard let frame = await frameSource.stableFrame(
                after: lastAcceptedFrameSequence,
                timeout: 0.4
            ) else {
                updateHUD(message: "没有发现新内容，请向下滚动后再试")
                report("手动采集未收到新的稳定画面，本次未追加")
                return
            }
            guard generation == sessionGeneration,
                  stateMachine.phase == .manual else { return }
            guard let previous = previousImage, let previousPiece = pieces.last else {
                throw CaptureError(code: "scroll_previous_frame_missing", message: "缺少上一段滚动截图")
            }
            let analysisStartedAt = Date()
            let registration = await Task.detached(priority: .userInitiated) {
                ScrollStitcher.registerVertical(
                    previous: previous,
                    current: frame.image
                )
            }.value
            guard generation == sessionGeneration,
                  stateMachine.phase == .manual else { return }
            let estimated = registration?.offset
            if estimated == 0 {
                updateHUD(message: "页面没有移动，请向下滚动后再试")
                report("手动采集画面未发生有效位移，本次未追加")
                return
            }
            if let registration,
               registration.offset > 0,
               registration.isReliable(viewportHeight: frame.image.height) {
                guard await ensureCapacityForNextViewport() else { return }
                let appendStartedAt = Date()
                try await append(
                    frame,
                    estimatedOffset: registration.offset,
                    confirmedOffset: registration.offset,
                    registration: ScrollRegistrationEdge(
                        fromIndex: pieces.count - 1,
                        toIndex: pieces.count,
                        offset: registration.offset,
                        confidence: registration.confidence,
                        overlapPixels: registration.overlapPixels,
                        residual: registration.residual,
                        ambiguityRatio: registration.ambiguityRatio
                    )
                )
                logSegmentLatency(
                    mode: "manual",
                    startedAt: segmentStartedAt,
                    analysisStartedAt: analysisStartedAt,
                    appendStartedAt: appendStartedAt,
                    confidence: registration.confidence
                )
                report("已采集第 \(pieces.count) 段")
                return
            }
            if let registration, registration.offset < 0 {
                if case .redefineInitialSection = ScrollCaptureDirectionPolicy.decision(
                    registeredOffset: registration.offset,
                    registrationReliable: registration.isReliable(
                        viewportHeight: frame.image.height
                    ),
                    pieceCount: pieces.count
                ) {
                    do {
                        try await redefineInitialSection(
                            with: frame,
                            registeredOffset: registration.offset,
                            source: "manual"
                        )
                    } catch {
                        logger.error(
                            "scroll.baseline.redefine_failed source=manual error=\(error.localizedDescription, privacy: .public)"
                        )
                        updateHUD(message: "起点更新失败，请停下后再试")
                    }
                } else {
                    updateHUD(message: "向上位置还不稳定，请停稳后再试")
                }
                return
            }
            guard await ensureCapacityForNextViewport() else { return }
            presentManualSeamReview(
                frame: frame,
                estimatedOffset: estimated,
                maximumOffset: previousPiece.pixelSize.height,
                previousImage: previous,
                currentImage: frame.image
            )
        } catch {
            await finish(
                endReason: .cancelled,
                terminalError: Self.captureError(
                    error,
                    code: "scroll_manual_capture_failed",
                    message: "手动滚动截图采集失败"
                ),
                releaseReason: .cancelled
            )
        }
    }

    private func append(
        _ frame: ScrollCapturedFrame,
        estimatedOffset: Int?,
        confirmedOffset: Int,
        registration: ScrollRegistrationEdge? = nil,
        commitImmediately: Bool = true
    ) async throws {
        guard let session = artifactSession, !pieces.isEmpty else {
            throw CaptureError(code: "scroll_session_missing", message: "滚动截图会话已结束")
        }
        let generation = sessionGeneration
        let image = frame.image
        let size = PixelSize(width: image.width, height: image.height)
        guard size.width == pieces[0].pixelSize.width, size.height > 0 else {
            throw CaptureError(
                code: "scroll_viewport_dimensions_changed",
                message: "滚动截图期间视口尺寸已变化"
            )
        }
        let anchorIndex = registration?.fromIndex ?? max(0, pieces.count - 1)
        guard anchorIndex == pieces.count - 1 else {
            throw CaptureError(code: "scroll_registration_anchor_missing", message: "滚动截图缺少注册锚点")
        }
        let rawOffset = registration?.offset ?? confirmedOffset
        let maximumOffset = max(1, pieces[anchorIndex].pixelSize.height)
        let clampedOffset = min(max(1, rawOffset), maximumOffset)
        let topY = pieces[anchorIndex].topY + clampedOffset
        let seamPlan: ScrollSeamPlan
        if clampedOffset >= maximumOffset {
            seamPlan = ScrollSeamPlan(
                previousCropBottom: maximumOffset,
                currentCropTop: 0,
                residual: 0
            )
        } else if let previousImage,
                  let selected = await Task.detached(priority: .userInitiated, operation: {
                      ScrollStitcher.chooseSeam(
                        previous: previousImage,
                        current: image,
                        offset: clampedOffset
                      )
                  }).value {
            seamPlan = selected
        } else {
            seamPlan = ScrollStitcher.centeredSeam(
                viewportHeight: maximumOffset,
                offset: clampedOffset
            )
        }
        guard generation == sessionGeneration,
              stateMachine.phase.acceptsFrames || stateMachine.phase == .reviewingSeam else { throw CancellationError() }
        let piece = try await writePiece(
            image: image,
            pixelSize: size,
            estimatedOffset: estimatedOffset,
            confirmedOffset: clampedOffset,
            topY: topY,
            registrationConfidence: registration?.confidence,
            registrationOverlap: registration?.overlapPixels,
            registrationAnchorIndex: registration?.fromIndex,
            sourceCropTop: seamPlan.currentCropTop,
            registrationResidual: registration?.residual,
            registrationAmbiguityRatio: registration?.ambiguityRatio,
            signature: frame.signature,
            session: session
        )
        guard generation == sessionGeneration,
              stateMachine.phase.acceptsFrames || stateMachine.phase == .reviewingSeam else {
            try? FileManager.default.removeItem(at: piece.url)
            throw CancellationError()
        }
        pieces[anchorIndex].sourceCropBottom = max(
            pieces[anchorIndex].sourceCropTop,
            min(seamPlan.previousCropBottom, pieces[anchorIndex].pixelSize.height)
        )
        pieces.append(piece)
        registrationEdges.append(
            ScrollRegistrationEdge(
                fromIndex: anchorIndex,
                toIndex: pieces.count - 1,
                offset: clampedOffset,
                confidence: registration?.confidence ?? 0.5,
                overlapPixels: registration?.overlapPixels ?? max(0, size.height - clampedOffset),
                residual: registration?.residual,
                ambiguityRatio: registration?.ambiguityRatio
            )
        )
        recomputeTopYs()
        previousImage = image
        lastAcceptedFrameSequence = frame.sequence
        guard commitImmediately else { return }
        try await commitCurrentLedgerAndPreview()
    }

    private func commitCurrentLedgerAndPreview() async throws {
        let generation = sessionGeneration
        guard let outputSize = currentOutputSize() else {
            throw CaptureError(code: "scroll_output_size_invalid", message: "滚动截图拼接尺寸无效")
        }
        let encoderMode = try resourceMode(
            projectedHeight: outputSize.height,
            pieceCount: pieces.count,
            additionalTemporaryBytes: 0,
            forFinalization: true
        )
        try await persistLedger(endReason: nil, encoderMode: encoderMode)
        guard generation == sessionGeneration,
              stateMachine.phase.acceptsFrames || stateMachine.phase == .reviewingSeam else { return }
        scheduleLivePreview()
        updateHUD(message: "已采集 \(pieces.count) 段")
    }

    private func beginUserDrivenCapture() {
        scrollSetupTask?.cancel()
        scrollSetupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
            var targetApplicationPID: Int32?
            var targetWaitCount = 0
            // The selection overlay activates this app. If capture was started
            // from its menu, the source application may therefore be unknown
            // for a moment. Keep the direct-scroll session alive until an
            // external target is available; never expose manual capture merely
            // because focus restoration took longer than a fixed timeout.
            while targetApplicationPID == nil {
                guard !Task.isCancelled, self.isCapturing else { return }
                if let resolved = self.resolvedTargetApplicationPID(),
                   resolved != ownPID,
                   NSRunningApplication(processIdentifier: resolved) != nil {
                    targetApplicationPID = resolved
                    break
                }
                targetWaitCount += 1
                if targetWaitCount == 10 {
                    self.updateHUD(message: "点一下要滚动的窗口继续")
                    self.report("滚动截图正在等待目标窗口")
                    self.logger.info("scroll.target.waiting reason=unresolved")
                }
                try? await Task.sleep(
                    nanoseconds: targetWaitCount < 10 ? 50_000_000 : 250_000_000
                )
            }
            guard var targetApplicationPID else { return }
            self.targetApplicationPID = targetApplicationPID
            self.installTargetTerminationObserver(for: targetApplicationPID)

            // Install before reactivating the target so the first real wheel
            // event cannot race the focus transition. Events are ignored until
            // the baseline frame and target focus are ready.
            self.installScrollEventObserver()
            guard self.stateMachine.phase == .following else { return }
            var focusPromptShown = false
            var focusWaitCount = 0
            var lastActivationRequestedPID: Int32?
            while !Task.isCancelled, self.isCapturing {
                guard !Task.isCancelled, self.isCapturing else { return }
                if self.isTargetApplicationFrontmost(targetApplicationPID) {
                    self.focusLossReported = false
                    if ScrollCaptureFollowStartPolicy.shouldArmAutomatically(
                        captureHasStarted: self.captureHasStarted,
                        captureInFlight: self.captureInFlight,
                        pieceCount: self.pieces.count,
                        targetApplicationFrontmost: true
                    ) {
                        self.updateHUD(message: "正在确认起点…")
                        self.report("滚动截图正在确认起点")
                        self.startPreparedMouseCapture()
                    } else {
                        self.scrollObserverArmed = self.captureHasStarted
                        self.updateHUD(
                            message: self.captureHasStarted
                                ? "直接滚动即可；向上滚动会重设起点"
                                : "正在确认起点…"
                        )
                        if self.captureHasStarted {
                            self.report("滚动截图已就绪")
                        }
                    }
                    return
                }

                if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                   frontmostPID != ownPID,
                   frontmostPID != targetApplicationPID,
                   NSRunningApplication(processIdentifier: frontmostPID) != nil {
                    targetApplicationPID = frontmostPID
                    self.targetApplicationPID = frontmostPID
                    self.installTargetTerminationObserver(for: frontmostPID)
                    lastActivationRequestedPID = nil
                    focusWaitCount = 0
                    self.logger.info(
                        "scroll.target.adopted pid=\(frontmostPID, privacy: .public)"
                    )
                    continue
                }

                if lastActivationRequestedPID != targetApplicationPID,
                   let targetApplication = NSRunningApplication(
                    processIdentifier: targetApplicationPID
                   ) {
                    _ = targetApplication.activate(options: [.activateIgnoringOtherApps])
                    lastActivationRequestedPID = targetApplicationPID
                }
                focusWaitCount += 1
                if !focusPromptShown, focusWaitCount >= 5 {
                    focusPromptShown = true
                    self.updateHUD(message: "点一下要滚动的窗口继续")
                    self.report("滚动截图正在等待目标窗口")
                    self.logger.info(
                        "scroll.target.waiting reason=not_frontmost pid=\(targetApplicationPID, privacy: .public)"
                    )
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func startAutomaticScroll() {
        guard ScrollCaptureWheelInputPolicy.canStartAutomatic(
            captureInFlight: captureInFlight,
            hasPendingScrollBurst: hasPendingScrollBurst
        ) else {
            updateHUD(message: "正在拼接鼠标滚动内容，完成后再选择自动滚动")
            return
        }
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback,
              captureHasStarted,
              scrollObserverArmed,
              !isAutomaticScrollRunning,
              AXIsProcessTrusted(),
              let targetApplicationPID,
              isTargetApplicationFrontmost(targetApplicationPID) else {
            updateHUD(message: "点一下原窗口，再开始自动滚动")
            return
        }
        isAutomaticScrollRunning = true
        hud.setAutomaticScrollRunning(true)
        updateHUD(message: "自动滚动中，可随时暂停或完成")
        if let selection {
            let location = ScrollAutomaticScrollProfile.eventLocation(
                displayBounds: CGDisplayBounds(selection.displayID),
                sourceRect: selection.region.sourceRectInPlatformLogicalPoints
            )
            prepareAutomaticScrollPointerFallback(at: location)
        }
        let generation = sessionGeneration
        automaticScrollTask?.cancel()
        automaticScrollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.sessionGeneration, !self.isAutomaticScrollRunning {
                    self.automaticScrollStartSequence = nil
                }
            }
            var consecutiveNoMovement = 0
            while !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.stateMachine.phase == .following,
                  self.isAutomaticScrollRunning {
                guard let targetApplicationPID = self.targetApplicationPID,
                      self.isTargetApplicationFrontmost(targetApplicationPID) else {
                    self.stopAutomaticScroll(message: "已暂停，点一下原窗口继续")
                    return
                }
                let startSequence = self.frameSource.latestSequence
                self.automaticScrollStartSequence = startSequence
                let startingPieceCount = self.pieces.count
                let emittedLogicalDistance = await self.performAutomaticScrollChunk()
                guard !Task.isCancelled, generation == self.sessionGeneration,
                      self.isAutomaticScrollRunning else { return }
                guard emittedLogicalDistance > 0 else {
                    self.stopAutomaticScroll(message: "自动滚动未发送位移，请确认选区后重试")
                    return
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      self.isAutomaticScrollRunning,
                      !self.captureInFlight else { continue }
                self.captureInFlight = true
                do {
                    defer {
                        if generation == self.sessionGeneration {
                            self.captureInFlight = false
                            if self.hasPendingScrollBurst { self.scheduleScrollCapture() }
                        }
                    }
                    let appended = await self.captureBufferedScrollBurst(
                        minimumSequence: startSequence,
                        generation: generation,
                        estimatedTotalOffsetPixels: emittedLogicalDistance *
                            (self.selection?.region.pixelScale ?? 1),
                        programmaticScroll: true
                    )
                    if !appended, !Task.isCancelled {
                        await self.captureViewportAfterUserScroll(
                            retryCount: 0,
                            minimumSequence: startSequence,
                            generation: generation,
                            expectedAutomaticOffsetPixels: emittedLogicalDistance *
                                (self.selection?.region.pixelScale ?? 1)
                        )
                    }
                }
                guard generation == self.sessionGeneration else { return }
                self.automaticScrollStartSequence = nil
                guard !Task.isCancelled, self.isAutomaticScrollRunning else { return }
                if self.pieces.count == startingPieceCount {
                    consecutiveNoMovement += 1
                } else {
                    consecutiveNoMovement = 0
                }
                if consecutiveNoMovement >= 3 {
                    if self.pieces.count > 1 {
                        self.hud.setEndSuggestionVisible(true)
                        self.stopAutomaticScroll(
                            message: "可能已到底部，可确认完成或继续"
                        )
                    } else {
                        self.hud.setEndSuggestionVisible(false)
                        self.stopAutomaticScroll(
                            message: "没有发现新内容，请重新确认起点"
                        )
                    }
                    return
                }
            }
        }
    }

    private func stopAutomaticScroll(message: String? = nil, restorePointer: Bool = true) {
        automaticScrollTask?.cancel()
        automaticScrollTask = nil
        isAutomaticScrollRunning = false
        if restorePointer {
            restoreAutomaticScrollPointerIfUnmoved()
        } else {
            automaticScrollPointerRestoreLocation = nil
            automaticScrollPointerTargetLocation = nil
        }
        hud.setAutomaticScrollRunning(false)
        if let message, stateMachine.phase == .following {
            updateHUD(message: message)
        }
    }

    private func performAutomaticScrollChunk() async -> Double {
        guard let selection else { return 0 }
        let chunk = ScrollAutomaticScrollProfile.chunk(
            viewportLogicalHeight: selection.region.sourceRectInPlatformLogicalPoints.height
        )
        var emitted: Double = 0
        for delta in chunk.pixelDeltas {
            guard !Task.isCancelled, isAutomaticScrollRunning else { break }
            guard let targetApplicationPID,
                  isTargetApplicationFrontmost(targetApplicationPID) else {
                stopAutomaticScroll(message: "已暂停，点一下原窗口继续")
                break
            }
            guard postAutomaticScrollStep(pixelDelta: delta) else { break }
            emitted += Double(abs(delta))
            try? await Task.sleep(nanoseconds: ScrollAutomaticScrollProfile.stepIntervalNanoseconds)
        }
        return emitted
    }

    private func prepareAutomaticScrollPointerFallback(at location: CGPoint) {
        automaticScrollPointerRestoreLocation = CGEvent(source: nil)?.location
        automaticScrollPointerTargetLocation = location
        let warpResult = CGWarpMouseCursorPosition(location)
        logger.info(
            "scroll.autoscroll.started driver=hid_pixel max_step=\(ScrollAutomaticScrollProfile.maximumPixelStep, privacy: .public) x=\(Double(location.x), privacy: .public) y=\(Double(location.y), privacy: .public) pointer_warp=\(warpResult.rawValue, privacy: .public)"
        )
    }

    /// Wheel events are routed to the window beneath the physical pointer on
    /// macOS. Keep the pointer inside the selected source while Auto-Scroll is
    /// running, then restore it only if the operator did not move it manually.
    private func restoreAutomaticScrollPointerIfUnmoved() {
        defer {
            automaticScrollPointerRestoreLocation = nil
            automaticScrollPointerTargetLocation = nil
        }
        guard let restore = automaticScrollPointerRestoreLocation,
              let target = automaticScrollPointerTargetLocation,
              let current = CGEvent(source: nil)?.location else { return }
        let distance = hypot(current.x - target.x, current.y - target.y)
        guard distance <= 12 else { return }
        _ = CGWarpMouseCursorPosition(restore)
    }

    /// Commits a fresh viewport after the target application is ready. The
    /// frame captured while the area picker was closing is only provisional so
    /// selection chrome can never become the first section.
    private func startPreparedMouseCapture() {
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback,
              !captureInFlight,
              pieces.count == 1,
              let targetApplicationPID,
              isTargetApplicationFrontmost(targetApplicationPID) else {
            updateHUD(message: "点一下原窗口，将页面停在起点")
            return
        }
        captureInFlight = true
        hud.setBaselineCaptureInFlight(true)
        stopAutomaticScroll()
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.sessionGeneration {
                    self.captureInFlight = false
                    self.hud.setBaselineCaptureInFlight(false)
                }
            }
            do {
                let frame = await self.frameSource.latestFrame()
                guard generation == self.sessionGeneration,
                      self.stateMachine.phase == .following else { return }
                guard let frame else {
                    self.updateHUD(message: "画面还没准备好，请稍后再试")
                    return
                }
                guard generation == self.sessionGeneration,
                      self.stateMachine.phase == .following else { return }
                try await self.replaceInitialBaseline(with: frame)
                guard generation == self.sessionGeneration,
                      self.stateMachine.phase == .following else { return }
                self.captureHasStarted = true
                self.scrollObserverArmed = self.scrollEventMonitor != nil
                self.progressTracker = ScrollCaptureProgressTracker()
                self.hud.setEndSuggestionVisible(false)
                self.logger.info(
                    "scroll.capture.armed input=direct sequence=\(frame.sequence, privacy: .public)"
                )
                self.updateHUD(
                    message: "鼠标滚动采集中：在选区内向下滚动，停下后自动拼接"
                )
                self.report("滚动截图已就绪")
            } catch {
                guard generation == self.sessionGeneration else { return }
                self.logger.error(
                    "scroll.baseline.reset_failed error=\(error.localizedDescription, privacy: .public)"
                )
                self.updateHUD(message: "起点确认失败，请稍后再试")
            }
        }
    }

    private func replaceInitialBaseline(with frame: ScrollCapturedFrame) async throws {
        guard artifactSession != nil, pieces.count == 1 else {
            throw CaptureError(code: "scroll_baseline_unavailable", message: "滚动截图起点不可重设")
        }
        invalidatePreview()
        let generation = sessionGeneration
        let image = frame.image
        let size = PixelSize(width: image.width, height: image.height)
        guard size.width == pieces[0].pixelSize.width,
              size.height == pieces[0].pixelSize.height else {
            throw CaptureError(code: "scroll_viewport_dimensions_changed", message: "滚动截图期间视口尺寸已变化")
        }
        let destination = pieces[0].url
        let byteCount = try await Task.detached(priority: .utility) {
            try ScrollStitcher.writeViewportPNG(image: image, destination: destination)
        }.value
        guard generation == sessionGeneration,
              stateMachine.phase == .following,
              pieces.count == 1 else { throw CancellationError() }
        pieces[0].capturedAt = frame.capturedAt
        pieces[0].estimatedOffset = nil
        pieces[0].confirmedOffset = nil
        pieces[0].topY = 0
        pieces[0].registrationConfidence = nil
        pieces[0].registrationOverlap = nil
        pieces[0].registrationAnchorIndex = nil
        pieces[0].sourceCropTop = 0
        pieces[0].sourceCropBottom = size.height
        pieces[0].registrationResidual = nil
        pieces[0].registrationAmbiguityRatio = nil
        pieces[0].byteCount = byteCount
        pieces[0].signature = frame.signature
        registrationEdges.removeAll()
        previousImage = image
        lastAcceptedFrameSequence = frame.sequence
        automaticFailureReason = nil
        let encoderMode = try resourceMode(
            projectedHeight: size.height,
            pieceCount: 1,
            additionalTemporaryBytes: 0
        )
        try await persistLedger(endReason: nil, encoderMode: encoderMode)
        guard generation == sessionGeneration,
              stateMachine.phase == .following else { throw CancellationError() }
        scheduleLivePreview()
        logger.info(
            "scroll.baseline.reset sequence=\(frame.sequence, privacy: .public) bytes=\(byteCount, privacy: .public)"
        )
    }

    /// An upward movement does not become a negative ledger edge. The current
    /// viewport replaces the entire accumulated document and becomes the new
    /// first section, so the next downward movement starts from this exact
    /// visual position.
    private func redefineInitialSection(
        with frame: ScrollCapturedFrame,
        registeredOffset: Int,
        source: String
    ) async throws {
        guard let session = artifactSession, !pieces.isEmpty else {
            throw CaptureError(code: "scroll_session_missing", message: "滚动截图会话已结束")
        }
        guard case .redefineInitialSection = ScrollCaptureDirectionPolicy.decision(
            registeredOffset: registeredOffset,
            registrationReliable: true,
            pieceCount: pieces.count
        ) else {
            return
        }

        stopAutomaticScroll()
        invalidatePreview()
        let generation = sessionGeneration
        let image = frame.image
        let size = PixelSize(width: image.width, height: image.height)
        guard size.width == pieces[0].pixelSize.width,
              size.height == pieces[0].pixelSize.height else {
            throw CaptureError(
                code: "scroll_viewport_dimensions_changed",
                message: "滚动截图期间视口尺寸已变化"
            )
        }

        let previousPieces = pieces
        let previousEdges = registrationEdges
        let previousFrame = previousImage
        let previousSequence = lastAcceptedFrameSequence
        let previousProgress = progressTracker
        let previousFailureReason = automaticFailureReason
        let replacement = try await writePiece(
            image: image,
            pixelSize: size,
            estimatedOffset: nil,
            confirmedOffset: nil,
            topY: 0,
            signature: frame.signature,
            session: session
        )
        guard generation == sessionGeneration,
              stateMachine.phase.acceptsFrames else {
            try? FileManager.default.removeItem(at: replacement.url)
            throw CancellationError()
        }

        pieces = [replacement]
        registrationEdges.removeAll()
        previousImage = image
        lastAcceptedFrameSequence = frame.sequence
        progressTracker = ScrollCaptureProgressTracker()
        automaticFailureReason = nil
        hud.setEndSuggestionVisible(false)

        do {
            let encoderMode = try resourceMode(
                projectedHeight: size.height,
                pieceCount: 1,
                additionalTemporaryBytes: 0
            )
            try await persistLedger(endReason: nil, encoderMode: encoderMode)
        } catch {
            if generation == sessionGeneration {
                pieces = previousPieces
                registrationEdges = previousEdges
                previousImage = previousFrame
                lastAcceptedFrameSequence = previousSequence
                progressTracker = previousProgress
                automaticFailureReason = previousFailureReason
                scheduleLivePreview()
            }
            try? FileManager.default.removeItem(at: replacement.url)
            throw error
        }

        guard generation == sessionGeneration,
              stateMachine.phase.acceptsFrames else { return }
        scheduleLivePreview()
        let obsoleteURLs = previousPieces.map(\.url).filter { $0 != replacement.url }
        await Task.detached(priority: .utility) {
            for url in obsoleteURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
        logger.info(
            "scroll.baseline.redefined source=\(source, privacy: .public) reverse_offset=\(registeredOffset, privacy: .public) discarded=\(max(0, previousPieces.count - 1), privacy: .public) sequence=\(frame.sequence, privacy: .public)"
        )
        updateHUD(message: "已重新设定起点，向下滚动继续")
        report("向上滚动已重新定义第一段")
    }

    private func canFinishUserCapture() -> Bool {
        guard ScrollCaptureUserCompletionPolicy.decision(
            captureHasStarted: captureHasStarted,
            pieceCount: pieces.count
        ) == .finalize else {
            hud.setEndSuggestionVisible(false)
            updateHUD(message: "没有发现可拼接内容，请重新确认起点")
            report("滚动截图尚无可拼接位移，未生成单帧伪长图")
            logger.info(
                "scroll.finish.blocked reason=no_stitched_movement started=\(self.captureHasStarted, privacy: .public) pieces=\(self.pieces.count, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func postAutomaticScrollStep(pixelDelta: Int32) -> Bool {
        guard let selection else { return false }
        let displayBounds = CGDisplayBounds(selection.displayID)
        let sourceRect = selection.region.sourceRectInPlatformLogicalPoints
        let location = ScrollAutomaticScrollProfile.eventLocation(
            displayBounds: displayBounds,
            sourceRect: sourceRect
        )
        guard let event = ScrollAutomaticScrollProfile.event(pixelDelta: pixelDelta, location: location) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func prepareTargetForManualCapture() {
        scrollSetupTask?.cancel()
        let generation = sessionGeneration
        scrollSetupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
            var resolvedPID: Int32?
            for _ in 0..<10 {
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.stateMachine.phase == .manual else { return }
                if let candidate = self.resolvedTargetApplicationPID(),
                   candidate != ownPID,
                   NSRunningApplication(processIdentifier: candidate) != nil {
                    resolvedPID = candidate
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let resolvedPID,
                  let application = NSRunningApplication(processIdentifier: resolvedPID) else {
                self.updateHUD(
                    message: self.captureHasStarted
                        ? "点一下原窗口，向下滚动后再采集"
                        : "点一下原窗口，将页面停在起点"
                )
                self.report("逐段确认等待用户激活目标应用")
                return
            }
            self.targetApplicationPID = resolvedPID
            self.installTargetTerminationObserver(for: resolvedPID)
            if !self.isTargetApplicationFrontmost(resolvedPID) {
                _ = application.activate(options: [.activateIgnoringOtherApps])
            }
            for _ in 0..<15 {
                guard !Task.isCancelled,
                      generation == self.sessionGeneration,
                      self.stateMachine.phase == .manual else { return }
                if self.isTargetApplicationFrontmost(resolvedPID) {
                    self.updateHUD(
                        message: self.captureHasStarted
                            ? "向下滚动，再点“采集此段”"
                            : "将页面停在起点，然后点“设为起点”"
                    )
                    self.report("逐段确认已恢复目标应用")
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.updateHUD(
                message: self.captureHasStarted
                    ? "点一下原窗口，向下滚动后再采集"
                    : "点一下原窗口，将页面停在起点"
            )
            self.report("逐段确认等待目标应用回到前台")
        }
    }

    private func installScrollEventObserver() {
        removeScrollEventObserver()
        scrollEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaY = event.scrollingDeltaY
            let momentumEnded = event.momentumPhase.contains(.ended) ||
                event.momentumPhase.contains(.cancelled)
            let gestureEnded = momentumEnded ||
                event.phase.contains(.ended) ||
                event.phase.contains(.cancelled)
            guard deltaY != 0 || gestureEnded else { return }
            let location = NSEvent.mouseLocation
            let eventSourceUserData = event.cgEvent?.getIntegerValueField(.eventSourceUserData)
            Task { @MainActor [weak self] in
                self?.handleScrollEvent(
                    deltaY: deltaY,
                    location: location,
                    gestureEnded: gestureEnded,
                    momentumEnded: momentumEnded,
                    eventSourceUserData: eventSourceUserData
                )
            }
        }
        guard scrollEventMonitor != nil else {
            pauseFollowingCapture(reason: "scroll_event_monitor_unavailable")
            return
        }
    }

    private func removeScrollEventObserver() {
        if let scrollEventMonitor {
            NSEvent.removeMonitor(scrollEventMonitor)
            self.scrollEventMonitor = nil
        }
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        scrollObserverArmed = false
        resetPendingScrollBurst()
    }

    private func handleScrollEvent(
        deltaY: CGFloat,
        location: CGPoint,
        gestureEnded: Bool,
        momentumEnded: Bool,
        eventSourceUserData: Int64?
    ) {
        guard stateMachine.phase == .following,
              captureMode == .automaticFirstManualFallback,
              scrollObserverArmed else { return }
        let inputDecision = ScrollCaptureWheelInputPolicy.decision(
            deltaY: deltaY,
            gestureEnded: gestureEnded,
            hasPendingScrollBurst: hasPendingScrollBurst,
            eventSourceUserData: eventSourceUserData,
            automaticScrollRunning: isAutomaticScrollRunning
        )
        guard inputDecision != .ignore else { return }
        let interruptedStart = inputDecision == .stopAutomaticAndFollowMouse
            ? automaticScrollStartSequence : nil
        if inputDecision == .stopAutomaticAndFollowMouse {
            stopAutomaticScroll(message: "已切换为鼠标滚动，停下后自动拼接", restorePointer: false)
            logger.info("scroll.autoscroll.stopped reason=mouse_scroll_takeover")
        }

        if let region = selection?.region.selectionRectInAppKitGlobalPoints,
           deltaY != 0,
           !region.insetBy(dx: -8, dy: -8).contains(location) {
            return
        }

        guard let targetApplicationPID,
              isTargetApplicationFrontmost(targetApplicationPID) else {
            if !focusLossReported {
                focusLossReported = true
                updateHUD(message: "已暂停，点一下原窗口继续")
                report("滚动截图已暂停：目标应用未在前台")
            }
            return
        }

        if focusLossReported {
            focusLossReported = false
            updateHUD(message: "向下滚动，停下后自动拼接")
        }
        hud.setEndSuggestionVisible(false)
        if !hasPendingScrollBurst {
            pendingScrollStartSequence = min(interruptedStart ?? frameSource.latestSequence, frameSource.latestSequence)
            pendingScrollStartedAt = Date()
            pendingScrollEventCount = 0
            pendingScrollDeltaY = 0
            pendingScrollExplicitlyEnded = false
            updateHUD(message: "滚动中，停下后自动拼接")
        }
        hasPendingScrollBurst = true
        if let interruptedStart {
            pendingScrollStartSequence = min(pendingScrollStartSequence, interruptedStart)
        }
        if deltaY != 0 {
            pendingScrollEventCount += 1
            pendingScrollDeltaY += deltaY
        }
        // A direct-touch `.ended` can be followed by momentum events. Only a
        // momentum `.ended` is a trustworthy fast-settle signal; every later
        // nonzero event clears an earlier signal and restarts the debounce.
        pendingScrollExplicitlyEnded = momentumEnded
        scheduleScrollCapture()
    }

    private func scheduleScrollCapture() {
        guard !captureInFlight,
              hasPendingScrollBurst else { return }
        scrollSettleTask?.cancel()
        let generation = sessionGeneration
        let settleDelay: UInt64 = pendingScrollExplicitlyEnded
            ? 80_000_000
            : 260_000_000
        scrollSettleTask = Task { @MainActor [weak self] in
            do {
                // Debounce the whole physical wheel/trackpad gesture. Momentum
                // events used to produce a new checkpoint every 160 ms, so one
                // flick could trigger several competing analyses and messages.
                try await Task.sleep(nanoseconds: settleDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.sessionGeneration == generation else { return }
            self.scrollSettleTask = nil
            await self.captureSettledScrollBurst()
        }
    }

    private func captureSettledScrollBurst() async {
        guard isCapturing, hasPendingScrollBurst, !captureInFlight else { return }
        guard let targetApplicationPID,
              isTargetApplicationFrontmost(targetApplicationPID) else {
            focusLossReported = true
            updateHUD(message: "已暂停，点一下原窗口继续")
            resetPendingScrollBurst()
            return
        }
        let minimumSequence = pendingScrollStartSequence
        let eventCount = pendingScrollEventCount
        let deltaY = pendingScrollDeltaY
        let gestureDurationMS = pendingScrollStartedAt.map(Self.elapsedMilliseconds(since:)) ?? 0
        let generation = sessionGeneration
        resetPendingScrollBurst()
        captureInFlight = true
        logger.info(
            "scroll.gesture events=\(eventCount, privacy: .public) delta_y=\(Double(deltaY), privacy: .public) duration_ms=\(gestureDurationMS, privacy: .public)"
        )
        defer {
            if generation == sessionGeneration {
                captureInFlight = false
                if hasPendingScrollBurst { scheduleScrollCapture() }
            }
        }

        let appendedBufferedFrames = await captureBufferedScrollBurst(
            minimumSequence: minimumSequence,
            generation: generation,
            estimatedTotalOffsetPixels: abs(Double(deltaY)) *
                (selection?.region.pixelScale ?? 1)
        )
        if !appendedBufferedFrames {
            await captureViewportAfterUserScroll(
                retryCount: 0,
                minimumSequence: minimumSequence,
                generation: generation
            )
        }
    }

    private func resetPendingScrollBurst() {
        hasPendingScrollBurst = false
        pendingScrollEventCount = 0
        pendingScrollDeltaY = 0
        pendingScrollStartedAt = nil
        pendingScrollExplicitlyEnded = false
        pendingScrollStartSequence = 0
    }

    private func captureBufferedScrollBurst(
        minimumSequence: UInt64,
        generation: Int,
        estimatedTotalOffsetPixels: Double?,
        programmaticScroll: Bool = false
    ) async -> Bool {
        let descriptors = frameSource.frameDescriptors(after: minimumSequence)
        guard let viewportHeight = pieces.last?.pixelSize.height else { return false }
        let sequences = programmaticScroll
            ? ScrollFrameCheckpointPlanner.programmaticScrollSequences(from: descriptors)
            : ScrollFrameCheckpointPlanner.continuousGestureSequences(
                from: descriptors,
                estimatedTotalOffsetPixels: estimatedTotalOffsetPixels,
                viewportHeight: viewportHeight
            )
        guard !sequences.isEmpty else { return false }
        let signatureDeltas = pieces.last.map { anchor in
            descriptors.map { $0.signature.meanAbsoluteDifference(from: anchor.signature) }
        } ?? []
        let minimumSignatureDelta = signatureDeltas.min() ?? -1
        let maximumSignatureDelta = signatureDeltas.max() ?? -1
        logger.info(
            "scroll.gesture.frames buffered=\(descriptors.count, privacy: .public) checkpoints=\(sequences.count, privacy: .public) signature_mad_min=\(minimumSignatureDelta, privacy: .public) signature_mad_max=\(maximumSignatureDelta, privacy: .public)"
        )
        var appendedCount = 0
        var rejectedCount = 0
        var strongestRejected: ScrollVerticalRegistration?

        do {
            for sequence in sequences {
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return appendedCount > 0 }
                guard sequence > lastAcceptedFrameSequence,
                      let frame = await frameSource.materializedFrame(sequence: sequence),
                      let previous = previousImage else { continue }
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return appendedCount > 0 }
                let registration = await Task.detached(priority: .userInitiated) {
                    ScrollStitcher.registerVertical(previous: previous, current: frame.image)
                }.value
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return appendedCount > 0 }
                guard let registration else {
                    rejectedCount += 1
                    continue
                }
                if case .redefineInitialSection = ScrollCaptureDirectionPolicy.decision(
                    registeredOffset: registration.offset,
                    registrationReliable: registration.isReliable(
                        viewportHeight: frame.image.height
                    ),
                    pieceCount: pieces.count
                ) {
                    let finalSequence = sequences.last ?? sequence
                    let finalFrame = finalSequence == sequence
                        ? frame
                        : await frameSource.materializedFrame(sequence: finalSequence) ?? frame
                    guard generation == sessionGeneration,
                          stateMachine.phase == .following else { return appendedCount > 0 }
                    do {
                        try await redefineInitialSection(
                            with: finalFrame,
                            registeredOffset: registration.offset,
                            source: "buffered"
                        )
                    } catch {
                        guard generation == sessionGeneration,
                              stateMachine.phase == .following else { return appendedCount > 0 }
                        logger.error(
                            "scroll.baseline.redefine_failed source=buffered error=\(error.localizedDescription, privacy: .public)"
                        )
                        updateHUD(message: "起点更新失败，请停下后再试")
                    }
                    return true
                }
                let isLastCheckpoint = sequence == sequences.last
                let minimumAdvance = max(8, frame.image.height / 8)
                guard registration.offset >= minimumAdvance || isLastCheckpoint else {
                    continue
                }
                guard registration.offset > 0,
                      registration.isReliable(viewportHeight: frame.image.height) else {
                    rejectedCount += 1
                    if strongestRejected.map({ registration.confidence > $0.confidence }) ?? true {
                        strongestRejected = registration
                    }
                    continue
                }
                guard await ensureCapacityForNextViewport() else {
                    return true
                }
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return appendedCount > 0 }
                let edge = ScrollRegistrationEdge(
                    fromIndex: pieces.count - 1,
                    toIndex: pieces.count,
                    offset: registration.offset,
                    confidence: registration.confidence,
                    overlapPixels: registration.overlapPixels,
                    residual: registration.residual,
                    ambiguityRatio: registration.ambiguityRatio
                )
                try await append(
                    frame,
                    estimatedOffset: registration.offset,
                    confirmedOffset: registration.offset,
                    registration: edge,
                    commitImmediately: false
                )
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return appendedCount > 0 }
                _ = progressTracker.record(
                    estimatedOffset: registration.offset,
                    focusAvailable: true,
                    automaticMode: true
                )
                appendedCount += 1
            }
            guard appendedCount > 0 else {
                if let strongestRejected {
                    logger.info(
                        "scroll.registration.rejected source=buffered reason=quality offset=\(strongestRejected.offset, privacy: .public) confidence=\(strongestRejected.confidence, privacy: .public) residual=\(strongestRejected.residual, privacy: .public) ambiguity=\(strongestRejected.ambiguityRatio, privacy: .public)"
                    )
                } else {
                    logger.info("scroll.registration.rejected source=buffered reason=no_candidate")
                }
                return false
            }
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return appendedCount > 0 }
            try await commitCurrentLedgerAndPreview()
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return appendedCount > 0 }
            logger.info(
                "scroll.gesture.checkpoints sampled=\(sequences.count, privacy: .public) appended=\(appendedCount, privacy: .public) rejected=\(rejectedCount, privacy: .public)"
            )
            updateHUD(message: "已拼接，继续向下滚动")
            return true
        } catch {
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return appendedCount > 0 }
            logger.error(
                "scroll.gesture.checkpoint_failed error=\(error.localizedDescription, privacy: .public)"
            )
            pauseFollowingCapture(reason: "scroll_checkpoint_capture_failed")
            return appendedCount > 0
        }
    }

    private func captureViewportAfterUserScroll(
        retryCount: Int,
        minimumSequence: UInt64,
        generation: Int,
        expectedAutomaticOffsetPixels: Double? = nil
    ) async {
        guard generation == sessionGeneration,
              stateMachine.phase == .following else { return }
        guard previousImage != nil else { return }
        guard let targetApplicationPID,
              isTargetApplicationFrontmost(targetApplicationPID) else {
            focusLossReported = true
            updateHUD(message: "已暂停，点一下原窗口继续")
            return
        }

        do {
            let segmentStartedAt = Date()
            let frame = await frameSource.stableFrame(
                after: minimumSequence,
                timeout: retryCount == 0 ? 0.65 : 0.35
            )
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return }
            guard let frame else {
                logger.info(
                    "scroll.registration.rejected source=stable reason=no_post_event_frame retry=\(retryCount, privacy: .public) minimum_sequence=\(minimumSequence, privacy: .public)"
                )
                if retryCount == 0 {
                    await captureViewportAfterUserScroll(
                        retryCount: 1,
                        minimumSequence: minimumSequence,
                        generation: generation,
                        expectedAutomaticOffsetPixels: expectedAutomaticOffsetPixels
                    )
                } else {
                    await handleAutomaticProgress(estimatedOffset: 0)
                }
                return
            }
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return }
            let analysisStartedAt = Date()
            let previousForRegistration = previousImage
            let signatureDelta = pieces.last.map {
                frame.signature.meanAbsoluteDifference(from: $0.signature)
            } ?? -1
            let adjacentRegistration = await Task.detached(priority: .userInitiated) {
                previousForRegistration.flatMap {
                    ScrollStitcher.registerVertical(previous: $0, current: frame.image)
                }
            }.value
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return }
            logger.info(
                "scroll.registration source=stable retry=\(retryCount, privacy: .public) sequence=\(frame.sequence, privacy: .public) signature_mad=\(signatureDelta, privacy: .public) offset=\(adjacentRegistration?.offset ?? Int.min, privacy: .public) confidence=\(adjacentRegistration?.confidence ?? -1, privacy: .public) residual=\(adjacentRegistration?.residual ?? -1, privacy: .public) ambiguity=\(adjacentRegistration?.ambiguityRatio ?? -1, privacy: .public) reliable=\(adjacentRegistration?.isReliable(viewportHeight: frame.image.height) ?? false, privacy: .public)"
            )
            if let registration = adjacentRegistration,
               registration.offset > 0,
               registration.isReliable(viewportHeight: frame.image.height) {
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return }
                guard await ensureCapacityForNextViewport() else { return }
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return }
                let appendStartedAt = Date()
                let edge = ScrollRegistrationEdge(
                    fromIndex: pieces.count - 1,
                    toIndex: pieces.count,
                    offset: registration.offset,
                    confidence: registration.confidence,
                    overlapPixels: registration.overlapPixels,
                    residual: registration.residual,
                    ambiguityRatio: registration.ambiguityRatio
                )
                try await append(
                    frame,
                    estimatedOffset: registration.offset,
                    confirmedOffset: registration.offset,
                    registration: edge
                )
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return }
                _ = progressTracker.record(
                    estimatedOffset: registration.offset,
                    focusAvailable: true,
                    automaticMode: true
                )
                logSegmentLatency(
                    mode: "follow",
                    startedAt: segmentStartedAt,
                    analysisStartedAt: analysisStartedAt,
                    appendStartedAt: appendStartedAt,
                    confidence: registration.confidence
                )
                updateHUD(message: "已拼接第 \(pieces.count) 段，继续向下滚动")
                return
            }
            if let adjacentRegistration,
               case .redefineInitialSection = ScrollCaptureDirectionPolicy.decision(
                   registeredOffset: adjacentRegistration.offset,
                   registrationReliable: adjacentRegistration.isReliable(
                       viewportHeight: frame.image.height
                   ),
                   pieceCount: pieces.count
               ) {
                do {
                    try await redefineInitialSection(
                        with: frame,
                        registeredOffset: adjacentRegistration.offset,
                        source: "stable"
                    )
                } catch {
                    guard generation == sessionGeneration,
                          stateMachine.phase == .following else { return }
                    logger.error(
                        "scroll.baseline.redefine_failed source=stable error=\(error.localizedDescription, privacy: .public)"
                    )
                    updateHUD(message: "起点更新失败，请停下后再试")
                }
                return
            }

            if retryCount == 0 {
                await captureViewportAfterUserScroll(
                    retryCount: 1,
                    minimumSequence: frame.sequence,
                    generation: generation,
                    expectedAutomaticOffsetPixels: expectedAutomaticOffsetPixels
                )
            } else if let previousImage, let previousPiece = pieces.last,
                      let suggested = ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
                        automaticDriverRunning: isAutomaticScrollRunning,
                        expectedOffsetPixels: expectedAutomaticOffsetPixels,
                        signatureDelta: signatureDelta,
                        registration: adjacentRegistration,
                        viewportHeight: previousPiece.pixelSize.height
                      ) {
                guard await ensureCapacityForNextViewport() else { return }
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return }
                logger.info(
                    "scroll.autoscroll.review reason=changed_without_reliable_registration signature_mad=\(signatureDelta, privacy: .public) weak_offset=\(adjacentRegistration?.offset ?? Int.min, privacy: .public) suggested_offset=\(suggested, privacy: .public) pieces=\(self.pieces.count, privacy: .public)"
                )
                presentManualSeamReview(
                    frame: frame,
                    estimatedOffset: suggested,
                    maximumOffset: previousPiece.pixelSize.height,
                    previousImage: previousImage,
                    currentImage: frame.image
                )
                report("当前段画面已变化但接缝不可靠，自动滚动已暂停，请确认此段")
            } else if expectedAutomaticOffsetPixels == nil,
                      let adjacentRegistration,
                      adjacentRegistration.offset > 0,
                      let previousImage,
                      let previousPiece = pieces.last {
                guard await ensureCapacityForNextViewport() else { return }
                guard generation == sessionGeneration,
                      stateMachine.phase == .following else { return }
                // Matching found real downward movement but could not prove a
                // safe seam. Review only this segment, then return to smart
                // follow instead of changing the whole session to manual.
                presentManualSeamReview(
                    frame: frame,
                    estimatedOffset: adjacentRegistration.offset,
                    maximumOffset: previousPiece.pixelSize.height,
                    previousImage: previousImage,
                    currentImage: frame.image
                )
                report("当前段接缝可信度不足，等待确认后继续智能跟随")
            } else {
                await handleAutomaticProgress(
                    estimatedOffset: expectedAutomaticOffsetPixels == nil
                        ? (adjacentRegistration?.offset ?? 0) : 0
                )
            }
        } catch {
            guard generation == sessionGeneration,
                  stateMachine.phase == .following else { return }
            pauseFollowingCapture(reason: "scroll_user_capture_failed")
        }
    }

    private func handleAutomaticProgress(estimatedOffset: Int) async {
        let decision = progressTracker.record(
            estimatedOffset: estimatedOffset,
            focusAvailable: true,
            automaticMode: true,
            endBoundaryConfirmed: false
        )
        switch decision {
        case .continueCapturing:
            updateHUD(message: "没有发现新内容，继续向下滚动")
            report("本次滚动未检测到可确认位移，等待下一次滚动")
        case .needsStartReposition:
            stopAutomaticScroll()
            hud.setEndSuggestionVisible(false)
            updateHUD(message: "没有发现新内容，请重新确认起点")
            report("滚动截图尚未检测到首个位移，请重新定位并确认起点")
        case .suggestEndConfirmation(let reason):
            hud.setEndSuggestionVisible(true)
            updateHUD(message: "可能已到底部，可确认完成或继续")
            report("连续未检测到新内容（\(reason)），等待用户确认是否到底部")
        case .failed(let reason):
            pauseFollowingCapture(reason: reason)
        case .endConfirmed:
            await finish(
                endReason: .endConfirmed,
                terminalError: nil,
                releaseReason: .completed
            )
        }
    }

    private func pauseFollowingCapture(reason: String) {
        guard isCapturing else { return }
        stopAutomaticScroll()
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        resetPendingScrollBurst()
        automaticFailureReason = reason
        let message: String
        switch reason {
        case "scroll_accessibility_permission_unavailable", "scroll_event_monitor_unavailable":
            scrollObserverArmed = false
            message = "需要辅助功能权限才能跟随滚动"
        case "scroll_checkpoint_capture_failed", "scroll_user_capture_failed":
            scrollObserverArmed = scrollEventMonitor != nil
            message = "这次没有采集成功，请再滚动一次"
        default:
            scrollObserverArmed = scrollEventMonitor != nil
            message = "没有识别到这次滚动，请再试一次"
        }
        updateHUD(message: message)
        report(message)
        logger.error("scroll.follow.paused reason=\(reason, privacy: .public)")
    }

    private func ensureCapacityForNextViewport() async -> Bool {
        guard let last = pieces.last else { return false }
        let estimatedRawBytes = Int64(last.pixelSize.width) * Int64(last.pixelSize.height) * 4
        do {
            _ = try resourceMode(
                projectedHeight: last.topY + last.pixelSize.height + last.pixelSize.height,
                pieceCount: pieces.count + 1,
                additionalTemporaryBytes: estimatedRawBytes
            )
            return true
        } catch let error as CaptureError {
            await finish(endReason: .resourceLimit, terminalError: error, releaseReason: .completed)
            return false
        } catch {
            await finish(
                endReason: .resourceLimit,
                terminalError: Self.captureError(
                    error,
                    code: "scroll_resource_limit",
                    message: "滚动截图资源限制已触发"
                ),
                releaseReason: .completed
            )
            return false
        }
    }

    private func resourceMode(
        projectedHeight: Int,
        pieceCount: Int,
        additionalTemporaryBytes: Int64,
        forFinalization: Bool = false
    ) throws -> ArtifactEncoderMode {
        guard let session = artifactSession else {
            throw CaptureError(code: "scroll_session_missing", message: "滚动截图会话已结束")
        }
        let width = pieces.first?.pixelSize.width ?? session.manifest.dimensions?.width ?? 0
        guard width > 0 else {
            throw CaptureError(code: "scroll_invalid_dimensions", message: "滚动截图视口尺寸无效")
        }
        let piecesBytes = pieces.reduce(Int64(0)) { $0 + $1.byteCount }
        let rawOutputEstimate = Int64(width) * Int64(max(0, projectedHeight)) * 4
        let temporaryBytes = piecesBytes + additionalTemporaryBytes + rawOutputEstimate
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let freeBytes = try availableDiskBytes(at: session.manifest.directoryURL)
        let decision = forFinalization
            ? limits.finalizationDecision(
                width: width,
                projectedHeight: projectedHeight,
                pieceCount: pieceCount,
                temporaryBytes: temporaryBytes,
                availableDiskBytes: freeBytes
            )
            : limits.decision(
                width: width,
                projectedHeight: projectedHeight,
                pieceCount: pieceCount,
                elapsed: elapsed,
                temporaryBytes: temporaryBytes,
                availableDiskBytes: freeBytes
            )
        switch decision {
        case .allow(let mode, _):
            return mode
        case .reject(let limit):
            throw CaptureError(
                code: "scroll_resource_limit",
                message: "滚动截图达到资源限制",
                detail: limit.rawValue
            )
        }
    }

    private func writePiece(
        image: CGImage,
        pixelSize: PixelSize,
        estimatedOffset: Int?,
        confirmedOffset: Int?,
        topY: Int,
        registrationConfidence: Double? = nil,
        registrationOverlap: Int? = nil,
        registrationAnchorIndex: Int? = nil,
        sourceCropTop: Int = 0,
        sourceCropBottom: Int? = nil,
        registrationResidual: Double? = nil,
        registrationAmbiguityRatio: Double? = nil,
        signature: ScrollImageSignature,
        session: ArtifactSession
    ) async throws -> RuntimePiece {
        let ordinal = pieces.count + 1
        let relativeURL = String(
            format: "pieces/%04d-%@.png",
            ordinal,
            UUID().uuidString
        )
        let url = session.manifest.directoryURL.appendingPathComponent(relativeURL)
        let encodeStartedAt = Date()
        let byteCount = try await Task.detached(priority: .utility) {
            try ScrollStitcher.writeViewportPNG(image: image, destination: url)
        }.value
        logger.info(
            "scroll.piece.encode_ms=\(Self.elapsedMilliseconds(since: encodeStartedAt), privacy: .public) bytes=\(byteCount, privacy: .public) ordinal=\(ordinal, privacy: .public)"
        )
        return RuntimePiece(
            url: url,
            relativeURL: relativeURL,
            capturedAt: Date(),
            pixelSize: pixelSize,
            estimatedOffset: estimatedOffset,
            confirmedOffset: confirmedOffset,
            topY: topY,
            registrationConfidence: registrationConfidence,
            registrationOverlap: registrationOverlap,
            registrationAnchorIndex: registrationAnchorIndex,
            sourceCropTop: sourceCropTop,
            sourceCropBottom: sourceCropBottom ?? pixelSize.height,
            registrationResidual: registrationResidual,
            registrationAmbiguityRatio: registrationAmbiguityRatio,
            byteCount: byteCount,
            signature: signature
        )
    }

    @discardableResult
    private func persistLedger(
        endReason: ScrollCaptureEndReason?,
        encoderMode: ArtifactEncoderMode?
    ) async throws -> ArtifactManifest? {
        guard let session = artifactSession, let selection = selection else { return nil }
        let outputSize = currentOutputSize()
        let manifest = try await artifactStore.updateScrollCaptureMetadata(
            for: session,
            mode: captureMode,
            endReason: endReason,
            failureReason: automaticFailureReason,
            pieces: pieces.map { $0.manifestPiece(region: selection.region, displayID: selection.displayID) },
            outputSize: outputSize,
            outputPixelCount: outputSize.map { $0.width * $0.height },
            encoderMode: encoderMode
        )
        onArtifactState?(manifest)
        return manifest
    }

    private func recomputeTopYs() {
        guard !pieces.isEmpty else { return }
        let positions = ScrollStitcher.solveTopPositions(
            pieceCount: pieces.count,
            edges: registrationEdges
        )
        for index in pieces.indices {
            pieces[index].topY = max(0, positions[index])
        }
    }

    private func scheduleLivePreview() {
        guard let session = artifactSession,
              let outputSize = currentOutputSize(),
              let mode = currentEncoderMode() else { return }
        previewGeneration &+= 1
        let generation = previewGeneration
        previewTask?.cancel()
        previewWorkTask?.cancel()
        previewWorkTask = nil
        let destination = session.manifest.directoryURL
            .appendingPathComponent(".preview-\(UUID().uuidString).png")
        let stitchPieces = pieces.map(\.stitchPiece)
        previewTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self,
                      self.previewGeneration == generation else { return }
                let previewStartedAt = Date()
                let work = Task.detached(priority: .utility) {
                    try ScrollStitcher.writePreviewPNG(
                        pieces: stitchPieces,
                        outputSize: outputSize,
                        destination: destination
                    )
                }
                self.previewWorkTask = work
                _ = try await work.value
                guard !Task.isCancelled,
                      self.previewGeneration == generation,
                      self.artifactSession?.manifest.id == session.manifest.id else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                let manifest = try await self.artifactStore.commitScrollPreview(
                    from: destination,
                    for: session,
                    dimensions: outputSize,
                    outputPixelCount: outputSize.width * outputSize.height,
                    encoderMode: mode
                )
                guard self.previewGeneration == generation else { return }
                self.logger.info(
                    "scroll.preview.latency_ms=\(Self.elapsedMilliseconds(since: previewStartedAt), privacy: .public) pieces=\(stitchPieces.count, privacy: .public)"
                )
                self.onArtifactState?(manifest)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self?.logger.debug("scroll.preview.failed \(error.localizedDescription, privacy: .public)")
            }
            self?.previewWorkTask = nil
        }
    }

    private func invalidatePreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        previewWorkTask?.cancel()
        previewWorkTask = nil
    }

    private func finish(
        endReason: ScrollCaptureEndReason,
        terminalError: CaptureError?,
        releaseReason: InputLeaseReleaseReason
    ) async {
        if startInFlight {
            startTermination = (
                terminalError ?? CaptureError(code: "scroll_capture_cancelled", message: "滚动截图已取消"),
                releaseReason
            )
            frameSource.cancelPendingStart()
            return
        }
        guard let session = artifactSession,
              !isFinalizing,
              stateMachine.handle(.beginFinalizing) else { return }
        isFinalizing = true
        stopAutomaticScroll()
        invalidatePreview()
        scrollSetupTask?.cancel()
        scrollSetupTask = nil
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        hud.setFinalizing()
        removeDisplayObserver()
        removeScrollEventObserver()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingManualFrame = nil
        pendingOffsetCorrectionIndex = nil
        seamReviewResumePhase = nil
        hud.hideSeamReview()
        await frameSource.stop()
        previousImage = nil

        guard let outputSize = currentOutputSize(), !pieces.isEmpty else {
            let error = terminalError ?? CaptureError(
                code: "scroll_no_pieces",
                message: "滚动截图没有可拼接片段"
            )
            _ = try? await artifactStore.markFailed(for: session, error: error)
            clearSession(reason: releaseReason)
            return
        }

        do {
            let finalizationStartedAt = Date()
            let encoderMode = try resourceMode(
                projectedHeight: outputSize.height,
                pieceCount: pieces.count,
                additionalTemporaryBytes: 0,
                forFinalization: true
            )
            let effectiveEndReason: ScrollCaptureEndReason
            if automaticFailureReason != nil,
               endReason == .userStopped || endReason == .endConfirmedByUser {
                effectiveEndReason = .scrollFailedManualCompleted
            } else {
                effectiveEndReason = endReason
            }
            try await persistLedger(endReason: effectiveEndReason, encoderMode: encoderMode)
            let stitchPieces = pieces.map(\.stitchPiece)
            let destination = session.manifest.temporaryURL
            let limits = self.limits
            let actualEncoderMode = try await Task.detached(priority: .userInitiated) {
                try ScrollStitcher.writePNG(
                    pieces: stitchPieces,
                    outputSize: outputSize,
                    mode: encoderMode,
                    limits: limits,
                    destination: destination
                )
            }.value
            try await persistLedger(endReason: effectiveEndReason, encoderMode: actualEncoderMode)

            let finalError = terminalError ?? (endReason == .resourceLimit
                ? CaptureError(code: "scroll_resource_limit", message: "滚动截图达到资源限制，已保留现有内容")
                : nil)
            let artifact = try await artifactStore.finalizeTemporary(
                for: session,
                terminalStatus: finalError == nil ? .completed : .partial,
                terminalError: finalError
            )
            onArtifactReady?(artifact)
            if !shutdownRequested {
                await artifactShelfController.present(artifact)
            }
            logger.info(
                "scroll.finalize.latency_ms=\(Self.elapsedMilliseconds(since: finalizationStartedAt), privacy: .public) pieces=\(self.pieces.count, privacy: .public) width=\(outputSize.width, privacy: .public) height=\(outputSize.height, privacy: .public) encoder=\(actualEncoderMode.rawValue, privacy: .public)"
            )
            report(artifact.status == .completed ? "滚动截图已完成" : "滚动截图保留为部分产物")
        } catch {
            let captureError = Self.captureError(
                error,
                code: "scroll_stitching_failed",
                message: "滚动截图拼接失败"
            )
            _ = try? await artifactStore.markFailed(for: session, error: captureError)
            report("滚动截图失败：\(captureError.description)")
        }
        clearSession(reason: releaseReason)
    }

    private func showHUD() {
        guard let selection else { return }
        hud.show(
            region: selection.region,
            onToggleAutomaticScroll: { [weak self] in self?.toggleAutomaticScroll() },
            onUseMouseScroll: { [weak self] in self?.useMouseScroll() },
            onCaptureNext: { [weak self] in self?.captureNextManual() },
            onCorrectLastOffset: { [weak self] in self?.correctLastOffset() },
            onEndConfirmed: { [weak self] in self?.finishAtUserConfirmedEnd() },
            onFinish: { [weak self] in self?.finishUserStopped() },
            onCancel: { [weak self] in self?.cancel() }
        )
        updateHUD(
            message: captureMode == .manual
                ? "将页面停在起点，然后点“设为起点”"
                : "正在确认起点…"
        )
    }

    private func updateHUD(message: String) {
        let size = currentOutputSize()
        hud.update(
            mode: captureMode,
            pieceCount: pieces.count,
            estimatedHeight: size?.height ?? 0,
            message: message,
            canCorrectLastOffset: pieces.count > 1,
            captureHasStarted: captureHasStarted
        )
    }

    private func beginSeamReview() -> Bool {
        let resumePhase = stateMachine.phase
        guard resumePhase == .following || resumePhase == .manual,
              stateMachine.handle(.reviewSeam) else { return false }
        seamReviewResumePhase = resumePhase
        if resumePhase == .following {
            stopAutomaticScroll()
            scrollSettleTask?.cancel()
            scrollSettleTask = nil
            resetPendingScrollBurst()
            scrollObserverArmed = false
        }
        return true
    }

    private func resumeAfterSeamReview(message: String) {
        guard stateMachine.phase == .reviewingSeam else { return }
        let resumePhase = seamReviewResumePhase ?? (
            captureMode == .automaticFirstManualFallback ? .following : .manual
        )
        seamReviewResumePhase = nil
        let event: ScrollCaptureSessionEvent = resumePhase == .following
            ? .resumeFollow
            : .resumeManual
        guard stateMachine.handle(event) else { return }
        hud.hideSeamReview()
        hud.setEndSuggestionVisible(false)

        if resumePhase == .following {
            if scrollEventMonitor == nil {
                installScrollEventObserver()
            }
            guard stateMachine.phase == .following else { return }
            scrollObserverArmed = scrollEventMonitor != nil
            let targetIsFrontmost = targetApplicationPID.map(isTargetApplicationFrontmost) ?? false
            focusLossReported = !targetIsFrontmost
            updateHUD(
                message: targetIsFrontmost
                    ? "\(message)，继续滚动即可"
                    : "\(message)；请点击原窗口后继续滚动"
            )
        } else {
            updateHUD(message: "\(message)，继续滚动后采集")
        }
    }

    private func presentManualSeamReview(
        frame: ScrollCapturedFrame,
        estimatedOffset: Int?,
        maximumOffset: Int,
        previousImage: CGImage,
        currentImage: CGImage
    ) {
        guard beginSeamReview() else { return }
        pendingManualFrame = PendingManualFrame(
            image: frame.image,
            signature: frame.signature,
            estimatedOffset: estimatedOffset,
            maximumOffset: maximumOffset,
            frameSequence: frame.sequence
        )
        let suggested = min(max(1, estimatedOffset ?? maximumOffset * 2 / 3), maximumOffset)
        hud.showSeamReview(
            title: "自动匹配不够可靠，请拖动确认接缝",
            previousImage: previousImage,
            currentImage: currentImage,
            suggestedOffset: suggested,
            maximumOffset: maximumOffset,
            onApply: { [weak self] offset in self?.applyPendingManualOffset(offset) },
            onSkip: { [weak self] in self?.skipPendingManualFrame() }
        )
        updateHUD(message: "调整接缝后确认")
    }

    private func applyPendingManualOffset(_ offset: Int) {
        guard stateMachine.phase == .reviewingSeam,
              let pending = pendingManualFrame else { return }
        pendingManualFrame = nil
        let confirmed = min(max(1, offset), pending.maximumOffset)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.append(
                    ScrollCapturedFrame(
                        sequence: pending.frameSequence,
                        capturedAt: Date(),
                        image: pending.image,
                        signature: pending.signature
                    ),
                    estimatedOffset: pending.estimatedOffset,
                    confirmedOffset: confirmed
                )
                self.resumeAfterSeamReview(
                    message: "已加入第 \(self.pieces.count) 段"
                )
            } catch {
                await self.finish(
                    endReason: .cancelled,
                    terminalError: Self.captureError(
                        error,
                        code: "scroll_manual_capture_failed",
                        message: "手动接缝保存失败"
                    ),
                    releaseReason: .cancelled
                )
            }
        }
    }

    private func skipPendingManualFrame() {
        guard stateMachine.phase == .reviewingSeam else { return }
        pendingManualFrame = nil
        resumeAfterSeamReview(message: "已跳过这一段")
    }

    private func correctLastOffset() {
        guard isCapturing, pieces.count > 1 else {
            report("至少采集两段后才能校正位移")
            return
        }
        guard !captureInFlight else {
            updateHUD(message: "正在处理当前滚动，请稍后")
            return
        }
        let index = pieces.count - 1
        let previous = pieces[index - 1]
        let suggested = pieces[index].confirmedOffset ?? previous.pixelSize.height / 2
        guard beginSeamReview() else { return }
        pendingOffsetCorrectionIndex = index
        updateHUD(message: "正在载入接缝预览…")
        let generation = sessionGeneration
        let previousURL = previous.url
        let currentURL = pieces[index].url
        Task { @MainActor [weak self] in
            let images = await Task.detached(priority: .userInitiated) {
                (
                    ScrollStitcher.loadImage(at: previousURL),
                    ScrollStitcher.loadImage(at: currentURL)
                )
            }.value
            guard let self,
                  generation == self.sessionGeneration,
                  self.stateMachine.phase == .reviewingSeam,
                  self.pendingOffsetCorrectionIndex == index else { return }
            self.hud.showSeamReview(
                title: "拖动校正上一段拼接位置",
                previousImage: images.0,
                currentImage: images.1,
                suggestedOffset: suggested,
                maximumOffset: previous.pixelSize.height,
                skipTitle: "保留原接缝",
                onApply: { [weak self] offset in self?.applyLastOffsetCorrection(offset) },
                onSkip: { [weak self] in self?.cancelLastOffsetCorrection() }
            )
            self.updateHUD(message: "拖动预览调整接缝，然后确认")
        }
    }

    private func applyLastOffsetCorrection(_ offset: Int) {
        guard stateMachine.phase == .reviewingSeam,
              let index = pendingOffsetCorrectionIndex,
              index > 0,
              index < pieces.count else { return }
        pendingOffsetCorrectionIndex = nil
        let previous = pieces[index - 1]
        let confirmed = min(max(1, offset), previous.pixelSize.height)
        pieces[index].confirmedOffset = confirmed
        pieces[index].registrationConfidence = 1
        pieces[index].registrationOverlap = max(0, previous.pixelSize.height - confirmed)
        pieces[index].registrationAnchorIndex = index - 1
        pieces[index].registrationResidual = 0
        pieces[index].registrationAmbiguityRatio = nil
        let seamPlan: ScrollSeamPlan
        if confirmed >= previous.pixelSize.height {
            seamPlan = ScrollSeamPlan(
                previousCropBottom: previous.pixelSize.height,
                currentCropTop: 0,
                residual: 0
            )
        } else {
            seamPlan = ScrollStitcher.centeredSeam(
                viewportHeight: previous.pixelSize.height,
                offset: confirmed
            )
        }
        pieces[index - 1].sourceCropBottom = max(
            pieces[index - 1].sourceCropTop,
            seamPlan.previousCropBottom
        )
        pieces[index].sourceCropTop = seamPlan.currentCropTop
        registrationEdges.removeAll { $0.toIndex >= index }
        registrationEdges.append(
            ScrollRegistrationEdge(
                fromIndex: index - 1,
                toIndex: index,
                offset: confirmed,
                confidence: 1,
                overlapPixels: max(0, previous.pixelSize.height - confirmed)
            )
        )
        recomputeTopYs()
        resumeAfterSeamReview(message: "接缝已调整")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persistLedger(endReason: nil, encoderMode: self.currentEncoderMode())
                self.scheduleLivePreview()
            } catch {
                self.report("保存位移校正失败：\(error.localizedDescription)")
            }
        }
    }

    private func cancelLastOffsetCorrection() {
        pendingOffsetCorrectionIndex = nil
        resumeAfterSeamReview(message: "已取消调整")
    }

    private func currentOutputSize() -> PixelSize? {
        guard let first = pieces.first else { return nil }
        let height = pieces.map { $0.topY + $0.pixelSize.height }.max() ?? 0
        guard height > 0 else { return nil }
        return PixelSize(width: first.pixelSize.width, height: height)
    }

    private func currentEncoderMode() -> ArtifactEncoderMode? {
        guard let size = currentOutputSize() else { return nil }
        return try? resourceMode(
            projectedHeight: size.height,
            pieceCount: pieces.count,
            additionalTemporaryBytes: 0,
            forFinalization: true
        )
    }

    private func isTargetApplicationFrontmost(_ pid: Int32) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func resolvedTargetApplicationPID() -> Int32? {
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        if let targetApplicationPID,
           targetApplicationPID != ownPID,
           NSRunningApplication(processIdentifier: targetApplicationPID) != nil {
            return targetApplicationPID
        }
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ownPID,
              NSRunningApplication(processIdentifier: frontmostPID) != nil else {
            return nil
        }
        return frontmostPID
    }

    private func beginHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, let session = self.artifactSession else { return }
                try? await self.artifactStore.touchLock(session.lockToken)
            }
        }
    }

    private func installDisplayObserver() {
        removeDisplayObserver()
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let selection = self.selection else { return }
                let displayStillPresent = NSScreen.screens.contains { screen in
                    let key = NSDeviceDescriptionKey("NSScreenNumber")
                    let number = screen.deviceDescription[key] as? NSNumber
                    return number.map { CGDirectDisplayID($0.uint32Value) == selection.displayID } ?? false
                }
                await self.finish(
                    endReason: .cancelled,
                    terminalError: CaptureError(
                        code: displayStillPresent ? "scroll_display_configuration_changed" : "scroll_display_disconnected",
                        message: displayStillPresent
                            ? "显示器配置已变化，滚动截图已停止"
                            : "滚动截图显示器已断开"
                    ),
                    releaseReason: .cancelled
                )
            }
        }
    }

    private func installTargetTerminationObserver(for pid: Int32) {
        removeTargetTerminationObserver()
        targetTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier == pid else { return }
            Task { @MainActor [weak self] in
                await self?.finish(
                    endReason: .cancelled,
                    terminalError: CaptureError(
                        code: "scroll_target_application_terminated",
                        message: "目标应用已退出，滚动截图保留为部分产物"
                    ),
                    releaseReason: .cancelled
                )
            }
        }
        targetActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.stateMachine.phase == .following || self.stateMachine.phase == .manual else { return }
                if application.processIdentifier == pid {
                    self.focusLossReported = false
                    self.updateHUD(
                        message: self.stateMachine.phase == .following
                            ? (self.captureHasStarted
                                ? "直接滚动即可；向上滚动会重设起点"
                                : "正在确认起点…")
                            : "向下滚动，再点“采集此段”"
                    )
                } else if !self.focusLossReported {
                    self.focusLossReported = true
                    self.updateHUD(message: "已暂停，点一下原窗口继续")
                    self.report("滚动截图已暂停：目标应用未在前台")
                }
            }
        }
    }

    private func removeTargetTerminationObserver() {
        if let targetTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(targetTerminationObserver)
            self.targetTerminationObserver = nil
        }
        if let targetActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(targetActivationObserver)
            self.targetActivationObserver = nil
        }
    }

    private func removeDisplayObserver() {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
    }

    private func availableDiskBytes(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        return ArtifactDiskCapacity.availableBytes(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            ordinary: values.volumeAvailableCapacity.map(Int64.init)
        )
    }

    private func clearSession(reason: InputLeaseReleaseReason) {
        let hadActiveSession = artifactSession != nil ||
            sessionLeaseToken != nil ||
            resourceClaimed ||
            stateMachine.phase != .idle
        sessionGeneration &+= 1
        stopAutomaticScroll()
        invalidatePreview()
        scrollSetupTask?.cancel()
        scrollSetupTask = nil
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        removeScrollEventObserver()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        removeDisplayObserver()
        removeTargetTerminationObserver()
        hud.hide()
        artifactSession = nil
        selection = nil
        pieces.removeAll()
        registrationEdges.removeAll()
        previousImage = nil
        startedAt = nil
        targetApplicationPID = nil
        automaticFailureReason = nil
        userScrollCaptureStarted = false
        resetPendingScrollBurst()
        captureInFlight = false
        focusLossReported = false
        progressTracker = ScrollCaptureProgressTracker()
        pendingManualFrame = nil
        pendingOffsetCorrectionIndex = nil
        seamReviewResumePhase = nil
        lastAcceptedFrameSequence = 0
        captureHasStarted = false
        startTermination = nil
        isFinalizing = false
        releaseResource()
        if let sessionLeaseToken {
            _ = inputModeCoordinator.release(sessionLeaseToken, reason: reason)
            self.sessionLeaseToken = nil
        }
        _ = stateMachine.handle(.reset)
        if hadActiveSession {
            onTerminal?(reason)
        }
    }

    private func releaseResource() {
        guard resourceClaimed else { return }
        resourceClaimed = false
        resourceCoordinator.release(.scroll)
    }

    private func validateStarting(generation: Int) throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation, startTermination == nil, !shutdownRequested else {
            throw startTermination?.error ?? CaptureError(code: "scroll_capture_cancelled", message: "滚动截图已取消")
        }
    }

    private func report(_ message: String) {
        logger.info("scroll.message \(message, privacy: .public)")
        onStatusMessage?(message)
    }

    private func logSegmentLatency(
        mode: String,
        startedAt: Date,
        analysisStartedAt: Date,
        appendStartedAt: Date,
        confidence: Double
    ) {
        let readyMS = max(0, analysisStartedAt.timeIntervalSince(startedAt) * 1_000)
        let analysisMS = max(0, appendStartedAt.timeIntervalSince(analysisStartedAt) * 1_000)
        let totalMS = Self.elapsedMilliseconds(since: startedAt)
        logger.info(
            "scroll.segment mode=\(mode, privacy: .public) ready_ms=\(readyMS, privacy: .public) analysis_ms=\(analysisMS, privacy: .public) total_ms=\(totalMS, privacy: .public) confidence=\(confidence, privacy: .public) pieces=\(self.pieces.count, privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(since date: Date) -> Double {
        max(0, Date().timeIntervalSince(date) * 1_000)
    }

    private static func captureError(
        _ error: Error,
        code: String,
        message: String
    ) -> CaptureError {
        if let captureError = error as? CaptureError {
            return captureError
        }
        return CaptureError(code: code, message: message, detail: error.localizedDescription)
    }
}

@MainActor
private final class ScrollCaptureHUDController {
    private enum ButtonRole {
        case manual
        case capture
        case correct
        case end
        case primary
        case cancel

        var tintColor: NSColor {
            switch self {
            case .manual:
                return .systemPurple
            case .capture:
                return .systemTeal
            case .correct:
                return .systemOrange
            case .end:
                return .systemGreen
            case .primary:
                return .systemBlue
            case .cancel:
                return .systemRed
            }
        }
    }

    private var panel: NSPanel?
    private var guidePanels: [NSPanel] = []
    private var summaryLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var automaticScrollButton: NSButton?
    private var mouseScrollButton: NSButton?
    private var captureButton: NSButton?
    private var correctButton: NSButton?
    private var endButton: NSButton?
    private var finishButton: NSButton?
    private var cancelButton: NSButton?
    private var captureControlsRow: NSStackView?
    private var reviewStatusLabel: NSTextField?
    private var seamContainer: NSStackView?
    private var seamPreviewView: ScrollSeamPreviewView?
    private var seamTitleLabel: NSTextField?
    private var seamValueLabel: NSTextField?
    private var seamSlider: NSSlider?
    private var seamSkipButton: NSButton?
    private var isEnding = false
    private var manualCaptureInFlight = false
    private var baselineCaptureInFlight = false
    private var captureHasStarted = false
    private var automaticScrollRunning = false
    private var currentPieceCount = 0
    private var currentEstimatedHeight = 0
    private var currentMode: ScrollCaptureMode = .manual
    private var endSuggestionRequested = false
    private var seamApplyAction: ((Int) -> Void)?
    private var seamSkipAction: (() -> Void)?
    private var toggleAutomaticScrollAction: (() -> Void)?
    private var useMouseScrollAction: (() -> Void)?
    private var captureNextAction: (() -> Void)?
    private var correctLastOffsetAction: (() -> Void)?
    private var endConfirmedAction: (() -> Void)?
    private var finishAction: (() -> Void)?
    private var cancelAction: (() -> Void)?

    func show(
        region: CaptureRegion,
        onToggleAutomaticScroll: @escaping () -> Void,
        onUseMouseScroll: @escaping () -> Void,
        onCaptureNext: @escaping () -> Void,
        onCorrectLastOffset: @escaping () -> Void,
        onEndConfirmed: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        captureHasStarted = false
        automaticScrollRunning = false
        currentPieceCount = 0
        endSuggestionRequested = false
        baselineCaptureInFlight = false
        manualCaptureInFlight = false
        isEnding = false
        toggleAutomaticScrollAction = onToggleAutomaticScroll
        useMouseScrollAction = onUseMouseScroll
        captureNextAction = onCaptureNext
        correctLastOffsetAction = onCorrectLastOffset
        endConfirmedAction = onEndConfirmed
        finishAction = onFinish
        cancelAction = onCancel
        let panel = self.panel ?? makePanel()
        self.panel = panel
        captureControlsRow?.isHidden = false
        reviewStatusLabel?.isHidden = true
        cancelButton?.isEnabled = true
        endButton?.isEnabled = true

        let preferredSize = panel.frame.size
        let selection = region.selectionRectInAppKitGlobalPoints
        let guideFrames = ScrollCaptureGuideGeometry.panelFrames(around: selection)
        while guidePanels.count < guideFrames.count {
            guidePanels.append(makeGuidePanel())
        }
        for (guide, frame) in zip(guidePanels, guideFrames) {
            guide.setFrame(frame, display: true)
            guide.orderFrontRegardless()
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let candidateY = selection.maxY + 12
        let y = candidateY + preferredSize.height <= visible.maxY
            ? candidateY
            : max(visible.minY + 12, selection.minY - preferredSize.height - 12)
        let x = min(
            max(selection.midX - preferredSize.width / 2, visible.minX + 12),
            visible.maxX - preferredSize.width - 12
        )
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: preferredSize), display: true)
        panel.orderFrontRegardless()
    }

    func update(
        mode: ScrollCaptureMode,
        pieceCount: Int,
        estimatedHeight: Int,
        message: String,
        canCorrectLastOffset: Bool,
        captureHasStarted: Bool
    ) {
        self.captureHasStarted = captureHasStarted
        currentPieceCount = pieceCount
        currentEstimatedHeight = estimatedHeight
        currentMode = mode
        updateDrivePresentation()
        detailLabel?.stringValue = message
        let seamReviewVisible = !(seamContainer?.isHidden ?? true)
        captureButton?.isEnabled = mode == .manual && !seamReviewVisible
        captureButton?.isHidden = mode != .manual
        captureButton?.alphaValue = mode == .manual ? 1 : 0.45
        captureButton?.title = captureHasStarted ? "采集此段" : "设为起点"
        automaticScrollButton?.isHidden = mode == .manual
        automaticScrollButton?.title = captureHasStarted
            ? (automaticScrollRunning ? "停止自动滚动" : "自动滚动（可选）")
            : "自动滚动（可选）"
        automaticScrollButton?.isEnabled = mode != .manual && captureHasStarted && !seamReviewVisible && !baselineCaptureInFlight
        mouseScrollButton?.isHidden = mode == .manual
        mouseScrollButton?.isEnabled = mode != .manual && !seamReviewVisible && !baselineCaptureInFlight
        correctButton?.isEnabled = canCorrectLastOffset && !seamReviewVisible
        correctButton?.isHidden = mode != .manual
        finishButton?.isEnabled = captureHasStarted && pieceCount > 1 && !seamReviewVisible
        endButton?.isHidden = !endSuggestionRequested || pieceCount <= 1
        if manualCaptureInFlight {
            captureButton?.isEnabled = false
        }
    }

    func setManualCaptureInFlight(_ inFlight: Bool) {
        manualCaptureInFlight = inFlight
        captureButton?.title = inFlight
            ? (captureHasStarted ? "正在分析…" : "正在确认起点…")
            : (captureHasStarted ? "采集此段" : "设为起点")
        captureButton?.isEnabled = !inFlight && (seamContainer?.isHidden ?? true)
    }

    func setBaselineCaptureInFlight(_ inFlight: Bool) {
        baselineCaptureInFlight = inFlight
        automaticScrollButton?.isEnabled = !inFlight && captureHasStarted && (seamContainer?.isHidden ?? true)
        mouseScrollButton?.isEnabled = !inFlight && (seamContainer?.isHidden ?? true)
    }

    func setAutomaticScrollRunning(_ running: Bool) {
        automaticScrollRunning = running
        automaticScrollButton?.title = captureHasStarted
            ? (running ? "停止自动滚动" : "自动滚动（可选）")
            : "自动滚动（可选）"
        automaticScrollButton?.contentTintColor = running ? .systemOrange : .secondaryLabelColor
        automaticScrollButton?.setAccessibilityLabel(
            running ? "停止自动滚动，切回鼠标滚动" : "自动滚动，可选，点击后才会驱动页面"
        )
        updateDrivePresentation()
    }

    private func updateDrivePresentation() {
        mouseScrollButton?.state = automaticScrollRunning ? .off : .on
        mouseScrollButton?.setAccessibilityValue(automaticScrollRunning ? "未选择" : "默认，已选择")
        automaticScrollButton?.state = automaticScrollRunning ? .on : .off
        guard !isEnding else { return }
        let name = currentMode == .manual ? "逐段采集" : (automaticScrollRunning ? "自动滚动" : "鼠标滚动")
        summaryLabel?.stringValue = captureHasStarted
            ? "\(name) · \(currentPieceCount) 段 · \(currentEstimatedHeight) px"
            : "\(name) · 准备中"
    }

    func setEndSuggestionVisible(_ visible: Bool) {
        endSuggestionRequested = visible
        endButton?.isHidden = !visible || currentPieceCount <= 1
    }

    func showSeamReview(
        title: String,
        previousImage: CGImage?,
        currentImage: CGImage?,
        suggestedOffset: Int,
        maximumOffset: Int,
        skipTitle: String = "跳过此段",
        onApply: @escaping (Int) -> Void,
        onSkip: @escaping () -> Void
    ) {
        seamApplyAction = onApply
        seamSkipAction = onSkip
        seamSkipButton?.title = skipTitle
        seamTitleLabel?.stringValue = title
        seamSlider?.minValue = 1
        seamSlider?.maxValue = Double(max(1, maximumOffset))
        seamSlider?.integerValue = min(max(1, suggestedOffset), max(1, maximumOffset))
        seamValueLabel?.stringValue = "位移 \(seamSlider?.integerValue ?? suggestedOffset) px"
        if let previousImage, let currentImage {
            seamPreviewView?.configure(
                previousImage: previousImage,
                currentImage: currentImage,
                offset: suggestedOffset,
                maximumOffset: maximumOffset
            )
            seamPreviewView?.isHidden = false
        } else {
            seamPreviewView?.isHidden = true
        }
        seamContainer?.isHidden = false
        captureControlsRow?.isHidden = true
        reviewStatusLabel?.stringValue = "待确认"
        reviewStatusLabel?.isHidden = false
        resizePanelForSeamReview(showsImages: previousImage != nil && currentImage != nil)
        captureButton?.isEnabled = false
        automaticScrollButton?.isEnabled = false
        mouseScrollButton?.isEnabled = false
        correctButton?.isEnabled = false
        finishButton?.isEnabled = false
    }

    func hideSeamReview() {
        seamContainer?.isHidden = true
        captureControlsRow?.isHidden = isEnding
        reviewStatusLabel?.isHidden = true
        seamApplyAction = nil
        seamSkipAction = nil
        if let panel {
            let oldTop = panel.frame.maxY
            panel.setFrame(
                CGRect(x: panel.frame.minX, y: oldTop - 132, width: 600, height: 132),
                display: true,
                animate: false
            )
        }
    }

    func setFinalizing() {
        isEnding = true
        summaryLabel?.stringValue = "正在生成长图…"
        detailLabel?.stringValue = "完成后会出现在截图浮窗"
        captureButton?.isEnabled = false
        automaticScrollButton?.isEnabled = false
        mouseScrollButton?.isEnabled = false
        correctButton?.isEnabled = false
        endButton?.isEnabled = false
        finishButton?.isEnabled = false
        cancelButton?.isEnabled = false
        hideSeamReview()
    }

    func setCancelling() {
        isEnding = true
        summaryLabel?.stringValue = "正在取消…"
        detailLabel?.stringValue = "正在清理本次截图"
        [captureButton, automaticScrollButton, mouseScrollButton, correctButton, endButton, finishButton, cancelButton]
            .compactMap { $0 }
            .forEach { $0.isEnabled = false }
        hideSeamReview()
    }

    func hide() {
        panel?.orderOut(nil)
        guidePanels.forEach { $0.orderOut(nil) }
        toggleAutomaticScrollAction = nil
        useMouseScrollAction = nil
        captureNextAction = nil
        correctLastOffsetAction = nil
        endConfirmedAction = nil
        finishAction = nil
        cancelAction = nil
        seamApplyAction = nil
        seamSkipAction = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Keep the HUD above the click-through selection mask. Its backing is
        // intentionally opaque enough that button contrast never depends on
        // the application content behind the mask.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        effect.layer?.borderWidth = 1

        let summary = NSTextField(labelWithString: "滚动截图")
        summary.font = .systemFont(ofSize: 12, weight: .semibold)
        summary.textColor = .labelColor
        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .left
        let automaticScrollButton = button(
            title: "自动滚动（可选）",
            action: #selector(toggleAutomaticScrollPressed),
            role: .manual
        )
        automaticScrollButton.contentTintColor = .secondaryLabelColor
        automaticScrollButton.toolTip = "可选：程序驱动页面向下滚动；动鼠标滚轮可立即切回鼠标采集"
        let mouseScrollButton = button(title: "鼠标滚动", action: #selector(useMouseScrollPressed), role: .capture)
        mouseScrollButton.setButtonType(.toggle)
        mouseScrollButton.state = .on
        mouseScrollButton.toolTip = "默认方式：直接在选区内滚动鼠标或触控板，停下后自动拼接，无需逐段点击"
        mouseScrollButton.setAccessibilityLabel("鼠标滚动，默认采集方式")
        let captureButton = button(title: "采集此段", action: #selector(captureNextPressed), role: .capture)
        let correctButton = button(title: "校正上一段", action: #selector(correctLastOffsetPressed), role: .correct)
        let endButton = button(title: "确认到底部", action: #selector(endConfirmedPressed), role: .end)
        let finishButton = button(
            title: "完成",
            action: #selector(finishPressed),
            role: .primary
        )
        let cancelButton = button(title: "取消并丢弃", action: #selector(cancelPressed), role: .cancel)
        endButton.isHidden = true

        let reviewStatus = NSTextField(labelWithString: "待确认")
        reviewStatus.font = .systemFont(ofSize: 11, weight: .semibold)
        reviewStatus.textColor = .systemOrange
        reviewStatus.isHidden = true
        reviewStatus.setAccessibilityLabel("接缝需要确认，采集已暂停")
        let firstRow = NSStackView(views: [summary, reviewStatus, NSView(), cancelButton])
        firstRow.orientation = .horizontal
        firstRow.alignment = .centerY
        firstRow.spacing = 8
        firstRow.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let secondRow = NSStackView(
            views: [mouseScrollButton, automaticScrollButton, captureButton, correctButton, NSView(), endButton, finishButton]
        )
        secondRow.orientation = .horizontal
        secondRow.alignment = .centerY
        secondRow.spacing = 7
        secondRow.arrangedSubviews[4].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let seamTitle = NSTextField(labelWithString: "确认接缝")
        seamTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        let seamValue = NSTextField(labelWithString: "位移 0 px")
        seamValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        seamValue.alignment = .right
        let seamSlider = NSSlider(value: 1, minValue: 1, maxValue: 100, target: self, action: #selector(seamSliderChanged))
        seamSlider.isContinuous = true
        let seamPreview = ScrollSeamPreviewView()
        seamPreview.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let applyButton = button(title: "确认接缝", action: #selector(applySeamPressed), role: .primary)
        applyButton.toolTip = "确认当前拼接位置并返回采集界面"
        let skipButton = button(title: "跳过此段", action: #selector(skipSeamPressed), role: .cancel)
        let seamControlRow = NSStackView(views: [seamSlider, seamValue, applyButton, skipButton])
        seamControlRow.orientation = .horizontal
        seamControlRow.alignment = .centerY
        seamControlRow.spacing = 8
        let seamContainer = NSStackView(views: [seamTitle, seamPreview, seamControlRow])
        seamContainer.orientation = .vertical
        seamContainer.alignment = .leading
        seamContainer.spacing = 6
        seamContainer.isHidden = true

        let root = NSStackView(views: [firstRow, detail, secondRow, seamContainer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 7
        effect.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10)
        ])
        firstRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        secondRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        seamContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        seamPreview.widthAnchor.constraint(equalTo: seamContainer.widthAnchor).isActive = true
        seamControlRow.widthAnchor.constraint(equalTo: seamContainer.widthAnchor).isActive = true
        seamSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        panel.contentView = effect
        summaryLabel = summary
        detailLabel = detail
        self.automaticScrollButton = automaticScrollButton
        self.mouseScrollButton = mouseScrollButton
        self.captureButton = captureButton
        self.correctButton = correctButton
        self.endButton = endButton
        self.finishButton = finishButton
        self.cancelButton = cancelButton
        captureControlsRow = secondRow
        reviewStatusLabel = reviewStatus
        self.seamContainer = seamContainer
        seamPreviewView = seamPreview
        seamTitleLabel = seamTitle
        seamValueLabel = seamValue
        self.seamSlider = seamSlider
        seamSkipButton = skipButton
        return panel
    }

    private func resizePanelForSeamReview(showsImages: Bool) {
        guard let panel else { return }
        let oldTop = panel.frame.maxY
        let height: CGFloat = showsImages ? 246 : 132
        panel.setFrame(
            CGRect(
                x: panel.frame.minX,
                y: oldTop - height,
                width: 600,
                height: height
            ),
            display: true,
            animate: false
        )
    }

    private func makeGuidePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.95)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSView()
        // Decorative strips must not masquerade as four empty dialogs to
        // VoiceOver or UI automation. The real HUD remains the sole control
        // surface for the capture session.
        panel.setAccessibilityElement(false)
        panel.contentView?.setAccessibilityElement(false)
        return panel
    }

    @objc private func seamSliderChanged() {
        let offset = seamSlider?.integerValue ?? 0
        seamValueLabel?.stringValue = "位移 \(offset) px"
        seamPreviewView?.setOffset(offset)
    }

    @objc private func applySeamPressed() {
        seamApplyAction?(seamSlider?.integerValue ?? 1)
    }

    @objc private func skipSeamPressed() {
        seamSkipAction?()
    }

    private func button(
        title: String,
        action: Selector,
        role: ButtonRole
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        // Keep this in lock-step with the screenshot selection buttons: the
        // role colour is carried by AppKit's normal rounded-button tint rather
        // than a second custom rendering system.
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = role.tintColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isBordered = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func toggleAutomaticScrollPressed() {
        toggleAutomaticScrollAction?()
    }

    @objc private func useMouseScrollPressed() {
        mouseScrollButton?.state = .on
        useMouseScrollAction?()
    }

    @objc private func captureNextPressed() {
        captureNextAction?()
    }

    @objc private func correctLastOffsetPressed() {
        correctLastOffsetAction?()
    }

    @objc private func endConfirmedPressed() {
        endConfirmedAction?()
    }

    @objc private func finishPressed() {
        finishAction?()
    }

    @objc private func cancelPressed() {
        cancelAction?()
    }

}

private final class ScrollSeamPreviewView: NSView {
    private var previousImage: NSImage?
    private var currentImage: NSImage?
    private var offset = 1
    private var maximumOffset = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityLabel("滚动截图接缝预览")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        previousImage: CGImage,
        currentImage: CGImage,
        offset: Int,
        maximumOffset: Int
    ) {
        self.previousImage = NSImage(
            cgImage: previousImage,
            size: CGSize(width: previousImage.width, height: previousImage.height)
        )
        self.currentImage = NSImage(
            cgImage: currentImage,
            size: CGSize(width: currentImage.width, height: currentImage.height)
        )
        self.maximumOffset = max(1, maximumOffset)
        self.offset = min(max(1, offset), self.maximumOffset)
        needsDisplay = true
    }

    func setOffset(_ offset: Int) {
        self.offset = min(max(1, offset), maximumOffset)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let previousImage, let currentImage else { return }

        let labelHeight: CGFloat = 17
        let gap: CGFloat = 8
        let content = bounds.insetBy(dx: 6, dy: 5)
        let imageTop = content.minY + labelHeight
        let imageHeight = max(1, content.maxY - imageTop)
        let imageWidth = max(1, (content.width - gap) / 2)
        let previousRect = CGRect(
            x: content.minX,
            y: imageTop,
            width: imageWidth,
            height: imageHeight
        )
        let currentRect = CGRect(
            x: previousRect.maxX + gap,
            y: imageTop,
            width: imageWidth,
            height: imageHeight
        )

        previousImage.draw(
            in: previousRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.low]
        )
        currentImage.draw(
            in: currentRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.low]
        )

        let ratio = min(1, max(0, CGFloat(offset) / CGFloat(maximumOffset)))
        let seamY = previousRect.minY + ratio * previousRect.height
        NSColor.systemTeal.withAlphaComponent(0.18).setFill()
        CGRect(
            x: previousRect.minX,
            y: seamY,
            width: previousRect.width,
            height: max(0, previousRect.maxY - seamY)
        ).fill()

        let seamPath = NSBezierPath()
        seamPath.move(to: CGPoint(x: previousRect.minX, y: seamY))
        seamPath.line(to: CGPoint(x: previousRect.maxX, y: seamY))
        seamPath.move(to: CGPoint(x: currentRect.minX, y: currentRect.minY + 1))
        seamPath.line(to: CGPoint(x: currentRect.maxX, y: currentRect.minY + 1))
        seamPath.lineWidth = 2
        NSColor.systemTeal.setStroke()
        seamPath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSString(string: "上一段：横线以下为重叠区").draw(
            at: CGPoint(x: previousRect.minX, y: content.minY),
            withAttributes: attributes
        )
        NSString(string: "当前段：顶部接续横线").draw(
            at: CGPoint(x: currentRect.minX, y: content.minY),
            withAttributes: attributes
        )
    }
}

enum ScrollCaptureGuideGeometry {
    static let outerPadding: CGFloat = 6
    static let pathInset: CGFloat = 2
    static let strokeWidth: CGFloat = 3

    /// Positive clearance means the antialiased inner stroke edge remains
    /// outside the selected capture rect on all four sides.
    static var captureClearance: CGFloat {
        outerPadding - pathInset - strokeWidth / 2
    }

    /// Four real windows form the guide. Every window stays wholly outside the
    /// selected source rectangle instead of using one transparent window that
    /// covers it. ScreenCaptureKit can then observe damage from the scrolling
    /// application underneath without the excluded guide suppressing frames.
    static func panelFrames(around selection: CGRect) -> [CGRect] {
        let clearance = captureClearance
        let thickness = strokeWidth
        let outerExtension = clearance + thickness
        return [
            CGRect(
                x: selection.minX - outerExtension,
                y: selection.maxY + clearance,
                width: selection.width + outerExtension * 2,
                height: thickness
            ),
            CGRect(
                x: selection.minX - outerExtension,
                y: selection.minY - clearance - thickness,
                width: selection.width + outerExtension * 2,
                height: thickness
            ),
            CGRect(
                x: selection.minX - clearance - thickness,
                y: selection.minY - clearance,
                width: thickness,
                height: selection.height + clearance * 2
            ),
            CGRect(
                x: selection.maxX + clearance,
                y: selection.minY - clearance,
                width: thickness,
                height: selection.height + clearance * 2
            )
        ]
    }
}

enum ScrollAutomaticScrollProfile {
    struct Chunk: Equatable {
        let pixelDeltas: [Int32]
        var logicalDistance: Double { pixelDeltas.reduce(0) { $0 + Double(abs($1)) } }
    }

    static let maximumPixelStep: Int32 = 12
    static let maximumChunkLogicalDistance: CGFloat = 240
    static let maximumViewportFraction: CGFloat = 0.35
    static let stepIntervalNanoseconds: UInt64 = 32_000_000

    /// Pixel events have a distance contract; line events and AXIncrement do
    /// not. A browser may turn one AX increment into a complete page jump, so
    /// automatic capture always uses this bounded pixel driver.
    static func chunk(viewportLogicalHeight: CGFloat) -> Chunk {
        guard viewportLogicalHeight.isFinite, viewportLogicalHeight > 0 else { return Chunk(pixelDeltas: []) }
        let distance = Int(min(maximumChunkLogicalDistance, floor(viewportLogicalHeight * maximumViewportFraction)))
        guard distance > 0 else { return Chunk(pixelDeltas: []) }
        var remaining = distance
        var deltas: [Int32] = []
        while remaining > 0 {
            let step = min(Int(maximumPixelStep), remaining)
            deltas.append(-Int32(step))
            remaining -= step
        }
        return Chunk(pixelDeltas: deltas)
    }

    static func event(pixelDelta: Int32, location: CGPoint) -> CGEvent? {
        guard pixelDelta < 0, pixelDelta >= -maximumPixelStep else { return nil }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 1, wheel1: pixelDelta, wheel2: 0, wheel3: 0) else { return nil }
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: ScrollCaptureWheelInputPolicy.injectedEventTag)
        return event
    }

    static func eventLocation(displayBounds: CGRect, sourceRect: CGRect) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + sourceRect.midX,
            y: displayBounds.minY + sourceRect.midY
        )
    }
}
