import AppKit
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import Foundation
import OSLog
import ScreenCaptureKit

@MainActor
final class RecordingSessionController {
    var onArtifactReady: ((ArtifactManifest) -> Void)?
    var onArtifactState: ((ArtifactManifest) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    private let artifactStore: ArtifactStore
    private let resourceCoordinator: CaptureResourceCoordinator
    private let inputModeCoordinator: InputModeCoordinator
    private let acceptanceContext: AcceptanceContext?
    private let capabilityProbeCoordinator: CapabilityProbeAcceptanceCoordinator?
    private let monitorCompleteFrameCount: () -> UInt64
    private let monitorHealthy: () -> Bool
    private let activeResourceCount: () -> Int
    private let monitorActive: () -> Bool
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "RecordingSession")
    private let hud = RecordingHUDController()
    private let nativeOperations: CaptureSessionNativeOperations
    private let shareableContentProvider: @MainActor () async throws -> SCShareableContent

    private var stream: SCStream?
    private var localFrames: LocalPreviewFramePump<CMSampleBuffer>?
    private var streamDelegate: RecordingStreamDelegate?
    private var sampleReceiver: RecordingSampleReceiver?
    private var writer: RecordingWriter?
    private var artifactSession: ArtifactSession?
    private var displayID: CGDirectDisplayID?
    private var startedAt: Date?
    private var timer: Timer?
    private var heartbeatTask: Task<Void, Never>?
    private var firstFrameDeadlineTask: Task<Void, Never>?
    private var ensureCapturingPersistedTask: Task<ArtifactManifest, Error>?
    private var displayObserver: NSObjectProtocol?
    private var operationID: UUID?
    private var deadlineID: UUID?
    private var leaseToken: InputLeaseToken?
    private var terminalError: CaptureError?
    private var phase: Phase = .idle
    private var isFinishing = false
    private var resourceClaimed = false
    private var monitorFrameCountAtStart: UInt64 = 0
    private var startInFlight = false
    private var shutdownRequested = false

    private enum Phase {
        case idle
        case preflighting
        case preparing
        case awaitingFirstFrame
        case recording
        case stopping
        case finalizing
    }

