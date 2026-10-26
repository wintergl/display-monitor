import CoreImage
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import ScreenCaptureKit

/// Converts the screenshot API's in-memory image to the existing video-layer
/// format. Images never go to disk; a pool reuses the preview-sized surfaces.
@MainActor
final class LocalPreviewSampleConverter {
    private let pool: CVPixelBufferPool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw CaptureError(code: "local_preview_invalid_size", message: "本地预览尺寸无效")
        }
        self.width = width
        self.height = height
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw CaptureError(code: "local_preview_buffer_pool_failed", message: "无法创建本地预览缓冲")
        }
        self.pool = pool
    }

    func sample(from image: CGImage) throws -> CMSampleBuffer {
        guard image.width == width, image.height == height else {
            throw CaptureError(code: "local_preview_invalid_frame", message: "本地预览画面尺寸不符")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            throw CaptureError(code: "local_preview_buffer_failed", message: "无法分配本地预览缓冲")
        }
        context.render(CIImage(cgImage: image), to: pixelBuffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                          formatDescriptionOut: &format) == noErr,
              let format else {
            throw CaptureError(code: "local_preview_format_failed", message: "无法创建本地预览格式")
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else {
            throw CaptureError(code: "local_preview_sample_failed", message: "无法创建本地预览帧")
        }
        return sample
    }
}

@available(macOS 14.0, *)
@MainActor
final class LocalPreviewScreenshotSource {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let converter: LocalPreviewSampleConverter

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        self.filter = filter
        self.configuration = configuration
        converter = try LocalPreviewSampleConverter(width: configuration.width, height: configuration.height)
    }

    func capture() async throws -> CMSampleBuffer {
        if #available(macOS 26.0, *) {
            let screenshot = Self.screenshotConfiguration(from: configuration)
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: screenshot)
            guard let image = output.sdrImage else {
                throw CaptureError(code: "local_preview_image_missing", message: "系统没有返回本地预览画面")
            }
            return try converter.sample(from: image)
        }
        return try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
    }

    @available(macOS 26.0, *)
    static func screenshotConfiguration(from configuration: SCStreamConfiguration) -> SCScreenshotConfiguration {
        let screenshot = SCScreenshotConfiguration()
        screenshot.width = configuration.width
        screenshot.height = configuration.height
        if !configuration.sourceRect.isEmpty { screenshot.sourceRect = configuration.sourceRect }
        screenshot.showsCursor = configuration.showsCursor
        screenshot.displayIntent = .local
        screenshot.dynamicRange = .sdr
        screenshot.fileURL = nil
        return screenshot
    }
}
