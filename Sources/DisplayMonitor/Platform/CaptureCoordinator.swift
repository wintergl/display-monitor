import AVFoundation
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import Foundation
import OSLog
import ScreenCaptureKit

/// Resumes its caller on timeout/cancellation without waiting for a native API
/// that ignores Swift task cancellation. A late result still runs its retirement
/// hook, so a late successful start cannot leave an unowned stream running.
@MainActor
final class CaptureNativeCallDeadline<Value> {
    private var continuation: CheckedContinuation<Void, Never>?
    private var result: Swift.Result<Value, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var isResolved = false

    func value(
        timeoutNanoseconds: UInt64,
        timeoutError: CaptureError,
        operation: @escaping @MainActor () async throws -> Value,
        onLateResult: @escaping @MainActor (Swift.Result<Value, Error>) async -> Void = { _ in },
        onSettled: @escaping @MainActor () -> Void = {}
    ) async throws -> Value {
        guard !Task.isCancelled else {
            onSettled()
            throw CancellationError()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                work = Task { @MainActor [self] in
                    let result: Swift.Result<Value, Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    if isResolved {
                        await onLateResult(result)
                        onSettled()
                    } else {
                        onSettled()
                        resolve(result)
                    }
                }
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.resolve(.failure(timeoutError))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.failure(CancellationError())) }
        }
        guard let result else { throw CancellationError() }
        return try result.get()
    }

    /// Cancels only the caller's wait; native work still retires its late result.
    func cancelWait() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Swift.Result<Value, Error>) {
        guard !isResolved else { return }
        isResolved = true
        self.result = result
        let continuation = continuation
        self.continuation = nil
        // A native start may ignore cancellation and succeed later. Keep its
        // single work task alive to retire that result from an uncancelled task.
        timer?.cancel()
        work = nil
        timer = nil
        continuation?.resume()
    }
}

/// A timed-out native call still exists until its callback (and any retirement)
/// settles. Reject retries during that interval instead of stacking more calls.
@MainActor
final class CaptureNativeRequestRegistry {
    private var pending: Set<UUID> = []
    private(set) var needsRecovery = false
    var canStart: Bool { pending.isEmpty && !needsRecovery }
    var pendingCount: Int { pending.count }

    func begin() -> UUID {
        let id = UUID()
        pending.insert(id)
        return id
    }

    func settle(_ id: UUID) { pending.remove(id) }
    func markStopFailure() { needsRecovery = true }
}

/// Keeps the native stream's asynchronous start/stop calls in order. A later
/// request invalidates an earlier start even while ScreenCaptureKit is suspended.
@MainActor
final class CaptureTransitionQueue {
    private var revision = 0
    private var tail: Task<Void, Never>?

    func isCurrent(_ revision: Int) -> Bool {
        self.revision == revision
    }

    func submit(
        _ operation: @escaping @MainActor @Sendable (Int) async throws -> Void
    ) -> Task<Void, Error> {
        revision &+= 1
        let revision = revision
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            try await operation(revision)
        }
        tail = Task { _ = await task.result }
        return task
    }
}

@MainActor
final class CaptureCoordinator {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Capture")
    private let sampleDisplayCoordinator: SampleBufferDisplayCoordinator
    private let sampleQueue = DispatchQueue(label: "com.hanshuai.DisplayMonitor.capture.samples")

    private var stream: SCStream?
    private var receiver: SampleBufferReceiver?
    private var localPreview: LocalPreviewFramePump<CMSampleBuffer>?
    private let transitions = CaptureTransitionQueue()
    private let nativeRequests = CaptureNativeRequestRegistry()
    private var nativeStops: [ObjectIdentifier: (id: UUID, task: Task<Void, Error>)] = [:]

    init(sampleDisplayCoordinator: SampleBufferDisplayCoordinator) {
        self.sampleDisplayCoordinator = sampleDisplayCoordinator
    }