    init(
        artifactStore: ArtifactStore,
        resourceCoordinator: CaptureResourceCoordinator,
        inputModeCoordinator: InputModeCoordinator,
        acceptanceContext: AcceptanceContext? = nil,
        capabilityProbeCoordinator: CapabilityProbeAcceptanceCoordinator? = nil,
        monitorCompleteFrameCount: @escaping () -> UInt64 = { 0 },
        monitorHealthy: @escaping () -> Bool = { false },
        activeResourceCount: @escaping () -> Int = { 0 },
        nativeOperations: CaptureSessionNativeOperations? = nil,
        shareableContentProvider: @escaping @MainActor () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        },
        monitorActive: @escaping () -> Bool
    ) {
        self.artifactStore = artifactStore
        self.resourceCoordinator = resourceCoordinator
        self.inputModeCoordinator = inputModeCoordinator
        self.acceptanceContext = acceptanceContext
        self.capabilityProbeCoordinator = capabilityProbeCoordinator
        self.monitorCompleteFrameCount = monitorCompleteFrameCount
        self.monitorHealthy = monitorHealthy
        self.activeResourceCount = activeResourceCount
        self.nativeOperations = nativeOperations ?? CaptureSessionNativeOperations(prefix: "recording")
        self.shareableContentProvider = shareableContentProvider
        self.monitorActive = monitorActive
    }

    var isRecording: Bool {
        phase == .recording
    }

    /// Includes the short finalizing interval so dependent offline work (GIF)
    /// does not compete with a writer that is still closing its MP4.
    var isBusy: Bool {
        phase != .idle || startInFlight
    }

    func start(
        selection: ScreenshotWorkspaceController.SelectedRegion,
        showsCursor: Bool,
        operationID: UUID,
        leaseToken: InputLeaseToken
    ) async throws {
        guard !shutdownRequested else {
            throw CaptureError(code: "recording_cancelled", message: "应用正在退出，无法启动录屏")
        }
        try Task.checkCancellation()
        guard phase == .idle, !startInFlight else {
            throw CaptureError(code: "recording_already_running", message: "当前已有区域录屏")
        }
        try nativeOperations.beginSession()
        let pixelSize = Self.evenPixelSize(selection.region.pixelRectInCaptureSpace)
        self.operationID = operationID
        monitorFrameCountAtStart = monitorCompleteFrameCount()
        self.leaseToken = leaseToken
        displayID = selection.displayID
        phase = .preflighting
        startInFlight = true
        defer { startInFlight = false }
        hud.showPreparing(region: selection.region) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.stop()
            }
        }

        do {
            let decision = await resourceCoordinator.acquire(
                .recording,
                monitorActive: monitorActive()
            )
            guard case .granted = decision else {
                let reason: String
                switch decision {
                case .queued(let message), .rejected(let message): reason = message
                case .granted: reason = "资源不可用"
                }
                throw CaptureError(
                    code: "recording_resource_unavailable",
                    message: "区域录屏暂不可启动",
                    detail: reason
                )
            }
            resourceClaimed = true
            try validateActive(operationID)

            try await artifactStore.preflightWriteAvailability(
                minimumFreeBytes: ArtifactStorageLimits.scrollDefault.minimumFreeDiskBytes
            )
            try validateActive(operationID)

            let content = try await nativeOperations.startupValue(stage: "shareable") { [shareableContentProvider] in
                try await shareableContentProvider()
            }
            try validateActive(operationID)
            guard let display = content.displays.first(where: {
                $0.displayID == selection.displayID
            }) else {
                throw CaptureError(
                    code: "recording_display_not_shareable",
                    message: "录屏区域所在显示器不可采集"
                )
            }

            let session = try await artifactStore.beginPreparedArtifact(
                fileExtension: "mp4",
                dimensions: pixelSize,
                displayID: UInt32(selection.displayID),
                captureRegion: selection.region,
                operationID: operationID
            )
            artifactSession = session
            // Own the returned lock before observing cancellation, so the
            // failure path can always terminate the prepared artifact.
            try validateActive(operationID)
            phase = .preparing
            onArtifactState?(session.manifest)

            let deadlineID = UUID()
            self.deadlineID = deadlineID
            let writer = try RecordingWriter(
                outputURL: session.manifest.temporaryURL,
                pixelSize: pixelSize,
                deadlineID: deadlineID,
                injectedFault: acceptanceContext?.writerFault,
                acceptanceReporter: acceptanceContext?.reporter,
                onFirstFrameCommitted: { [weak self] presentationTime in
                    Task { @MainActor [weak self] in
                        await self?.handleFirstFrameCommitted(
                            presentationTime: presentationTime,
                            operationID: operationID,
                            artifactID: session.manifest.id,
                            deadlineID: deadlineID
                        )
                    }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard self?.operationID == operationID else { return }
                        await self?.claimAndFinish(error: error)
                    }
                }
            )
            let filter = Self.makeFilter(content: content, display: display)
            let configuration = SCStreamConfiguration()
            configuration.width = pixelSize.width
            configuration.height = pixelSize.height
            configuration.sourceRect = selection.region.sourceRectInPlatformLogicalPoints
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 4
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = showsCursor
            configuration.capturesAudio = false

            if #available(macOS 26.0, *) {
                self.writer = writer
                phase = .awaitingFirstFrame
                installFirstFrameDeadline(
                    operationID: operationID,
                    artifactID: session.manifest.id,
                    deadlineID: deadlineID
                )
                let source = try LocalPreviewScreenshotSource(filter: filter, configuration: configuration)
                let frames = LocalPreviewFramePump<CMSampleBuffer>(
                    frameRate: 30,
                    capture: { [nativeOperations] in
                        try await nativeOperations.startupValue(stage: "frame") {
                            try await source.capture()
                        }
                    },
                    present: { buffer in await writer.appendAndWait(buffer) },
                    failed: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == operationID else { return }
                            await self.claimAndFinish(error: (error as? CaptureError) ?? CaptureError(
                                code: "recording_frame_failed", message: "录屏取帧失败", detail: error.localizedDescription
                            ))
                        }
                    }
                )
                localFrames = frames
                report("正在启动区域录屏…")
                logger.notice("recording.localFrames.start fps=30 sharingStream=false")
                try await frames.start()
                try validateActive(operationID)
                logger.notice("recording.localFrames.firstFrame sharingStream=false")
                beginHeartbeat(for: session)
                installDisplayObserver()
                return
            }

            let delegate = RecordingStreamDelegate { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.operationID == operationID else { return }
                    await self?.claimAndFinish(
                        error: CaptureError(
                            code: "recording_stream_stopped",
                            message: "屏幕录制流已停止",
                            detail: error.localizedDescription
                        )
                    )
                }
            }
            let receiver = RecordingSampleReceiver(writer: writer)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: writer.sampleHandlerQueue)

            self.writer = writer
            sampleReceiver = receiver
            streamDelegate = delegate
            self.stream = stream
            phase = .awaitingFirstFrame
            installFirstFrameDeadline(
                operationID: operationID,
                artifactID: session.manifest.id,
                deadlineID: deadlineID
            )
            try await nativeOperations.startupValue(
                stage: "start",
                operation: { try await stream.startCapture() },
                onLateResult: { [nativeOperations] _ in
                    // This captures only the old stream and receiver. The UI
                    // and writer may already have completed their own cleanup.
                    try? stream.removeStreamOutput(receiver, type: .screen)
                    try? await nativeOperations.stop(stream, afterLateStart: true)
                }
            )
            try validateActive(operationID)
            beginHeartbeat(for: session)
            installDisplayObserver()
            report("正在启动区域录屏…")
        } catch {
            guard self.operationID == operationID else {
                throw CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
            }
            let captureError: CaptureError
            if let storeError = error as? ArtifactStoreError,
               case .insufficientDiskSpace = storeError {
                captureError = CaptureError(
                    code: "recording_disk_full",
                    message: "磁盘空间不足，无法开始区域录屏",
                    detail: error.localizedDescription
                )
            } else if error is CancellationError {
                captureError = CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
            } else {
                captureError = (error as? CaptureError) ?? CaptureError(
                    code: "recording_start_failed",
                    message: "区域录屏启动失败",
                    detail: error.localizedDescription
                )
            }
            startInFlight = false
            if writer != nil {
                terminalError = terminalError ?? captureError
                await finishClaimed(discardZeroFrame: terminalError?.code == "recording_cancelled")
            } else {
                await finishStartFailure(captureError)
            }
            throw captureError
        }
    }

    func stop() async {
        if startInFlight {
            terminalError = terminalError ?? CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
            hud.setCancelling()
            nativeOperations.cancelStartupWait()
            return
        }
        switch phase {
        case .idle, .stopping, .finalizing:
            return
        case .preflighting, .preparing:
            guard terminalError == nil else { return }
            terminalError = CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
            hud.setCancelling()
        case .awaitingFirstFrame:
            guard let writer, let expectedOperationID = operationID else { return }
            let resolution = await writer.requestFirstFrameCancel()
            guard operationID == expectedOperationID, !isFinishing else { return }
            switch resolution {
            case .cancelWon:
                terminalError = CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
                await finishClaimed(discardZeroFrame: true)
            case .firstFrameAlreadyCommitted(let presentationTime):
                _ = getOrCreateEnsureCapturingPersisted(
                    firstPresentationTime: presentationTime
                )
                await claimAndFinish(error: nil)
            case .firstFrameCommitted, .timeoutWon, .alreadyResolved:
                return
            }
        case .recording:
            await claimAndFinish(error: nil)
        }
    }

    func stopForPermissionRevocation() async {
        await claimAndFinish(
            error: CaptureError(
                code: "screen_recording_permission_revoked",
                message: "屏幕录制权限已撤销"
            )
        )
    }

    func shutdown() async {
        shutdownRequested = true
        await claimAndFinish(
            error: CaptureError(
                code: "recording_application_exit",
                message: "应用退出，录屏已尝试恢复"
            )
        )
        // A stop button may already own finalization, or start() may still be
        // returning from its preflight await. Join it instead of reporting that
        // shutdown finished while the writer still owns its artifact lock.
        while isBusy, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return
            }
        }
    }

    func stopForSystemSleep() async {
        await claimAndFinish(
            error: CaptureError(
                code: "recording_system_sleep",
                message: "系统进入睡眠，录屏已停止并开始保存"
            )
        )
    }

    func handleSystemWake() async {
        guard phase == .idle else { return }
        _ = try? await artifactStore.recoverAll()
    }

    private func handleFirstFrameCommitted(
        presentationTime: CMTime,
        operationID: UUID,
        artifactID: UUID,
        deadlineID: UUID
    ) async {
        guard self.operationID == operationID,
              artifactSession?.manifest.id == artifactID,
              self.deadlineID == deadlineID else { return }
        let task = getOrCreateEnsureCapturingPersisted(
            firstPresentationTime: CMTimeGetSeconds(presentationTime)
        )
        do {
            let manifest = try await task.value
            guard self.operationID == operationID,
                  artifactSession?.manifest.id == artifactID,
                  self.deadlineID == deadlineID else { return }
            onArtifactState?(manifest)
            firstFrameDeadlineTask?.cancel()
            firstFrameDeadlineTask = nil
            if terminalError == nil, !isFinishing {
                phase = .recording
                startedAt = Date()
                beginRecordingTimer()
                hud.setRecording()
                report("区域录屏已开始")
            } else if !isFinishing, !startInFlight {
                await finishClaimed(discardZeroFrame: false)
            }
        } catch {
            guard self.operationID == operationID,
                  artifactSession?.manifest.id == artifactID,
                  self.deadlineID == deadlineID else { return }
            await claimAndFinish(
                error: CaptureError(
                    code: "recording_capturing_persist_failed",
                    message: "录屏状态持久化失败",
                    detail: error.localizedDescription
                )
            )
        }
    }

    private func getOrCreateEnsureCapturingPersisted(
        firstPresentationTime: Double
    ) -> Task<ArtifactManifest, Error> {
        if let ensureCapturingPersistedTask { return ensureCapturingPersistedTask }
        guard let session = artifactSession else {
            return Task {
                throw CaptureError(code: "recording_session_missing", message: "录屏会话不可用")
            }
        }
        let store = artifactStore
        let task = Task {
            _ = firstPresentationTime
            return try await store.markCapturing(for: session)
        }
        ensureCapturingPersistedTask = task
        return task
    }

    private func installFirstFrameDeadline(
        operationID: UUID,
        artifactID: UUID,
        deadlineID: UUID
    ) {
        firstFrameDeadlineTask?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        firstFrameDeadlineTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(10))
            } catch {
                return
            }
            guard let self else { return }
            await self.handleFirstFrameDeadline(
                operationID: operationID,
                artifactID: artifactID,
                deadlineID: deadlineID
            )
        }
    }

    private func handleFirstFrameDeadline(
        operationID: UUID,
        artifactID: UUID,
        deadlineID: UUID
    ) async {
        guard self.operationID == operationID,
              artifactSession?.manifest.id == artifactID,
              self.deadlineID == deadlineID,
              let writer else { return }
        let resolution = await writer.requestFirstFrameTimeout(deadlineID: deadlineID)
        guard self.operationID == operationID,
              artifactSession?.manifest.id == artifactID,
              self.deadlineID == deadlineID else { return }
        guard case .timeoutWon = resolution else { return }
        await claimAndFinish(
            error: CaptureError(
                code: "recording_first_frame_timeout",
                message: "区域录屏启动超时，请重试"
            )
        )
    }

    private func claimAndFinish(error: CaptureError?) async {
        guard phase != .idle, phase != .finalizing, !isFinishing else { return }
        if terminalError == nil {
            terminalError = error
        } else if error != nil {
            return
        }
        // Release the UI wait immediately. Native work keeps its own recovery
        // marker and late-result retirement independently of this session.
        if startInFlight {
            nativeOperations.cancelStartupWait()
            return
        }
        await finishClaimed(discardZeroFrame: false)
    }

    private func finishClaimed(discardZeroFrame: Bool) async {
        guard let session = artifactSession, !isFinishing, !startInFlight else { return }
        isFinishing = true
        phase = .stopping
        hud.setFinalizing()
        var persistenceFailure: CaptureError?
        if let firstPresentationTime = await writer?.committedFirstPresentationTime() {
            do {
                _ = try await getOrCreateEnsureCapturingPersisted(
                    firstPresentationTime: CMTimeGetSeconds(firstPresentationTime)
                ).value
            } catch {
                persistenceFailure = CaptureError(
                    code: "recording_capturing_persist_failed",
                    message: "录屏状态持久化失败",
                    detail: error.localizedDescription
                )
            }
        }
        if !discardZeroFrame {
            _ = try? await artifactStore.markFinalizing(for: session)
        }
        timer?.invalidate()
        timer = nil
        firstFrameDeadlineTask?.cancel()
        firstFrameDeadlineTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        removeDisplayObserver()
        await stopStream()

        let metrics = await writer?.finish() ?? RecordingWriterMetrics(
            frameCount: 0,
            droppedFrameCount: 0,
            invalidTimestampCount: 0,
            firstPresentationTime: nil,
            lastPresentationTime: nil,
            failure: CaptureError(code: "recording_writer_missing", message: "录屏写入器不可用")
        )
        phase = .finalizing
        let duration: Double? = {
            guard let first = metrics.firstPresentationTime,
                  let last = metrics.lastPresentationTime else { return nil }
            return max(0, CMTimeGetSeconds(CMTimeSubtract(last, first)))
        }()
        var terminalArtifact: ArtifactManifest?
        do {
            _ = try await artifactStore.updateRecordingMetrics(
                for: session,
                durationSeconds: duration,
                frameCount: metrics.frameCount,
                droppedFrameCount: metrics.droppedFrameCount
            )

            let finalFailure = terminalError ?? metrics.failure ?? persistenceFailure
            let artifact: ArtifactManifest
            if metrics.frameCount == 0, discardZeroFrame {
                artifact = try await artifactStore.discard(for: session)
            } else if metrics.frameCount == 0 {
                artifact = try await artifactStore.markFailed(
                    for: session,
                    error: finalFailure ?? CaptureError(
                        code: "recording_no_valid_frames",
                        message: "录屏没有收到有效视频帧"
                    )
                )
            } else if let finalFailure {
                do {
                    artifact = try await artifactStore.finalizeTemporary(
                        for: session,
                        terminalStatus: .partial,
                        terminalError: finalFailure
                    )
                } catch {
                    artifact = try await artifactStore.markPartial(for: session, error: finalFailure)
                }
            } else {
                do {
                    artifact = try await artifactStore.finalizeTemporary(for: session)
                } catch {
                    artifact = try await artifactStore.markPartial(
                        for: session,
                        error: CaptureError(
                            code: "recording_finalize_failed",
                            message: "录屏文件未能完成提交，已保留诊断文件",
                            detail: error.localizedDescription
                        )
                    )
                }
            }
            if artifact.status != .discarded {
                terminalArtifact = artifact
                onArtifactReady?(artifact)
                report(artifact.status == .completed ? "录屏已完成" : "录屏保留为\(artifact.status.label)")
            } else {
                report("区域录屏已取消")
            }
        } catch {
            report("录屏收尾失败：\(error.localizedDescription)")
        }
        let releaseReason = releaseReason(for: terminalError)
        let monitorFrameDelta = monitorCompleteFrameCount() &- monitorFrameCountAtStart
        clearSessionState(releaseReason: releaseReason)
        if let terminalArtifact, let capabilityProbeCoordinator {
            await capabilityProbeCoordinator.recordRound(
                artifact: terminalArtifact,
                monitorCompleteFrameDelta: monitorFrameDelta,
                monitorHealthy: monitorHealthy(),
                activeResourceCount: activeResourceCount()
            )
        }
    }

    private func finishStartFailure(_ error: CaptureError) async {
        isFinishing = true
        await stopStream()
        if let session = artifactSession {
            if terminalError?.code == "recording_cancelled" {
                _ = try? await artifactStore.discard(for: session)
            } else {
                _ = try? await artifactStore.markFailed(for: session, error: error)
            }
        }
        clearSessionState(releaseReason: releaseReason(for: terminalError ?? error))
    }

    private func stopStream() async {
        if let frames = localFrames {
            localFrames = nil
            frames.stop()
            // Cancelling the pump cannot cancel an in-progress system screenshot.
            // Its registry marker prevents a new recording from overlapping it.
            let deadline = ContinuousClock.now + .seconds(3)
            while nativeOperations.pendingCount > 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            logger.notice("recording.localFrames.stop frames=\(frames.frameCount, privacy: .public) pending=\(self.nativeOperations.pendingCount, privacy: .public)")
        }
        guard let stream else { return }
        let receiver = sampleReceiver
        self.stream = nil
        sampleReceiver = nil
        streamDelegate = nil
        // Remove the output before finishing the writer, even if native stop
        // never replies. Late starts are stopped again by their own hook.
        if let receiver { try? stream.removeStreamOutput(receiver, type: .screen) }
        let cleanup = Task { @MainActor [nativeOperations, logger] in
            do {
                try await nativeOperations.stop(stream)
                logger.notice("recording.stream.stop.completed")
            } catch {
                logger.error("recording.stream.stop.incomplete \(String(describing: error), privacy: .public)")
            }
        }
        await cleanup.value
    }

    private func beginRecordingTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.hud.update(duration: Date().timeIntervalSince(startedAt))
            }
        }
    }

    private func beginHeartbeat(for session: ArtifactSession) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, self.artifactSession?.manifest.id == session.manifest.id else {
                    return
                }
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
                guard let self, let displayID = self.displayID else { return }
                let isStillAvailable = NSScreen.screens.contains { screen in
                    let key = NSDeviceDescriptionKey("NSScreenNumber")
                    let value = screen.deviceDescription[key] as? NSNumber
                    return value.map { CGDirectDisplayID($0.uint32Value) == displayID } ?? false
                }
                guard isStillAvailable else {
                    await self.claimAndFinish(
                        error: CaptureError(
                            code: "recording_display_disconnected",
                            message: "录屏显示器已断开"
                        )
                    )
                    return
                }
                // Any parameter change can invalidate sourceRect/pixel scale.
                await self.claimAndFinish(
                    error: CaptureError(
                        code: "recording_display_configuration_changed",
                        message: "显示器配置已变化，录屏已安全停止"
                    )
                )
            }
        }
    }

    private func removeDisplayObserver() {
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
    }

    private func clearSessionState(releaseReason: InputLeaseReleaseReason) {
        hud.hide()
        timer?.invalidate()
        timer = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        firstFrameDeadlineTask?.cancel()
        firstFrameDeadlineTask = nil
        ensureCapturingPersistedTask?.cancel()
        ensureCapturingPersistedTask = nil
        removeDisplayObserver()
        artifactSession = nil
        writer = nil
        stream = nil
        sampleReceiver = nil
        streamDelegate = nil
        displayID = nil
        startedAt = nil
        monitorFrameCountAtStart = 0
        terminalError = nil
        deadlineID = nil
        operationID = nil
        isFinishing = false
        phase = .idle
        if resourceClaimed {
            resourceClaimed = false
            resourceCoordinator.release(.recording)
        }
        if let leaseToken {
            _ = inputModeCoordinator.release(leaseToken, reason: releaseReason)
            self.leaseToken = nil
        }
    }

    private func validateActive(_ expectedOperationID: UUID) throws {
        try Task.checkCancellation()
        guard operationID == expectedOperationID, terminalError == nil else {
            throw CaptureError(code: "recording_cancelled", message: "区域录屏已取消")
        }
    }

    private func releaseReason(for error: CaptureError?) -> InputLeaseReleaseReason {
        switch error?.code {
        case "recording_cancelled": .cancelled
        case "screen_recording_permission_revoked": .permissionRevoked
        case "recording_application_exit": .applicationTermination
        default: .completed
        }
    }

    private func report(_ message: String) {
        logger.info("recording.message \(message, privacy: .public)")
        onStatusMessage?(message)
    }

    private static func evenPixelSize(_ pixelRect: CapturePixelRect) -> PixelSize {
        PixelSize(
            width: max(2, (pixelRect.width / 2) * 2),
            height: max(2, (pixelRect.height / 2) * 2)
        )
    }

    private static func makeFilter(content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        CurrentProcessCaptureFilter.make(content: content, display: display)
    }
}

