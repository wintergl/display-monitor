import AVFoundation
import CoreMedia
import Darwin
import DisplayMonitorCore
import Foundation
import OSLog

struct RecordingWriterMetrics: Sendable {
    var frameCount: Int
    var droppedFrameCount: Int
    var invalidTimestampCount: Int
    var firstPresentationTime: CMTime?
    var lastPresentationTime: CMTime?
    var failure: CaptureError?
}

protocol RecordingAssetWriterAdapter: AnyObject {
    var status: AVAssetWriter.Status { get }
    var error: Error? { get }
    func startWriting() -> Bool
    func startSession(atSourceTime startTime: CMTime)
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void)
    func cancelWriting()
}

protocol RecordingWriterInputAdapter: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
    func markAsFinished()
}

extension AVAssetWriter: RecordingAssetWriterAdapter {}
extension AVAssetWriterInput: RecordingWriterInputAdapter {}

/// AVAssetWriter is isolated to its own serial sample queue. ScreenCaptureKit
/// callbacks never await disk encoding; they only make a bounded append/drop
/// decision on this queue.
final class RecordingWriter: @unchecked Sendable {
    private struct ReadySample: @unchecked Sendable {
        // A ready sample is immutable after capture and retained until the
        // serial writer queue has consumed it.
        let value: CMSampleBuffer
    }
    let sampleHandlerQueue = DispatchQueue(label: "com.hanshuai.DisplayMonitor.recording.writer")

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "RecordingWriter")
    private let assetWriter: any RecordingAssetWriterAdapter
    private let input: any RecordingWriterInputAdapter
    private let onFailure: @MainActor @Sendable (CaptureError) -> Void
    private let onFirstFrameCommitted: @MainActor @Sendable (CMTime) -> Void
    private let injectedFault: AcceptanceWriterFault?
    private let acceptanceReporter: AcceptanceReporter?
    private let finishTimeout: TimeInterval

    private var timingPolicy = RecordingTimingPolicy()
    private var firstFrameGate: FirstFrameGate
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var frameCount = 0
    private var droppedFrameCount = 0
    private var invalidTimestampCount = 0
    private var failure: CaptureError?
    private var startedWriting = false
    private var finishing = false
    private var finishContinuation: CheckedContinuation<RecordingWriterMetrics, Never>?
    private var injectedFaultTriggered = false

    init(
        outputURL: URL,
        pixelSize: PixelSize,
        frameRate: Int = 30,
        deadlineID: UUID = UUID(),
        injectedFault: AcceptanceWriterFault? = nil,
        acceptanceReporter: AcceptanceReporter? = nil,
        finishTimeout: TimeInterval = 5,
        onFirstFrameCommitted: @escaping @MainActor @Sendable (CMTime) -> Void = { _ in },
        onFailure: @escaping @MainActor @Sendable (CaptureError) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelSize.width,
            AVVideoHeightKey: pixelSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, pixelSize.width * pixelSize.height * frameRate / 3),
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(input) else {
            throw CaptureError(code: "recording_writer_input_unavailable", message: "无法配置 H.264 写入器")
        }
        assetWriter.add(input)
        self.assetWriter = assetWriter
        self.input = input
        self.firstFrameGate = FirstFrameGate(deadlineID: deadlineID)
        self.injectedFault = injectedFault
        self.acceptanceReporter = acceptanceReporter
        self.finishTimeout = finishTimeout
        self.onFirstFrameCommitted = onFirstFrameCommitted
        self.onFailure = onFailure
    }

    init(
        assetWriter: any RecordingAssetWriterAdapter,
        input: any RecordingWriterInputAdapter,
        deadlineID: UUID,
        injectedFault: AcceptanceWriterFault? = nil,
        acceptanceReporter: AcceptanceReporter? = nil,
        finishTimeout: TimeInterval = 5,
        onFirstFrameCommitted: @escaping @MainActor @Sendable (CMTime) -> Void = { _ in },
        onFailure: @escaping @MainActor @Sendable (CaptureError) -> Void = { _ in }
    ) {
        self.assetWriter = assetWriter
        self.input = input
        self.firstFrameGate = FirstFrameGate(deadlineID: deadlineID)
        self.injectedFault = injectedFault
        self.acceptanceReporter = acceptanceReporter
        self.finishTimeout = finishTimeout
        self.onFirstFrameCommitted = onFirstFrameCommitted
        self.onFailure = onFailure
    }

    /// The screenshot pump awaits encoding admission before requesting another
    /// frame. This keeps at most one frame queued even under encoder pressure.
    @MainActor
    func appendAndWait(_ sampleBuffer: CMSampleBuffer) async {
        let sample = ReadySample(value: sampleBuffer)
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async { [self] in
                append(sample.value)
                continuation.resume()
            }
        }
    }

    /// Must be called from sampleHandlerQueue, also supplied to legacy SCStream.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, failure == nil, firstFrameGate.acceptsSamples else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        guard presentationSeconds.isFinite, presentationSeconds >= 0 else {
            invalidTimestampCount += 1
            logger.debug("recording.frame.discarded reason=invalidTimestamp")
            return
        }
        if !startedWriting {
            guard assetWriter.startWriting() else {
                fail(writerFailure(
                    defaultCode: "recording_start_writing_failed",
                    message: "无法开始 MP4 编码"
                ))
                return
            }
            assetWriter.startSession(atSourceTime: .zero)
            startedWriting = true
            if assetWriter.status == .failed {
                fail(writerFailure(
                    defaultCode: "recording_start_writing_failed",
                    message: "无法开始 MP4 编码"
                ))
                return
            }
        }
        let decision = timingPolicy.consume(
            presentationTime: presentationSeconds,
            writerReady: input.isReadyForMoreMediaData
        )
        switch decision {
        case .discardInvalidTimestamp:
            invalidTimestampCount += 1
            logger.debug("recording.frame.discarded reason=invalidTimestamp")
        case .dropBackpressure:
            droppedFrameCount += 1
        case .failBackpressure(let consecutive):
            droppedFrameCount += 1
            fail(
                CaptureError(
                    code: "recording_encoder_backpressure",
                    message: "录屏编码持续拥塞，已停止录制",
                    detail: "连续丢帧 \(consecutive) > \(RecordingTimingPolicy.backpressureFailureThreshold)"
                )
            )
        case .append:
            appendValidatedSample(sampleBuffer, presentationTime: presentationTime)
        }
    }

    func requestFirstFrameCancel() async -> FirstFrameGateResolution {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .alreadyResolved)
                    return
                }
                continuation.resume(returning: self.firstFrameGate.cancel())
            }
        }
    }

    func requestFirstFrameTimeout(deadlineID: UUID) async -> FirstFrameGateResolution {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .alreadyResolved)
                    return
                }
                continuation.resume(
                    returning: self.firstFrameGate.timeout(deadlineID: deadlineID)
                )
            }
        }
    }

    func committedFirstPresentationTime() async -> CMTime? {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async { [weak self] in
                continuation.resume(returning: self?.firstPresentationTime)
            }
        }
    }

    func finish() async -> RecordingWriterMetrics {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: RecordingWriterMetrics(
                        frameCount: 0,
                        droppedFrameCount: 0,
                        invalidTimestampCount: 0,
                        firstPresentationTime: nil,
                        lastPresentationTime: nil,
                        failure: CaptureError(code: "recording_writer_released", message: "录屏写入器已释放")
                    ))
                    return
                }
                guard !self.finishing else {
                    continuation.resume(returning: self.metrics())
                    return
                }
                self.finishing = true
                guard self.frameCount > 0, self.startedWriting else {
                    if self.startedWriting {
                        self.assetWriter.cancelWriting()
                    }
                    continuation.resume(returning: self.metrics(
                        failure: self.failure ?? CaptureError(
                            code: "recording_no_valid_frames",
                            message: "录屏没有收到有效视频帧"
                        )
                    ))
                    return
                }
                self.input.markAsFinished()
                self.finishContinuation = continuation
                self.assetWriter.finishWriting { [weak self] in
                    self?.sampleHandlerQueue.async { [weak self] in
                        self?.resolveFinishWriting(timedOut: false)
                    }
                }
                self.sampleHandlerQueue.asyncAfter(deadline: .now() + self.finishTimeout) { [weak self] in
                    self?.resolveFinishWriting(timedOut: true)
                }
            }
        }
    }

    /// AVAssetWriter has occasionally completed the file without invoking its
    /// completion callback. Both callback and watchdog re-enter the writer
    /// queue, so the continuation is resumed exactly once.
    private func resolveFinishWriting(timedOut: Bool) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil

        let writerError: CaptureError?
        if assetWriter.status == .completed {
            writerError = nil
            if timedOut {
                logger.notice("recording.writer.finish.callback.missed status=completed")
            }
        } else if timedOut {
            assetWriter.cancelWriting()
            writerError = failure ?? CaptureError(
                code: "recording_finish_timeout",
                message: "MP4 写入收尾超时，已保留可恢复文件"
            )
            logger.error("recording.writer.finish.timeout status=\(self.assetWriter.status.rawValue, privacy: .public)")
        } else {
            writerError = failure ?? writerFailure(
                defaultCode: "recording_finish_failed",
                message: "MP4 写入未完成"
            )
        }
        continuation.resume(returning: metrics(failure: writerError))
    }

    private func appendValidatedSample(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) {
        let normalizationBase = firstPresentationTime ?? presentationTime
        guard let normalized = normalizedSampleBuffer(
            from: sampleBuffer,
            firstPresentationTime: normalizationBase
        ) else {
            fail(CaptureError(code: "recording_timestamp_normalization_failed", message: "录屏时间戳无效"))
            return
        }
        if injectedFault == .beforeFirstAppend, frameCount == 0, !injectedFaultTriggered {
            triggerInjectedWriterFault(point: .beforeFirstAppend)
            return
        }
        guard input.append(normalized) else {
            fail(writerFailure(
                defaultCode: "recording_append_failed",
                message: "无法写入视频帧"
            ))
            return
        }
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
        }
        frameCount += 1
        lastPresentationTime = presentationTime
        if frameCount == 1 {
            let resolution = firstFrameGate.commitSuccessfulAppend(
                presentationTime: CMTimeGetSeconds(presentationTime)
            )
            if case .firstFrameCommitted = resolution {
                let handler = onFirstFrameCommitted
                Task { @MainActor in
                    handler(presentationTime)
                }
            }
        }
        if injectedFault == .afterSuccessfulFrameCount30,
           frameCount == 30,
           !injectedFaultTriggered {
            triggerInjectedWriterFault(point: .afterSuccessfulFrameCount30)
        }
    }

    private func triggerInjectedWriterFault(point: AcceptanceWriterFault) {
        injectedFaultTriggered = true
        acceptanceReporter?.record(event: "acceptance.writerFault.hit", fields: [
            "point": point.rawValue,
            "successfulFrameCount": String(frameCount)
        ])
        fail(CaptureError(
            code: "recording_writer_fault_injected",
            message: "录屏编码失败（验收注入）",
            detail: "point=\(point.rawValue) successfulFrameCount=\(frameCount)"
        ))
    }

    private func writerFailure(defaultCode: String, message: String) -> CaptureError {
        let underlying = assetWriter.error
        return CaptureError(
            code: Self.isDiskFull(underlying) ? "recording_disk_full" : defaultCode,
            message: Self.isDiskFull(underlying) ? "磁盘空间不足，录屏已安全停止" : message,
            detail: underlying?.localizedDescription
        )
    }

    private static func isDiskFull(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        return isDiskFull(error.userInfo[NSUnderlyingErrorKey] as? Error)
    }

    private func normalizedSampleBuffer(
        from sampleBuffer: CMSampleBuffer,
        firstPresentationTime: CMTime
    ) -> CMSampleBuffer? {
        var requiredCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &requiredCount
        )
        guard countStatus == noErr, requiredCount > 0 else { return nil }
        var timing = Array(repeating: CMSampleTimingInfo(), count: requiredCount)
        let fillStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: requiredCount,
            arrayToFill: &timing,
            entriesNeededOut: &requiredCount
        )
        guard fillStatus == noErr else { return nil }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(
                timing[index].presentationTimeStamp,
                firstPresentationTime
            )
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    firstPresentationTime
                )
            }
        }
        var normalized: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &normalized
        )
        return status == noErr ? normalized : nil
    }

    private func fail(_ error: CaptureError) {
        guard failure == nil else { return }
        failure = error
        logger.error("recording.writer.failed code=\(error.code, privacy: .public) detail=\(error.detail ?? "", privacy: .public)")
        let handler = onFailure
        Task { @MainActor in
            handler(error)
        }
    }

    private func metrics(failure overrideFailure: CaptureError? = nil) -> RecordingWriterMetrics {
        RecordingWriterMetrics(
            frameCount: frameCount,
            droppedFrameCount: droppedFrameCount,
            invalidTimestampCount: invalidTimestampCount,
            firstPresentationTime: firstPresentationTime,
            lastPresentationTime: lastPresentationTime,
            failure: overrideFailure ?? failure
        )
    }
}
