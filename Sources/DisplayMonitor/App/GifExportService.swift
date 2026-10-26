import AVFoundation
import CoreMedia
import DisplayMonitorCore
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Capture Extension only. The service is deliberately gated outside schema 8
/// so MP4 remains the primary recoverable recording artifact until the GIF
/// extension has its own evidence and release approval.
@MainActor
final class GifExportService {
    var onStatusMessage: ((String) -> Void)?

    private let artifactStore: ArtifactStore
    private let isExtensionEnabled: () -> Bool
    private let recordingBusy: () -> Bool
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "GifExport")
    private var currentRenderTask: Task<GifRenderResult, Error>?
    private var activeSession: ArtifactSession?
    private var heartbeatTask: Task<Void, Never>?
    private var cancellationRequested = false
    private var isPreparingExport = false
    private var shutdownRequested = false

    init(
        artifactStore: ArtifactStore,
        isExtensionEnabled: @escaping () -> Bool,
        recordingBusy: @escaping () -> Bool
    ) {
        self.artifactStore = artifactStore
        self.isExtensionEnabled = isExtensionEnabled
        self.recordingBusy = recordingBusy
    }

    var isEnabled: Bool { !shutdownRequested && isExtensionEnabled() }
    var isExporting: Bool { isPreparingExport || activeSession != nil }

    func export(
        from source: ArtifactManifest,
        options: GifExportOptions = .default
    ) async throws -> ArtifactManifest {
        try Task.checkCancellation()
        guard !shutdownRequested else { throw CancellationError() }
        guard isEnabled else {
            throw CaptureError(
                code: "gif_extension_not_enabled",
                message: "GIF Capture Extension 尚未开门"
            )
        }
        guard source.kind == .recording,
              source.status == .completed,
              FileManager.default.fileExists(atPath: source.canonicalURL.path) else {
            throw CaptureError(
                code: "gif_source_not_completed_mp4",
                message: "只能从已完成的 MP4 录屏导出 GIF"
            )
        }
        guard !isPreparingExport, activeSession == nil, currentRenderTask == nil else {
            throw CaptureError(code: "gif_export_busy", message: "已有 GIF 导出任务正在运行")
        }

        isPreparingExport = true
        cancellationRequested = false
        defer { isPreparingExport = false }

        try await waitForRecordingToBecomeIdle()
        try checkCancellation()

        let operationID = UUID()
        let session = try await artifactStore.beginArtifact(
            kind: .gif,
            fileExtension: "gif",
            sourceArtifactID: source.id,
            dimensions: source.dimensions,
            displayID: source.displayID,
            captureRegion: source.captureRegion,
            operationID: operationID
        )
        activeSession = session
        beginHeartbeat(for: session)
        defer {
            if activeSession?.manifest.id == session.manifest.id {
                heartbeatTask?.cancel()
                heartbeatTask = nil
                activeSession = nil
                cancellationRequested = false
            }
        }
        do {
            try checkCancellation()
            let sourceDuration = try await sourceDuration(for: source.canonicalURL)
            try checkCancellation()
            let clip = try options.resolve(totalDuration: sourceDuration)
            let renderTask = Task.detached(priority: .utility) {
                try GifRenderer.render(
                    sourceURL: source.canonicalURL,
                    destinationURL: session.manifest.temporaryURL,
                    startSeconds: clip.startSeconds,
                    duration: clip.durationSeconds,
                    sourceSize: source.dimensions,
                    frameRate: options.frameRate,
                    maximumWidth: options.maximumWidth
                )
            }
            currentRenderTask = renderTask
            report("GIF 导出已开始：\(String(format: "%.1f", clip.durationSeconds)) 秒、\(Int(options.frameRate)) FPS")
            let rendered = try await withTaskCancellationHandler(operation: {
                try await renderTask.value
            }, onCancel: {
                renderTask.cancel()
            })
            currentRenderTask = nil
            try checkCancellation()

            _ = try await artifactStore.updateArtifactMetrics(
                for: session,
                durationSeconds: rendered.durationSeconds,
                frameCount: rendered.frameCount,
                droppedFrameCount: nil
            )
            try checkCancellation()
            let artifact = try await artifactStore.finalizeTemporary(for: session)
            report("GIF 导出已完成")
            return artifact
        } catch is CancellationError {
            currentRenderTask?.cancel()
            currentRenderTask = nil
            _ = try? await artifactStore.markFailed(
                for: session,
                error: CaptureError(code: "gif_export_cancelled", message: "GIF 导出已取消")
            )
            report("GIF 导出已取消，MP4 未受影响")
            throw CaptureError(code: "gif_export_cancelled", message: "GIF 导出已取消")
        } catch {
            currentRenderTask?.cancel()
            currentRenderTask = nil
            let captureError = error as? CaptureError ?? CaptureError(
                code: "gif_export_failed",
                message: "GIF 导出失败",
                detail: error.localizedDescription
            )
            _ = try? await artifactStore.markFailed(for: session, error: captureError)
            report("GIF 导出失败：\(captureError.description)")
            throw captureError
        }
    }

    func cancelCurrentExport() {
        cancellationRequested = true
        currentRenderTask?.cancel()
    }

    func beginTermination() {
        shutdownRequested = true
        cancelCurrentExport()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !shutdownRequested, !cancellationRequested else {
            throw CancellationError()
        }
    }

    private func beginHeartbeat(for session: ArtifactSession) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.activeSession?.manifest.id == session.manifest.id else {
                    return
                }
                try? await self.artifactStore.touchLock(session.lockToken)
            }
        }
    }

    private func waitForRecordingToBecomeIdle() async throws {
        var announced = false
        while recordingBusy() {
            if !announced {
                report("录屏仍在运行或收尾，GIF 导出已排队")
                announced = true
            }
            try checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func sourceDuration(for url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw CaptureError(code: "gif_source_duration_invalid", message: "MP4 时长无效，无法导出 GIF")
        }
        return seconds
    }

    private func report(_ message: String) {
        logger.info("gif.message \(message, privacy: .public)")
        onStatusMessage?(message)
    }
}

