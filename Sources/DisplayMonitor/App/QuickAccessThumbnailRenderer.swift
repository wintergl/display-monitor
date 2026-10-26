import CoreGraphics
import Foundation
import ImageIO

/// Ephemeral presentation rasters. The header is sampled from original pixels,
/// never magnified from a whole-document overview. All decoding happens on a
/// worker; neither canonical files nor artifact manifests are modified.
enum QuickAccessThumbnailRenderer {
    struct Result: @unchecked Sendable {
        let main: CGImage
        let overview: CGImage?
        let sourceHeadRect: CGRect
    }

    static let maximumHeadWidth = 432
    static let maximumHeadHeight = 280

    static func render(canonicalURL: URL, boundedPreviewURL: URL?, isLong: Bool) throws -> Result {
        try ScreenshotRasterWorkGate.shared.withPermit {
            try Task.checkCancellation()
            return try autoreleasepool {
                let url = FileManager.default.fileExists(atPath: canonicalURL.path) ? canonicalURL : boundedPreviewURL
                guard let url,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let original = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    throw ThumbnailError.unavailable
                }
                let rasterSource = ScreenshotRasterSource(image: original, sourceURL: url)
                let image = try rasterSource.imageForRendering()
                defer { rasterSource.releaseReadPages() }
                try Task.checkCancellation()
                let headHeight = isLong ? min(image.height, max(1, Int((Double(image.width) * Double(maximumHeadHeight) / Double(maximumHeadWidth)).rounded(.down)))) : image.height
                let headRect = CGRect(x: 0, y: 0, width: image.width, height: headHeight)
                guard let cropped = image.cropping(to: headRect) else { throw ThumbnailError.unavailable }
                let head = try raster(cropped, maximumWidth: maximumHeadWidth, maximumHeight: maximumHeadHeight)
                try Task.checkCancellation()
                let overview: CGImage?
                if isLong {
                    // The whole-document strip is intentionally small. Its only
                    // role is showing extent; legible content comes from head.
                    overview = try raster(image, maximumWidth: 48, maximumHeight: 280)
                } else { overview = nil }
                return Result(main: head, overview: overview, sourceHeadRect: headRect)
            }
        }
    }

    private static func raster(_ image: CGImage, maximumWidth: Int, maximumHeight: Int) throws -> CGImage {
        let scale = min(1, Double(maximumWidth) / Double(image.width), Double(maximumHeight) / Double(image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ThumbnailError.unavailable
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ThumbnailError.unavailable }
        return result
    }

    private enum ThumbnailError: Error { case unavailable }
}
