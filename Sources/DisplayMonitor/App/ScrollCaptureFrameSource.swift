import CoreImage
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import Foundation
import OSLog
import ScreenCaptureKit

struct ScrollCapturedFrame: @unchecked Sendable {
    var sequence: UInt64
    var capturedAt: Date
    var image: CGImage
    var signature: ScrollImageSignature
}

struct ScrollBufferedFrameDescriptor: Sendable {
    var sequence: UInt64
    var capturedAt: Date
    var signature: ScrollImageSignature
}

enum ScrollCaptureFilterRefreshPolicy {
    /// Application exclusions already cover windows created after the stream
    /// starts. Replacing that live filter with another equivalent filter can
    /// stall damage delivery on some ScreenCaptureKit/macOS combinations.
    /// Only the explicit-window fallback needs to be refreshed after the HUD
    /// and decorative guide windows are created.
    static func requiresLiveUpdate(for strategy: String) -> Bool {
        strategy.hasPrefix("windows:")
    }
}

enum ScrollFrameCheckpointPlanner {
    /// A programmatic chunk advances at most 35% of the viewport. Its first
    /// and final frames retain overlap without committing every sampled frame
    /// and consuming the session's 100-piece limit on a few short gestures.
    static func programmaticScrollSequences(from descriptors: [ScrollBufferedFrameDescriptor]) -> [UInt64] {
        sequences(from: descriptors, maximumCount: 2)
    }

    /// Preserves the first and last buffered frames and distributes the rest
    /// across the gesture. A long physical flick can therefore become several
    /// safe internal strips without turning into several user-visible actions.
    static func sequences(
        from descriptors: [ScrollBufferedFrameDescriptor],
        maximumCount: Int = 10
    ) -> [UInt64] {
        guard !descriptors.isEmpty, maximumCount > 0 else { return [] }
        guard descriptors.count > maximumCount else {
            return descriptors.map(\.sequence)
        }
        guard maximumCount > 1 else { return [descriptors.last!.sequence] }
        var indexes = Set<Int>([0, descriptors.count - 1])
        for slot in 1..<(maximumCount - 1) {
            let position = Double(slot) * Double(descriptors.count - 1) /
                Double(maximumCount - 1)
            indexes.insert(Int(position.rounded()))
        }
        return indexes.sorted().map { descriptors[$0].sequence }
    }

    /// Uses gesture travel and duration only to decide how many frames deserve
    /// precise analysis. Image signatures never authorize a commit here; every
    /// selected frame still passes full-height registration and ambiguity
    /// rejection in the controller.
    static func continuousGestureSequences(
        from descriptors: [ScrollBufferedFrameDescriptor],
        estimatedTotalOffsetPixels: Double?,
        viewportHeight: Int,
        maximumCount: Int = 12
    ) -> [UInt64] {
        guard !descriptors.isEmpty, maximumCount > 0, viewportHeight > 0 else { return [] }
        let durationCount = max(1, Int(ceil(Double(descriptors.count) / 8)))
        let targetAdvance = max(8, Double(viewportHeight) * 0.42)
        let motionCount = estimatedTotalOffsetPixels.map {
            max(1, Int(ceil(abs($0) / targetAdvance)))
        } ?? 1
        let desiredCount = min(maximumCount, max(durationCount, motionCount))
        var indexes = Set<Int>()
        for slot in 1...desiredCount {
            let boundary = Double(slot) * Double(descriptors.count) / Double(desiredCount)
            indexes.insert(min(descriptors.count - 1, max(0, Int(ceil(boundary)) - 1)))
        }
        return indexes.sorted().map { descriptors[$0].sequence }
    }
}

/// Keeps one ScreenCaptureKit stream alive for an entire scroll-capture
/// operation. The sample callback owns frame conversion; callers only ask for
/// the latest stable frame and never recreate shareable content per segment.
@MainActor
final class ScrollCaptureFrameSource {
    var onStreamStopped: ((CaptureError) -> Void)?