struct GifExportOptions: Sendable, Equatable {
    static let `default` = GifExportOptions()

    var startSeconds: Double?
    var endSeconds: Double?
    var frameRate: Double
    var maximumWidth: Int

    init(
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        frameRate: Double = 10,
        maximumWidth: Int = 1_280
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.frameRate = frameRate
        self.maximumWidth = maximumWidth
    }

    func resolve(totalDuration: Double) throws -> GifClip {
        guard totalDuration.isFinite, totalDuration > 0,
              startSeconds?.isFinite != false, endSeconds?.isFinite != false,
              frameRate.isFinite, frameRate > 0, frameRate <= 30,
              maximumWidth >= 160 else {
            throw CaptureError(code: "gif_export_options_invalid", message: "GIF 导出范围或预设无效")
        }
        let start = min(max(0, startSeconds ?? 0), totalDuration)
        let requestedEnd = endSeconds ?? totalDuration
        let end = min(max(start, requestedEnd), totalDuration)
        guard end > start, frameRate > 0, frameRate <= 30, maximumWidth >= 160 else {
            throw CaptureError(code: "gif_export_options_invalid", message: "GIF 导出范围或预设无效")
        }
        let duration = min(end - start, 30)
        guard duration > 0 else {
            throw CaptureError(code: "gif_export_duration_invalid", message: "GIF 导出时长无效")
        }
        return GifClip(startSeconds: start, durationSeconds: duration)
    }
}

struct GifClip: Sendable {
    var startSeconds: Double
    var durationSeconds: Double
}

struct GifRenderResult: Sendable {
    var durationSeconds: Double
    var frameCount: Int
}

private enum GifRendererError: LocalizedError {
    case destinationUnavailable
    case frameUnavailable
    case finalizeFailed
    case outputTooLarge
    case timingMismatch

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable: return "无法创建 GIF 编码器"
        case .frameUnavailable: return "无法从 MP4 解码视频帧"
        case .finalizeFailed: return "GIF 编码未完成"
        case .outputTooLarge: return "GIF 文件超过 128 MiB 限制"
        case .timingMismatch: return "GIF 编码后的帧数或播放时长不一致"
        }
    }
}

