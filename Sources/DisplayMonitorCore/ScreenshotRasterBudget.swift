import Foundation

public enum ScreenshotRasterBudget {
    /// The current flat renderer owns a bitmap, image/encoding intermediates,
    /// and filter results. Reject before allocation, preserving the document.
    /// Larger documents use ScreenshotTiledRasterPlan rather than allocating
    /// this flat surface.
    public static func permits(width: Int, height: Int, maximumWorkingBytes: Int = 512 * 1_024 * 1_024) -> Bool {
        guard width > 0, height > 0, maximumWorkingBytes > 0 else { return false }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return false }
        let workingBytes = pixels.partialValue.multipliedReportingOverflow(by: 16)
        return !workingBytes.overflow && workingBytes.partialValue <= maximumWorkingBytes
    }
}

/// Conservative scratch accounting for full-width PNG bands. The caller must
/// render only `renderRect`; source image caches have their own independent
/// budget. Six RGBA surfaces cover the renderer, filters, CGImage snapshots and
/// encoder conversion; the fixed reserve covers zlib and scanline buffers.
public enum ScreenshotCanonicalRasterGrid {
    /// These are part of the raster contract, independent of export budget,
    /// requested band height and caller-provided halos. Quartz AA is sensitive
    /// to a bitmap's clipping extent; every output path uses the same grid.
    public static let tileWidth = 512
    public static let tileHeight = 128
    public static let halo = 2
    public static let cacheByteLimit = 2 * 1_024 * 1_024
    public static let workingReserveBytes = 8 * 1_024 * 1_024
}

public struct ScreenshotTiledRasterPlan: Equatable, Sendable {
    /// zlib/scanlines plus the canonical rasterizer's fixed scratch/cache.
    public static let fixedWorkingReserveBytes = 2 * 1_024 * 1_024 + ScreenshotCanonicalRasterGrid.workingReserveBytes
    public let width: Int
    public let height: Int
    public let bandHeight: Int
    public let haloRows: Int
    public let maximumWorkingBytes: Int
    public let estimatedWorkingBytes: Int
    public let maximumEncodedBytes: Int64

    public init(
        width: Int,
        height: Int,
        maximumWorkingBytes: Int = 64 * 1_024 * 1_024,
        haloRows: Int = 0,
        maximumOutputBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    ) throws {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              haloRows >= 0, maximumWorkingBytes > 0, maximumOutputBytes > 0 else {
            throw ScreenshotTiledRasterError.invalidDimensions
        }
        let reserve = Self.fixedWorkingReserveBytes
        let row = width.multipliedReportingOverflow(by: 24)
        let halo = haloRows.multipliedReportingOverflow(by: 2)
        guard !row.overflow, !halo.overflow, maximumWorkingBytes > reserve else {
            throw ScreenshotTiledRasterError.workingBudgetExceeded
        }
        let availableRows = (maximumWorkingBytes - reserve) / row.partialValue
        let neededHaloRows = min(height - 1, halo.partialValue)
        guard availableRows > neededHaloRows else {
            throw ScreenshotTiledRasterError.workingBudgetExceeded
        }
        let bandHeight = min(2_048, height, availableRows - neededHaloRows)
        let rawRow = Int64(width) * 4 + 1
        let raw = rawRow.multipliedReportingOverflow(by: Int64(height))
        guard !raw.overflow else { throw ScreenshotTiledRasterError.outputBudgetExceeded }
        // zlib's compressBound plus IDAT framing is smaller than this bound.
        let overhead = raw.partialValue / 50 + 1_024 * 1_024
        let encoded = raw.partialValue.addingReportingOverflow(overhead)
        guard !encoded.overflow, encoded.partialValue <= maximumOutputBytes else {
            throw ScreenshotTiledRasterError.outputBudgetExceeded
        }
        self.width = width
        self.height = height
        self.bandHeight = bandHeight
        self.haloRows = haloRows
        self.maximumWorkingBytes = maximumWorkingBytes
        self.estimatedWorkingBytes = min(height, bandHeight + neededHaloRows) * row.partialValue + reserve
        self.maximumEncodedBytes = encoded.partialValue
    }

    /// Coordinates use the document's top-left, original-pixel space.
    public func renderRect(forBandTop top: Int) -> CGRect {
        let start = max(0, top - min(top, haloRows))
        let coreBottom = min(height, top + bandHeight)
        let end = coreBottom + min(height - coreBottom, haloRows)
        return CGRect(x: 0, y: start, width: width, height: end - start)
    }
}

public enum ScreenshotTiledRasterError: LocalizedError {
    case invalidDimensions
    case workingBudgetExceeded
    case outputBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "图片尺寸无效，无法分块导出"
        case .workingBudgetExceeded: return "图片过宽或滤镜范围过大，超过分块内存预算；编辑内容仍保留"
        case .outputBudgetExceeded: return "图片超过导出文件预算；请缩小裁剪范围后重试"
        }
    }
}