    private var buffer = ScrollFrameBuffer()
    private let shareableContentProvider: @MainActor () async throws -> SCShareableContent
    private let snapshotService = ScreenshotService()
    private let nativeOperations: CaptureSessionNativeOperations
    private let imageContext = CIContext()
    private let logger = Logger(
        subsystem: "com.hanshuai.DisplayMonitor",
        category: "ScrollFrameSource"
    )
    private let sampleQueue = DispatchQueue(
        label: "com.hanshuai.DisplayMonitor.scroll.frames",
        qos: .userInitiated
    )
    private var stream: SCStream?
    private var receiver: ScrollCaptureFrameReceiver?
    private var streamDelegate: ScrollCaptureStreamDelegate?
    private var activeRegion: CaptureRegion?
    private var activeDisplayID: CGDirectDisplayID?
    private var snapshotSequence: UInt64 = 0
    private var sessionID: UUID?
    private var stopsInFlight = 0

    init(
        nativeOperations: CaptureSessionNativeOperations? = nil,
        shareableContentProvider: @escaping @MainActor () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    ) {
        self.nativeOperations = nativeOperations ?? CaptureSessionNativeOperations(prefix: "scroll_capture")
        self.shareableContentProvider = shareableContentProvider
    }

    var isActive: Bool { sessionID != nil }

    var latestSequence: UInt64 {
        max(buffer.latest()?.sequence ?? 0, snapshotSequence)
    }

    func start(
        region: CaptureRegion,
        displayID: CGDirectDisplayID
    ) async throws -> ScrollCapturedFrame {
        try Task.checkCancellation()
        guard !isActive else {
            throw CaptureError(code: "scroll_capture_already_running", message: "当前已有滚动截图")
        }
        guard stopsInFlight == 0 else {
            throw CaptureError(code: "scroll_capture_native_operation_pending", message: "系统采集服务仍在结束上次请求，请稍后重试")
        }
        try nativeOperations.beginSession()
        let operationID = UUID()
        sessionID = operationID
        await stopCurrentStream()
        do {
            try validateActive(operationID)
        } catch {
            if sessionID == operationID { sessionID = nil }
            throw error
        }
        // A previous stream may still deliver queued callbacks while its stop
        // completes. Each receiver keeps its own disabled buffer.
        buffer = ScrollFrameBuffer()
        buffer.beginSession()
        activeRegion = region
        activeDisplayID = displayID
        snapshotSequence = 0

        var pendingStream: SCStream?
        var pendingReceiver: ScrollCaptureFrameReceiver?
        do {
            let content = try await nativeOperations.startupValue(stage: "shareable") { [shareableContentProvider] in
                try await shareableContentProvider()
            }
            try validateActive(operationID)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError(code: "display_not_shareable", message: "滚动截图所在显示器不可采集")
            }

            let filter = makeFilter(content: content, display: display).filter
            let configuration = SCStreamConfiguration()
            configuration.width = region.pixelRectInCaptureSpace.width
            configuration.height = region.pixelRectInCaptureSpace.height
            configuration.sourceRect = region.sourceRectInPlatformLogicalPoints
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 4
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let receiver = ScrollCaptureFrameReceiver(buffer: buffer)
            let delegate = ScrollCaptureStreamDelegate { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == operationID, self.stream != nil else { return }
                    self.onStreamStopped?(
                        CaptureError(
                            code: "scroll_capture_stream_stopped",
                            message: "滚动截图采集流已停止",
                            detail: error.localizedDescription
                        )
                    )
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            pendingStream = stream
            pendingReceiver = receiver
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: sampleQueue)
            self.receiver = receiver
            streamDelegate = delegate
            self.stream = stream

            try await nativeOperations.startupValue(
                stage: "start",
                operation: { try await stream.startCapture() },
                onLateResult: { [nativeOperations] _ in
                    try? stream.removeStreamOutput(receiver, type: .screen)
                    try? await nativeOperations.stop(stream, afterLateStart: true)
                }
            )
            try validateActive(operationID)
            if let frame = await waitForFirstFrame(timeout: 2, operationID: operationID) {
                try validateActive(operationID)
                return frame
            }
            throw CaptureError(code: "scroll_capture_first_frame_timeout", message: "滚动截图未收到起始画面")
        } catch {
            let wasCancelled = sessionID != operationID || Task.isCancelled
            if sessionID == operationID {
                await stop()
            } else if let pendingStream {
                // stop() may have raced an in-flight startCapture(). Stop the
                // now-started old stream without touching the replacement.
                await stopStream(pendingStream, receiver: pendingReceiver)
            }
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Rebuilds the filter after the capture HUD and guide windows exist. The
    /// initial shareable-content snapshot is necessarily taken before those
    /// windows are shown, so a window-list fallback must be refreshed before
    /// user scrolling is armed.
    @discardableResult
    func refreshOwnWindowExclusions(
        displayID: CGDirectDisplayID
    ) async throws -> String {
        guard let operationID = sessionID, let stream else {
            throw CaptureError(
                code: "scroll_capture_stream_missing",
                message: "滚动截图采集流尚未启动"
            )
        }
        let content = try await nativeOperations.startupValue(stage: "refresh_shareable") { [shareableContentProvider] in
            try await shareableContentProvider()
        }
        try validateActive(operationID)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError(code: "display_not_shareable", message: "滚动截图所在显示器不可采集")
        }
        let result = makeFilter(content: content, display: display)
        guard ScrollCaptureFilterRefreshPolicy.requiresLiveUpdate(for: result.strategy) else {
            return "\(result.strategy):stable"
        }
        try await nativeOperations.startupValue(stage: "filter") {
            try await stream.updateContentFilter(result.filter)
        }
        try validateActive(operationID)
        return "\(result.strategy):refreshed"
    }