/// GIF stores delays as hundredths of a second. Quantize the total once and
/// distribute those ticks so every encoded frame has a positive delay and the
/// manifest can describe the duration actually written to the file.
struct GifFrameSamplingPlan: Sendable {
    let sampleTimes: [Double]
    let frameDelays: [Double]
    var frameCount: Int { sampleTimes.count }
    var durationSeconds: Double { frameDelays.reduce(0, +) }

    init(startSeconds: Double, duration: Double, frameRate: Double, maximumFrames: Int = 300) throws {
        guard startSeconds.isFinite, startSeconds >= 0,
              duration.isFinite, duration > 0, duration <= 30,
              frameRate.isFinite, frameRate > 0, frameRate <= 30,
              maximumFrames > 0,
              (startSeconds + duration).isFinite, startSeconds + duration > startSeconds else {
            throw CaptureError(code: "gif_export_options_invalid", message: "GIF 导出范围或预设无效")
        }
        let totalTicks = max(1, Int((duration * 100).rounded()))
        let count = min(300, maximumFrames, totalTicks, max(1, Int((duration * frameRate).rounded(.up))))
        sampleTimes = (0..<count).map { startSeconds + duration * Double($0) / Double(count) }
        frameDelays = (0..<count).map { index in
            let firstTick = Int((Double(index) * Double(totalTicks) / Double(count)).rounded())
            let nextTick = Int((Double(index + 1) * Double(totalTicks) / Double(count)).rounded())
            return Double(nextTick - firstTick) / 100
        }
    }
}

enum GifRenderer {
    static func render(
        sourceURL: URL,
        destinationURL: URL,
        startSeconds: Double,
        duration: Double,
        sourceSize: PixelSize?,
        frameRate: Double = 10,
        maximumFrames: Int = 300,
        maximumWidth: Int = 1_280,
        maximumOutputBytes: Int64 = 128 * 1_024 * 1_024
    ) throws -> GifRenderResult {
        let plan = try GifFrameSamplingPlan(
            startSeconds: startSeconds, duration: duration,
            frameRate: frameRate, maximumFrames: maximumFrames
        )
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // The default tolerances may return a nearby keyframe repeatedly.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let sourceSize, sourceSize.width > maximumWidth {
            let scale = Double(maximumWidth) / Double(sourceSize.width)
            generator.maximumSize = CGSize(
                width: maximumWidth,
                height: max(2, Int((Double(sourceSize.height) * scale).rounded()))
            )
        }
        return try encode(
            destinationURL: destinationURL,
            plan: plan,
            maximumOutputBytes: maximumOutputBytes
        ) { seconds in
            var actualTime = CMTime.invalid
            do {
                return try generator.copyCGImage(
                    at: CMTime(seconds: seconds, preferredTimescale: 60_000),
                    actualTime: &actualTime
                )
            } catch {
                throw GifRendererError.frameUnavailable
            }
        }
    }

    static func encode(
        destinationURL: URL,
        plan: GifFrameSamplingPlan,
        maximumOutputBytes: Int64 = 128 * 1_024 * 1_024,
        frameAt: (Double) throws -> CGImage
    ) throws -> GifRenderResult {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destinationURL)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destinationURL) }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            plan.frameCount,
            nil
        ) else {
            throw GifRendererError.destinationUnavailable
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for index in 0..<plan.frameCount {
            try Task.checkCancellation()
            let image = try frameAt(plan.sampleTimes[index])
            let delay = plan.frameDelays[index]
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ] as CFDictionary)
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw GifRendererError.finalizeFailed }
        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        if let byteCount = values.fileSize, Int64(byteCount) > maximumOutputBytes {
            throw GifRendererError.outputTooLarge
        }
        guard let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
              CGImageSourceGetCount(source) == plan.frameCount else {
            throw GifRendererError.timingMismatch
        }
        var encodedDuration = 0.0
        for index in 0..<plan.frameCount {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            guard let delay, delay.isFinite, delay > 0,
                  abs(delay - plan.frameDelays[index]) < 0.000_001 else {
                throw GifRendererError.timingMismatch
            }
            encodedDuration += delay
        }
        guard abs(encodedDuration - plan.durationSeconds) < 0.000_001 else {
            throw GifRendererError.timingMismatch
        }
        completed = true
        return GifRenderResult(durationSeconds: encodedDuration, frameCount: plan.frameCount)
    }
}