    func start(
        display: DisplayDescriptor,
        frameRate: Int,
        captureResolution: CaptureResolutionPreset,
        showsCursor: Bool,
        generation: Int,
        onFrame: @escaping @MainActor @Sendable (Int, Date, Int) -> Void,
        onError: @escaping @MainActor @Sendable (Int, CaptureError) -> Void
    ) async throws {
        receiver?.invalidate()
        localPreview?.stop()
        let task = transitions.submit { [self] revision in
            try await stopCurrentStream()
            try checkCurrentStart(revision)
            try await startCurrentStream(
                display: display,
                frameRate: frameRate,
                captureResolution: captureResolution,
                showsCursor: showsCursor,
                generation: generation,
                revision: revision,
                onFrame: onFrame,
                onError: onError
            )
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func checkCurrentStart(_ revision: Int) throws {
        try Task.checkCancellation()
        guard transitions.isCurrent(revision) else {
            throw CancellationError()
        }
    }

    private func startCurrentStream(
        display: DisplayDescriptor,
        frameRate: Int,
        captureResolution: CaptureResolutionPreset,
        showsCursor: Bool,
        generation: Int,
        revision: Int,
        onFrame: @escaping @MainActor @Sendable (Int, Date, Int) -> Void,
        onError: @escaping @MainActor @Sendable (Int, CaptureError) -> Void
    ) async throws {
        // Keep at most the existing native request(s) alive when a framework
        // callback never arrives. Retrying must not accumulate abandoned Tasks.
        guard nativeRequests.canStart else {
            throw CaptureError(
                code: "capture_native_operation_pending",
                message: nativeRequests.needsRecovery
                    ? "系统采集服务停止失败，请重新启动应用"
                    : "系统采集服务尚未完成上次请求，请稍后重试",
                detail: nativeRequests.needsRecovery ? "native stop failed; restart required" : "native callback pending"
            )
        }
        let content = try await nativeCall(
            timeoutNanoseconds: 5_000_000_000,
            timeoutError: CaptureError(code: "capture_display_lookup_timeout", message: "系统显示器读取超时，请重试"),
            operation: {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        )
        try checkCurrentStart(revision)
        guard let targetDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError(code: "display_not_shareable", message: "目标显示器不可采集")
        }
        let filterResult = CurrentProcessCaptureFilter.makeWithStrategy(
            content: content,
            display: targetDisplay
        )
        let filter = filterResult.filter
        logger.info("filter.currentApp strategy=\(filterResult.strategy, privacy: .public)")
        let sourceSize = try sourcePixelSize(for: display, scDisplay: targetDisplay, filter: filter)
        let outputSize = try OutputSizeCalculator.calculate(
            sourcePixelWidth: sourceSize.width,
            sourcePixelHeight: sourceSize.height,
            maxWidth: captureResolution.maxPixelSize.width,
            maxHeight: captureResolution.maxPixelSize.height
        )

        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false

        if #available(macOS 14.0, *) {
            let epoch = sampleDisplayCoordinator.frameEpoch
            let screenshotSource = try LocalPreviewScreenshotSource(filter: filter, configuration: configuration)
            let pump = LocalPreviewFramePump<CMSampleBuffer>(
                frameRate: frameRate,
                capture: { [weak self] in
                    guard let self else { throw CancellationError() }
                    let buffer = try await self.nativeCall(
                        timeoutNanoseconds: 3_000_000_000,
                        timeoutError: CaptureError(code: "local_preview_frame_timeout", message: "本地预览取帧超时"),
                        operation: { try await screenshotSource.capture() }
                    )
                    guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
                          let image = CMSampleBufferGetImageBuffer(buffer),
                          CVPixelBufferGetWidth(image) == outputSize.width,
                          CVPixelBufferGetHeight(image) == outputSize.height else {
                        throw CaptureError(code: "local_preview_invalid_frame", message: "本地预览画面无效")
                    }
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary],
                       let first = attachments.first {
                        first[kCMSampleAttachmentKey_DisplayImmediately] = true
                    }
                    return buffer
                },
                present: { [sampleDisplayCoordinator] buffer in
                    let date = Date()
                    sampleDisplayCoordinator.enqueue(buffer, epoch: epoch) { count in
                        onFrame(generation, date, count)
                    }
                },
                failed: { error in
                    onError(generation, (error as? CaptureError) ?? CaptureError(
                        code: "local_preview_frame_failed", message: "本地预览取帧失败", detail: String(describing: error)
                    ))
                }
            )
            localPreview = pump
            logger.info("localPreview.start requestedFPS=\(frameRate, privacy: .public) width=\(outputSize.width, privacy: .public) height=\(outputSize.height, privacy: .public) sharingStream=false")
            do {
                try await pump.start()
                try checkCurrentStart(revision)
            } catch {
                pump.stop()
                localPreview = nil
                sampleDisplayCoordinator.flush()
                throw error
            }
            logger.info("localPreview.firstFrame sharingStream=false")
            return
        }

        let canaryGate = CanaryGate()
        let receiver = SampleBufferReceiver(
            generation: generation,
            sampleDisplayCoordinator: sampleDisplayCoordinator,
            frameEpoch: sampleDisplayCoordinator.frameEpoch,
            expectedSize: outputSize,
            canaryGate: canaryGate,
            onFrame: { [weak self] generation, date, frameCount in
                guard self?.transitions.isCurrent(revision) == true else { return }
                onFrame(generation, date, frameCount)
            },
            onError: { [weak self] generation, error in
                guard self?.transitions.isCurrent(revision) == true else { return }
                onError(generation, error)
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        self.receiver = receiver

        logger.info("stream.start generation=\(generation) display=\(display.id)")
        do {
            try await nativeCall(
                timeoutNanoseconds: 5_000_000_000,
                timeoutError: CaptureError(code: "capture_native_start_timeout", message: "系统采集启动超时，请重试"),
                operation: { try await stream.startCapture() },
                onLateResult: { [self] _ in
                    receiver.invalidate()
                    do { try await stopNativeStream(stream, receiver: receiver, afterLateStart: true) }
                    catch {
                        logger.error("stream.lateStart.retirementFailed \(String(describing: error), privacy: .public)")
                    }
                }
            )
            try checkCurrentStart(revision)
            try await canaryGate.waitForFirstFrame(timeoutSeconds: 2)
            try checkCurrentStart(revision)
        } catch {
            do { try await stopCurrentStream() }
            catch {
                logger.error("stream.start.cleanupFailed \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    @discardableResult
    func stop() async -> CaptureError? {
        receiver?.invalidate()
        localPreview?.stop()
        let task = transitions.submit { [self] _ in
            try await stopCurrentStream()
        }
        do {
            try await task.value
            return nil
        } catch let error as CaptureError {
            logger.error("stream.stop.incomplete code=\(error.code, privacy: .public)")
            return error
        } catch {
            return CaptureError(code: "capture_native_stop_failed", message: "系统采集停止失败", detail: String(describing: error))
        }
    }

    private func stopCurrentStream() async throws {
        let wasLocalPreview = localPreview != nil
        if let localPreview {
            logger.info("localPreview.stop frames=\(localPreview.frameCount, privacy: .public)")
            localPreview.stop()
            self.localPreview = nil
        }
        if wasLocalPreview {
            // Cancellation releases the waiting Swift task before the native
            // still callback necessarily settles. Give that single callback a
            // bounded retirement window before a serialized restart.
            let deadline = ContinuousClock.now + .seconds(3)
            while nativeRequests.pendingCount > 0, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { break }
            }
        }
        guard let stream else {
            sampleDisplayCoordinator.flush()
            // A cancelled still request may finish late. It owns no persistent
            // sharing resource; its registry marker still blocks a new start.
            guard wasLocalPreview || nativeRequests.canStart else {
                throw CaptureError(
                    code: "capture_native_operation_pending",
                    message: nativeRequests.needsRecovery
                        ? "系统采集服务停止失败，请重新启动应用"
                        : "系统采集服务仍在结束上次请求"
                )
            }
            return
        }

        let receiver = self.receiver
        receiver?.invalidate()
        self.stream = nil
        self.receiver = nil
        logger.info("stream.stop")
        var stopFailure: Error?
        do { try await stopNativeStream(stream, receiver: receiver) }
        catch { stopFailure = error }
        if let receiver {
            do {
                try stream.removeStreamOutput(receiver, type: .screen)
            } catch {
                logger.error("stream.removeOutput.failed \(String(describing: error), privacy: .public)")
            }
        }
        sampleDisplayCoordinator.flush()
        if let stopFailure { throw stopFailure }
    }

    private func stopNativeStream(
        _ stream: SCStream,
        receiver: SampleBufferReceiver?,
        afterLateStart: Bool = false
    ) async throws {
        let key = ObjectIdentifier(stream)
        if let previous = nativeStops[key] {
            let result = await previous.task.result
            if !afterLateStart { return try result.get() }
            // A stop issued before start's native callback may have observed an
            // unstarted stream. Retire once more after that callback is known.
        }
        let operationID = UUID()
        let task = Task { @MainActor [self] in
            try await performNativeStop(stream, receiver: receiver, force: afterLateStart)
        }
        nativeStops[key] = (operationID, task)
        defer {
            if nativeStops[key]?.id == operationID { nativeStops.removeValue(forKey: key) }
        }
        try await task.value
    }

    private func performNativeStop(_ stream: SCStream, receiver: SampleBufferReceiver?, force: Bool) async throws {
        guard force || receiver?.hasStopped != true else { return }
        do {
            try await nativeCall(
                timeoutNanoseconds: 3_000_000_000,
                timeoutError: CaptureError(code: "capture_native_stop_timeout", message: "系统采集停止超时，请稍后重试"),
                operation: { try await stream.stopCapture() },
                onLateResult: { [self] result in
                    if case .failure(let error) = result, !isAlreadyStopped(error) {
                        nativeRequests.markStopFailure()
                        logger.error("stream.lateStop.failed \(String(describing: error), privacy: .public)")
                    }
                }
            )
        } catch {
            if isAlreadyStopped(error) {
                logger.info("stream.stop.alreadyStopped")
                return
            }
            if !(error is CaptureError) && !(error is CancellationError) {
                nativeRequests.markStopFailure()
            }
            logger.error("stream.stop.failed \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func isAlreadyStopped(_ error: Error) -> Bool {
        let nativeError = error as NSError
        return nativeError.domain == SCStreamErrorDomain && nativeError.code == -3808
    }

    private func nativeCall<Value>(
        timeoutNanoseconds: UInt64,
        timeoutError: CaptureError,
        operation: @escaping @MainActor () async throws -> Value,
        onLateResult: @escaping @MainActor (Swift.Result<Value, Error>) async -> Void = { _ in }
    ) async throws -> Value {
        try Task.checkCancellation()
        let operationID = nativeRequests.begin()
        return try await CaptureNativeCallDeadline<Value>().value(
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutError: timeoutError,
            operation: operation,
            onLateResult: onLateResult,
            onSettled: { [self] in nativeRequests.settle(operationID) }
        )
    }

    private func sourcePixelSize(
        for descriptor: DisplayDescriptor,
        scDisplay: SCDisplay,
        filter: SCContentFilter
    ) throws -> PixelSize {
        let scWidth = max(1, Double(scDisplay.width))
        let scHeight = max(1, Double(scDisplay.height))
        var width = descriptor.pixelSize.width
        var height = descriptor.pixelSize.height

        if #available(macOS 14.0, *) {
            let scale = Double(filter.pointPixelScale)
            if scale.isFinite, scale > 0 {
                width = max(1, Int((scWidth * scale).rounded()))
                height = max(1, Int((scHeight * scale).rounded()))
            }
        }

        let scAspect = scWidth / scHeight
        let pixelAspect = Double(width) / Double(max(1, height))
        let swappedPixelAspect = Double(height) / Double(max(1, width))
        if abs(pixelAspect - scAspect) / scAspect > 0.01,
           abs(swappedPixelAspect - scAspect) / scAspect <= 0.01 {
            swap(&width, &height)
        }

        let finalAspect = Double(width) / Double(max(1, height))
        guard width > 0,
              height > 0,
              abs(finalAspect - scAspect) / scAspect <= 0.01 else {
            throw CaptureError(
                code: "source_size_mismatch",
                message: "源画面尺寸与显示器方向不一致",
                detail: "\(width)x\(height), sc=\(Int(scWidth))x\(Int(scHeight))"
            )
        }
        return PixelSize(width: width, height: height)
    }
}

private final class SampleBufferReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lifecycleLock = NSLock()
    private var isValid = true
    private var streamHasStopped = false
    private var firstFrameSignalled = false
    var hasStopped: Bool { lifecycleLock.withLock { streamHasStopped } }
    let generation: Int
    let sampleDisplayCoordinator: SampleBufferDisplayCoordinator
    let frameEpoch: UInt64
    let expectedSize: PixelSize
    let canaryGate: CanaryGate
    let onFrame: @MainActor @Sendable (Int, Date, Int) -> Void
    let onError: @MainActor @Sendable (Int, CaptureError) -> Void

    init(
        generation: Int,
        sampleDisplayCoordinator: SampleBufferDisplayCoordinator,
        frameEpoch: UInt64,
        expectedSize: PixelSize,
        canaryGate: CanaryGate,
        onFrame: @escaping @MainActor @Sendable (Int, Date, Int) -> Void,
        onError: @escaping @MainActor @Sendable (Int, CaptureError) -> Void
    ) {
        self.generation = generation
        self.sampleDisplayCoordinator = sampleDisplayCoordinator
        self.frameEpoch = frameEpoch
        self.expectedSize = expectedSize
        self.canaryGate = canaryGate
        self.onFrame = onFrame
        self.onError = onError
    }

    func invalidate() {
        lifecycleLock.withLock { isValid = false }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldReport = lifecycleLock.withLock {
            streamHasStopped = true
            let shouldReport = isValid
            isValid = false
            return shouldReport
        }
        guard shouldReport else { return }
        let captureError = CaptureError(
            code: "stream_stopped",
            message: "屏幕采集已中断",
            detail: String(describing: error)
        )
        let gate = canaryGate
        let generation = generation
        let handler = onError
        Task {
            await gate.fail(captureError)
            await handler(generation, captureError)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else {
            return
        }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        guard frameStatus(for: sampleBuffer) == .complete else {
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(imageBuffer) == expectedSize.width,
              CVPixelBufferGetHeight(imageBuffer) == expectedSize.height else {
            return
        }

        let frameGeneration = generation
        let frameHandler = onFrame
        let frameDate = Date()
        let shouldSignalCanary = lifecycleLock.withLock {
            guard isValid else { return false }
            sampleDisplayCoordinator.enqueue(sampleBuffer, epoch: frameEpoch) { count in
                frameHandler(frameGeneration, frameDate, count)
            }
            guard !firstFrameSignalled else { return false }
            firstFrameSignalled = true
            return true
        }
        if shouldSignalCanary {
            let gate = canaryGate
            Task { await gate.markSatisfied() }
        }
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

private actor CanaryGate {
    private var satisfied = false
    private var failure: CaptureError?

    func fail(_ error: CaptureError) {
        failure = error
    }

    func markSatisfied() {
        satisfied = true
    }

    func waitForFirstFrame(timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if let failure { throw failure }
            if satisfied {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CaptureError(
            code: "canary_timeout",
            message: "采集验证超时",
            detail: "2 秒内未收到尺寸正确的 complete 视频帧"
        )
    }
}