    /// Waits until two successive frame signatures are visually stable. A
    /// timeout returns the newest post-event frame so the registration layer can
    /// still distinguish movement, no movement, and an unsupported animation.
    func stableFrame(
        after minimumSequence: UInt64,
        timeout: TimeInterval = 0.65
    ) async -> ScrollCapturedFrame? {
        guard let operationID = sessionID, !Task.isCancelled else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var previous: ScrollBufferedFrame?
        var stableMatches = 0

        while Date() < deadline, !Task.isCancelled, sessionID == operationID {
            if let latest = buffer.latest(),
               latest.sequence > minimumSequence,
               latest.sequence != previous?.sequence {
                if let previous,
                   latest.signature.meanAbsoluteDifference(from: previous.signature) <= 1.8 {
                    stableMatches += 1
                } else {
                    stableMatches = 0
                }
                previous = latest
                if stableMatches >= 1 {
                    return await materialize(latest)
                }
            }
            try? await Task.sleep(nanoseconds: 45_000_000)
        }
        guard sessionID == operationID, !Task.isCancelled else { return nil }
        if let latest = buffer.latest(), latest.sequence > minimumSequence {
            return await materialize(latest)
        }
        // ScreenCaptureKit can omit damage callbacks for some browser and
        // full-screen-space combinations. A current single-frame snapshot is
        // authoritative; registration still decides whether it actually moved.
        return await snapshotFrame(after: minimumSequence)
    }

    func frameDescriptors(after minimumSequence: UInt64) -> [ScrollBufferedFrameDescriptor] {
        buffer.frames(after: minimumSequence).map {
            ScrollBufferedFrameDescriptor(
                sequence: $0.sequence,
                capturedAt: $0.capturedAt,
                signature: $0.signature
            )
        }
    }

    func materializedFrame(sequence: UInt64) async -> ScrollCapturedFrame? {
        guard let frame = buffer.frame(sequence: sequence) else { return nil }
        return await materialize(frame)
    }