private final class RecordingStreamDelegate: NSObject, SCStreamDelegate {
    private let onStop: (Error) -> Void

    init(onStop: @escaping (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

private final class RecordingSampleReceiver: NSObject, SCStreamOutput {
    private let writer: RecordingWriter

    init(writer: RecordingWriter) {
        self.writer = writer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              frameStatus(for: sampleBuffer) == .complete else {
            return
        }
        writer.append(sampleBuffer)
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
private final class RecordingHUDController {
    private var panel: NSPanel?
    private var guidePanel: NSPanel?
    private var label: NSTextField?
    private var actionButton: NSButton?
    private var stopAction: (() -> Void)?
    private var region: CaptureRegion?

    func showPreparing(region: CaptureRegion, onCancel: @escaping () -> Void) {
        self.region = region
        stopAction = onCancel
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = "● 正在准备区域录屏…"
        label?.textColor = .secondaryLabelColor
        actionButton?.title = "取消"
        actionButton?.isHidden = false
        position(panel: panel, region: region)
    }

    func setRecording() {
        update(duration: 0)
        actionButton?.title = "停止"
        actionButton?.isHidden = false
        if let region {
            showGuide(region: region)
        }
    }

    func setCancelling() {
        label?.stringValue = "● 正在取消…"
        label?.textColor = .secondaryLabelColor
        actionButton?.isHidden = true
    }

    private func position(panel: NSPanel, region: CaptureRegion) {
        let preferredSize = panel.frame.size
        let selection = region.selectionRectInAppKitGlobalPoints
        let screen = NSScreen.screens.first { $0.frame.intersects(selection) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let candidateY = selection.maxY + 12
        let y = candidateY + preferredSize.height <= visible.maxY
            ? candidateY
            : max(visible.minY + 12, selection.minY - preferredSize.height - 12)
        let x = min(max(selection.midX - preferredSize.width / 2, visible.minX + 12), visible.maxX - preferredSize.width - 12)
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: preferredSize), display: true)
        panel.orderFrontRegardless()
    }

    func update(duration: TimeInterval) {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        label?.stringValue = String(format: "● 录制中 %02d:%02d", minutes, seconds)
        label?.textColor = .systemRed
    }

    func setFinalizing() {
        label?.stringValue = "● 正在保存 MP4…"
        label?.textColor = .secondaryLabelColor
        actionButton?.isHidden = true
    }

    func hide() {
        panel?.orderOut(nil)
        guidePanel?.orderOut(nil)
        stopAction = nil
        region = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 190, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
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

        let label = NSTextField(labelWithString: "● 录制中 00:00")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .systemRed
        let button = NSButton(title: "停止", target: self, action: #selector(stopPressed))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [label, NSView(), button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4)
        ])
        panel.contentView = effect
        self.label = label
        actionButton = button
        return panel
    }

    @objc private func stopPressed() {
        stopAction?()
    }

    private func showGuide(region: CaptureRegion) {
        let panel = guidePanel ?? makeGuidePanel()
        guidePanel = panel
        panel.setFrame(region.selectionRectInAppKitGlobalPoints.insetBy(dx: -1, dy: -1), display: true)
        panel.orderFrontRegardless()
    }

    private func makeGuidePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.clear.cgColor
        border.layer?.borderColor = NSColor.systemRed.cgColor
        border.layer?.borderWidth = 2
        panel.contentView = border
        return panel
    }
}
