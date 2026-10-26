import AVFoundation
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import OSLog

@MainActor
final class V1ACaptureProbe {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "CaptureProbe")

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--v1a-capture-probe") else {
            return
        }

        let probe = V1ACaptureProbe()
        do {
            let result = try await probe.run()
            guard result.durationSeconds >= 9.5 else {
                throw CaptureError(
                    code: "recording_duration_too_short",
                    message: "录屏输出短于 10 秒",
                    detail: "duration=\(result.durationSeconds)"
                )
            }
            probe.logger.info("v1a.captureProbe=PASS screenshot=\(result.screenshotURL.path, privacy: .public) recording=\(result.recordingURL.path, privacy: .public) duration=\(result.durationSeconds, privacy: .public) frames=\(result.frameCount, privacy: .public) dropped=\(result.droppedFrameCount, privacy: .public)")
            print("V1A_CAPTURE_PROBE=PASS screenshot=\(result.screenshotURL.path) recording=\(result.recordingURL.path) duration=\(result.durationSeconds) frames=\(result.frameCount) dropped=\(result.droppedFrameCount)")
        } catch {
            probe.logger.error("v1a.captureProbe=FAIL error=\(String(describing: error), privacy: .public)")
            print("V1A_CAPTURE_PROBE=FAIL error=\(error)")
        }
        NSApp.terminate(nil)
    }

    private struct Result {
        let screenshotURL: URL
        let recordingURL: URL
        let durationSeconds: Double
        let frameCount: Int
        let droppedFrameCount: Int
    }

    private func run() async throws -> Result {
        guard #available(macOS 14.0, *) else {
            throw CaptureError(
                code: "screenshot_manager_unavailable",
                message: "当前 macOS 不支持 SCScreenshotManager 诊断路径"
            )
        }

        let content = try await shareableContentWithRetry()
        let requestedMainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == requestedMainDisplayID })
            ?? content.displays.first else {
            logger.error(
                "v1a.captureProbe.displayMissing requestedMainDisplayID=\(requestedMainDisplayID, privacy: .public) shareableDisplayIDs=\(content.displays.map(\.displayID), privacy: .public)"
            )
            throw CaptureError(code: "probe_display_missing", message: "找不到可共享显示器")
        }
        let displayID = display.displayID
        if displayID != requestedMainDisplayID {
            logger.warning(
                "v1a.captureProbe.displayFallback requestedMainDisplayID=\(requestedMainDisplayID, privacy: .public) selectedDisplayID=\(displayID, privacy: .public)"
            )
        }

        let outputDirectory = try makeOutputDirectory()
        let screenshotURL = outputDirectory.appendingPathComponent("region-screenshot.png")
        let recordingURL = outputDirectory.appendingPathComponent("region-recording.mp4")
        let region = sourceRegion(for: displayID)
        let configuration = makeConfiguration(display: display, region: region)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let image = try await captureImage(
            filter: filter,
            configuration: configuration
        )
        try writePNG(image, to: screenshotURL)

        let recording = try await record(
            filter: filter,
            configuration: configuration,
            to: recordingURL
        )
        return Result(
            screenshotURL: screenshotURL,
            recordingURL: recordingURL,
            durationSeconds: recording.durationSeconds,
            frameCount: recording.frameCount,
            droppedFrameCount: recording.droppedFrameCount
        )
    }

    @available(macOS 14.0, *)
    private func shareableContentWithRetry() async throws -> SCShareableContent {
        var lastContent: SCShareableContent?
        for attempt in 1...3 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            lastContent = content
            if !content.displays.isEmpty {
                logger.info(
                    "v1a.captureProbe.shareableContent attempt=\(attempt, privacy: .public) displayIDs=\(content.displays.map(\.displayID), privacy: .public)"
                )
                return content
            }
            logger.warning(
                "v1a.captureProbe.shareableContent.empty attempt=\(attempt, privacy: .public)"
            )
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let lastContent {
            return lastContent
        }
        return try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
    }

    @available(macOS 14.0, *)
    private func captureImage(
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
                        throwing: CaptureError(
                            code: "screenshot_empty",
                            message: "截图返回空图像"
                        )
                    )
                }
            }
        }
    }

    private func record(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        to url: URL
    ) async throws -> ProbeRecordingResult {
        let writer = try ProbeRecordingWriter(
            outputURL: url,
            width: configuration.width,
            height: configuration.height
        )
        let sampleQueue = DispatchQueue(label: "com.hanshuai.DisplayMonitor.v1a.probe.samples")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
            // SCStream can take time to deliver its first frame after the
            // signed app starts. Capture beyond the requested 10-second
            // evidence window so the encoded file, rather than only the
            // wall-clock request, contains at least 10 seconds of real data.
            try await Task.sleep(nanoseconds: 12_000_000_000)
            try await stream.stopCapture()
            try stream.removeStreamOutput(writer, type: .screen)
            return try await writer.finish(on: sampleQueue)
        } catch {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(writer, type: .screen)
            throw error
        }
    }

    private func makeConfiguration(
        display: SCDisplay,
        region: CGRect
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = min(960, max(2, display.width / 2))
        configuration.height = min(540, max(2, display.height / 2))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.sourceRect = region
        return configuration
    }

    private func sourceRegion(for displayID: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(displayID)
        return CGRect(
            x: bounds.width * 0.25,
            y: bounds.height * 0.25,
            width: bounds.width * 0.5,
            height: bounds.height * 0.5
        )
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
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
    }

    private func makeOutputDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent(
            "DisplayMonitor-V1A-CaptureProbe-\(Int(Date().timeIntervalSince1970 * 1000))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct ProbeRecordingResult: Sendable {
    let durationSeconds: Double
    let frameCount: Int
    let droppedFrameCount: Int
}