    /// Captures the viewport at the operator-confirmed position. A fresh
    /// snapshot is preferred so the provisional frame cannot survive a start
    /// reposition merely because the live stream omitted damage callbacks.
    func latestFrame() async -> ScrollCapturedFrame? {
        guard let operationID = sessionID, !Task.isCancelled else { return nil }
        if let frame = await snapshotFrame(after: latestSequence) {
            return frame
        }
        guard sessionID == operationID, !Task.isCancelled else { return nil }
        guard let frame = buffer.latest() else { return nil }
        return await materialize(frame)
    }

    /// The controller owns its artifact and lease cleanup. Interrupt its native
    /// startup wait synchronously so cancellation can reach that cleanup path.
    func cancelPendingStart() {
        nativeOperations.cancelStartupWait()
    }

    func stop() async {
        stopsInFlight += 1
        defer { stopsInFlight -= 1 }
        sessionID = nil
        cancelPendingStart()
        await stopCurrentStream()
    }

    private func stopCurrentStream() async {
        let stream = self.stream
        let receiver = self.receiver
        self.stream = nil
        self.receiver = nil
        streamDelegate = nil
        buffer.reset()
        activeRegion = nil
        activeDisplayID = nil
        snapshotSequence = 0
        if let stream { await stopStream(stream, receiver: receiver) }
    }

    private func stopStream(_ stream: SCStream, receiver: ScrollCaptureFrameReceiver?) async {
        if let receiver { try? stream.removeStreamOutput(receiver, type: .screen) }
        // A cancelled caller must still launch uncancelled native retirement.
        let cleanup = Task { @MainActor [nativeOperations, logger] in
            do { try await nativeOperations.stop(stream) }
            catch {
                logger.error("scroll.stream.stop.incomplete \(String(describing: error), privacy: .public)")
            }
        }
        await cleanup.value
    }

    private func validateActive(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == operationID else { throw CancellationError() }
    }

    private func waitForFirstFrame(timeout: TimeInterval, operationID: UUID) async -> ScrollCapturedFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled, sessionID == operationID {
            if let frame = buffer.latest() {
                return await materialize(frame)
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        guard sessionID == operationID, !Task.isCancelled else { return nil }
        guard let frame = buffer.latest() else { return nil }
        return await materialize(frame)
    }

    private func materialize(_ frame: ScrollBufferedFrame) async -> ScrollCapturedFrame? {
        guard let operationID = sessionID, !Task.isCancelled else { return nil }
        let context = imageContext
        let result = await Task.detached(priority: .userInitiated) { () -> ScrollCapturedFrame? in
            let width = CVPixelBufferGetWidth(frame.pixelBuffer)
            let height = CVPixelBufferGetHeight(frame.pixelBuffer)
            guard let image = context.createCGImage(
                CIImage(cvPixelBuffer: frame.pixelBuffer),
                from: CGRect(x: 0, y: 0, width: width, height: height)
            ) else {
                return nil
            }
            return ScrollCapturedFrame(
                sequence: frame.sequence,
                capturedAt: frame.capturedAt,
                image: image,
                signature: frame.signature
            )
        }.value
        guard sessionID == operationID, !Task.isCancelled else { return nil }
        return result
    }

    private func snapshotFrame(after minimumSequence: UInt64) async -> ScrollCapturedFrame? {
        guard let operationID = sessionID, let activeRegion, let activeDisplayID, !Task.isCancelled else { return nil }
        do {
            let image = try await snapshotService.capture(
                region: activeRegion,
                displayID: activeDisplayID
            )
            guard sessionID == operationID, !Task.isCancelled else { return nil }
            guard var signature = ScrollStitcher.signature(for: image) else { return nil }
            signature.sourceHeight = image.height
            let sequence = max(minimumSequence, latestSequence) &+ 1
            snapshotSequence = sequence
            logger.info(
                "scroll.frame.snapshot sequence=\(sequence, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)"
            )
            return ScrollCapturedFrame(
                sequence: sequence,
                capturedAt: Date(),
                image: image,
                signature: signature
            )
        } catch {
            logger.error(
                "scroll.frame.snapshot_failed error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func makeFilter(
        content: SCShareableContent,
        display: SCDisplay
    ) -> (filter: SCContentFilter, strategy: String) {
        CurrentProcessCaptureFilter.makeWithStrategy(content: content, display: display)
    }
}

private struct ScrollBufferedFrame: @unchecked Sendable {
    var sequence: UInt64
    var capturedAt: Date
    var pixelBuffer: CVPixelBuffer
    var signature: ScrollImageSignature
}

private final class ScrollFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumFrameCount = 72
    private let maximumBytes = 160 * 1_024 * 1_024
    private var storedFrames: [ScrollBufferedFrame] = []
    private var storedBytes = 0
    private var sequence: UInt64 = 0
    private var isAcceptingFrames = false

    func publish(pixelBuffer: CVPixelBuffer, signature: ScrollImageSignature) {
        lock.lock()
        guard isAcceptingFrames else {
            lock.unlock()
            return
        }
        sequence &+= 1
        let frame = ScrollBufferedFrame(
            sequence: sequence,
            capturedAt: Date(),
            pixelBuffer: pixelBuffer,
            signature: signature
        )
        storedFrames.append(frame)
        storedBytes += Self.byteCount(of: pixelBuffer)
        while storedFrames.count > 2,
              storedFrames.count > maximumFrameCount || storedBytes > maximumBytes {
            let removed = storedFrames.removeFirst()
            storedBytes = max(0, storedBytes - Self.byteCount(of: removed.pixelBuffer))
        }
        lock.unlock()
    }

    func beginSession() {
        lock.lock()
        sequence = 0
        storedFrames.removeAll(keepingCapacity: true)
        storedBytes = 0
        isAcceptingFrames = true
        lock.unlock()
    }

    func latest() -> ScrollBufferedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames.last
    }

    func frames(after minimumSequence: UInt64) -> [ScrollBufferedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames.filter { $0.sequence > minimumSequence }
    }

    func frame(sequence: UInt64) -> ScrollBufferedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames.first { $0.sequence == sequence }
    }

    func reset() {
        lock.lock()
        sequence = 0
        storedFrames.removeAll(keepingCapacity: false)
        storedBytes = 0
        isAcceptingFrames = false
        lock.unlock()
    }

    private static func byteCount(of pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
    }
}

private final class ScrollCaptureFrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    private let context = CIContext()
    private let buffer: ScrollFrameBuffer

    init(buffer: ScrollFrameBuffer) {
        self.buffer = buffer
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
        guard let signature = makeSignature(
            for: imageBuffer,
            width: width,
            height: height
        ) else {
            return
        }
        buffer.publish(pixelBuffer: imageBuffer, signature: signature)
    }

    /// Samples the stream buffer directly into the same bounded signature used
    /// by registration. Full-resolution `CGImage` creation is deferred until a
    /// stable frame is actually accepted as a viewport piece.
    private func makeSignature(
        for pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> ScrollImageSignature? {
        guard width > 0, height > 0 else { return nil }
        let sampleWidth = min(72, width)
        let sampleHeight = min(
            height,
            min(
                512,
                max(96, Int(Double(height) * Double(sampleWidth) / Double(max(1, width))))
            )
        )
        let scaleX = Double(sampleWidth) / Double(width)
        let scaleY = Double(sampleHeight) / Double(height)
        let sampled = CIImage(cvPixelBuffer: pixelBuffer).transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        guard let image = context.createCGImage(
            sampled,
            from: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
        ), var signature = ScrollStitcher.signature(for: image) else {
            return nil
        }
        signature.sourceHeight = height
        return signature
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

private final class ScrollCaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