private final class ProbeRecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var didStart = false
    private var firstPresentationTimeStamp: CMTime?
    private var lastPresentationTimeStamp: CMTime?
    private var frameCount = 0
    private var droppedFrameCount = 0

    init(outputURL: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError(code: "recording_writer_unavailable", message: "无法配置 MP4 writer")
        }
        writer.add(input)
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(imageBuffer) > 0,
              CVPixelBufferGetHeight(imageBuffer) > 0 else {
            return
        }

        if !didStart {
            guard writer.startWriting() else {
                return
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            firstPresentationTimeStamp = timestamp
            writer.startSession(atSourceTime: timestamp)
            didStart = true
        }
        lastPresentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard input.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return
        }
        if input.append(sampleBuffer) {
            frameCount += 1
        }
    }

    func finish(on queue: DispatchQueue) async throws -> ProbeRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.didStart else {
                    continuation.resume(
                        throwing: CaptureError(
                            code: "recording_no_frames",
                            message: "10 秒录屏没有收到有效帧"
                        )
                    )
                    return
                }
                let minimumEnd = CMTimeAdd(
                    self.firstPresentationTimeStamp ?? .zero,
                    CMTime(seconds: 10, preferredTimescale: 600)
                )
                let lastTimestamp = self.lastPresentationTimeStamp ?? minimumEnd
                let endTimestamp = CMTimeCompare(lastTimestamp, minimumEnd) > 0 ? lastTimestamp : minimumEnd
                self.writer.endSession(atSourceTime: endTimestamp)
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        let duration = CMTimeGetSeconds(
                            CMTimeSubtract(
                                endTimestamp,
                                self.firstPresentationTimeStamp ?? .zero
                            )
                        )
                        continuation.resume(
                            returning: ProbeRecordingResult(
                                durationSeconds: duration,
                                frameCount: self.frameCount,
                                droppedFrameCount: self.droppedFrameCount
                            )
                        )
                    } else {
                        continuation.resume(
                            throwing: self.writer.error ?? CaptureError(
                                code: "recording_finalize_failed",
                                message: "MP4 finalize 失败"
                            )
                        )
                    }
                }
            }
        }
    }
}
