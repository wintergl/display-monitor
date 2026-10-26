import CoreGraphics
import DisplayMonitorCore
import Foundation
import zlib

/// Streams original-resolution bands to a PNG file. No full output bitmap or
/// encoded heap Data is created here. `renderBand` must honor its input rect
/// (including halo) and return that exact original-pixel size, top edge first.
enum ScreenshotTiledPNGExporter {
    @discardableResult
    static func write(
        width: Int,
        height: Int,
        destination: URL,
        maximumWorkingBytes: Int = 64 * 1_024 * 1_024,
        haloRows: Int = 0,
        maximumOutputBytes: Int64 = 16 * 1_024 * 1_024 * 1_024,
        availableDiskBytes: Int64? = nil,
        isCancelled: () -> Bool = { Task<Never, Never>.isCancelled },
        renderBand: (CGRect) throws -> CGImage
    ) throws -> URL {
        let plan = try ScreenshotTiledRasterPlan(
            width: width, height: height,
            maximumWorkingBytes: maximumWorkingBytes,
            haloRows: haloRows, maximumOutputBytes: maximumOutputBytes
        )
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw ScreenshotTiledPNGError.destinationExists
        }
        let directory = destination.deletingLastPathComponent()
        let free = availableDiskBytes ?? availableBytes(at: directory)
        let diskReserve: Int64 = 64 * 1_024 * 1_024
        if free < diskReserve || plan.maximumEncodedBytes > free - diskReserve {
            throw ScreenshotTiledPNGError.insufficientDiskSpace
        }
        if isCancelled() { throw CancellationError() }
        let staging = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        let encoder = try ScreenshotPNGStreamEncoder(
            destination: staging, width: width, height: height,
            maximumBytes: plan.maximumEncodedBytes
        )
        var published = false
        defer {
            encoder.abort()
            if !published { try? manager.removeItem(at: staging) }
        }
        for top in stride(from: 0, to: height, by: plan.bandHeight) {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let rect = plan.renderRect(forBandTop: top)
                let image = try renderBand(rect)
                guard image.width == width, image.height == Int(rect.height) else {
                    throw ScreenshotTiledPNGError.invalidBandDimensions
                }
                let coreHeight = min(plan.bandHeight, height - top)
                try encoder.append(
                    image: image, firstRow: top - Int(rect.minY),
                    rowCount: coreHeight, isCancelled: isCancelled
                )
            }
        }
        if isCancelled() { throw CancellationError() }
        try encoder.finish()
        if isCancelled() { throw CancellationError() }
        // The destination is a new revision/temp output. Never replace a source
        // or an earlier complete export, even if one appeared during rendering.
        try manager.moveItem(at: staging, to: destination)
        published = true
        return destination
    }

    private static func availableBytes(at directory: URL) -> Int64 {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        return ArtifactDiskCapacity.availableBytes(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            ordinary: values?.volumeAvailableCapacity.map(Int64.init)
        )
    }
}

enum ScreenshotTiledPNGError: LocalizedError {
    case destinationExists
    case insufficientDiskSpace
    case cannotCreateFile
    case invalidBandDimensions
    case cannotRenderBand
    case encodingFailed(Int32)
    case incompleteRows
    case outputBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .destinationExists: return "导出目标已存在，原文件未修改"
        case .insufficientDiskSpace: return "可用磁盘空间不足，编辑内容仍保留"
        case .cannotCreateFile: return "无法创建分块导出临时文件"
        case .invalidBandDimensions: return "分块渲染尺寸不符，已停止导出"
        case .cannotRenderBand: return "无法渲染图片分块，编辑内容仍保留"
        case .encodingFailed(let code): return "PNG 分块压缩失败（\(code)），编辑内容仍保留"
        case .incompleteRows: return "PNG 分块数据不完整，未生成导出文件"
        case .outputBudgetExceeded: return "PNG 输出超过文件预算，已停止导出"
        }
    }
}

private final class ScreenshotPNGStreamEncoder {
    private let handle: FileHandle
    private let width: Int
    private let expectedRows: Int
    private let maximumBytes: Int64
    private let compressor: ScreenshotZlibStream
    private var writtenBytes: Int64 = 0
    private var writtenRows = 0
    private var closed = false

    init(destination: URL, width: Int, height: Int, maximumBytes: Int64) throws {
        self.width = width
        self.expectedRows = height
        self.maximumBytes = maximumBytes
        compressor = try ScreenshotZlibStream()
        guard FileManager.default.createFile(
            atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw ScreenshotTiledPNGError.cannotCreateFile }
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        do {
            try write(Data([137, 80, 78, 71, 13, 10, 26, 10]))
            var header = uint32Data(UInt32(width))
            header.append(uint32Data(UInt32(height)))
            header.append(contentsOf: [8, 6, 0, 0, 0])
            try writeChunk(type: "IHDR", data: header)
            try writeChunk(type: "sRGB", data: Data([0]))
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    deinit { if !closed { try? handle.close() } }

    func append(image: CGImage, firstRow: Int, rowCount: Int, isCancelled: () -> Bool) throws {
        guard !closed, firstRow >= 0, rowCount > 0,
              firstRow + rowCount <= image.height,
              writtenRows + rowCount <= expectedRows else {
            throw ScreenshotTiledPNGError.incompleteRows
        }
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ), let raw = context.data else { throw ScreenshotTiledPNGError.cannotRenderBand }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        let pixels = raw.assumingMemoryBound(to: UInt8.self)
        var scanline = Data(repeating: 0, count: bytesPerRow + 1)
        for row in firstRow..<(firstRow + rowCount) {
            if isCancelled() { throw CancellationError() }
            scanline.withUnsafeMutableBytes { output in
                let destination = output.baseAddress!.assumingMemoryBound(to: UInt8.self)
                destination[0] = 0 // PNG filter None; zlib compresses across rows/bands.
                let source = pixels.advanced(by: row * bytesPerRow)
                for x in stride(from: 0, to: bytesPerRow, by: 4) {
                    let alpha = Int(source[x + 3])
                    destination[x + 4] = UInt8(alpha)
                    // PNG stores unassociated alpha. CGContext produces
                    // premultiplied RGBA, so undo it before writing each row.
                    if alpha == 255 {
                        destination[x + 1] = source[x]
                        destination[x + 2] = source[x + 1]
                        destination[x + 3] = source[x + 2]
                    } else if alpha == 0 {
                        destination[x + 1] = 0
                        destination[x + 2] = 0
                        destination[x + 3] = 0
                    } else {
                        for channel in 0..<3 {
                            destination[x + channel + 1] = UInt8(min(255, (Int(source[x + channel]) * 255 + alpha / 2) / alpha))
                        }
                    }
                }
            }
            try compressor.process(scanline, final: false) { try writeChunk(type: "IDAT", data: $0) }
            writtenRows += 1
        }
    }

    func finish() throws {
        guard !closed, writtenRows == expectedRows else { throw ScreenshotTiledPNGError.incompleteRows }
        try compressor.process(Data(), final: true) { try writeChunk(type: "IDAT", data: $0) }
        try writeChunk(type: "IEND", data: Data())
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    func abort() {
        if !closed { try? handle.close(); closed = true }
    }

    private func writeChunk(type: String, data: Data) throws {
        let typeData = Data(type.utf8)
        var crc = uLong(0)
        crc = typeData.withUnsafeBytes { zlib.crc32(crc, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
        if !data.isEmpty {
            crc = data.withUnsafeBytes { zlib.crc32(crc, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
        }
        try write(uint32Data(UInt32(data.count)))
        try write(typeData)
        try write(data)
        try write(uint32Data(UInt32(truncatingIfNeeded: crc)))
    }

    private func uint32Data(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private func write(_ data: Data) throws {
        guard Int64(data.count) <= maximumBytes - writtenBytes else {
            throw ScreenshotTiledPNGError.outputBudgetExceeded
        }
        try handle.write(contentsOf: data)
        writtenBytes += Int64(data.count)
    }
}

/// Uses zlib's wrapped DEFLATE stream (not Compression's raw DEFLATE). PNG
/// requires this wrapper and its Adler checksum, including a completed trailer.
private final class ScreenshotZlibStream {
    private var stream = z_stream()
    private var ended = false
    private var output = [UInt8](repeating: 0, count: 64 * 1_024)

    init() throws {
        let result = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { throw ScreenshotTiledPNGError.encodingFailed(result) }
    }

    deinit { deflateEnd(&stream) }

    func process(_ input: Data, final: Bool, emit: (Data) throws -> Void) throws {
        guard !ended else { throw ScreenshotTiledPNGError.encodingFailed(Z_STREAM_ERROR) }
        try input.withUnsafeBytes { source in
            stream.next_in = source.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
            stream.avail_in = uInt(source.count)
            defer { stream.next_in = nil; stream.avail_in = 0; stream.next_out = nil; stream.avail_out = 0 }
            repeat {
                let capacity = 64 * 1_024
                let result = output.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress!
                    stream.avail_out = uInt(capacity)
                    return zlib.deflate(&stream, final ? Z_FINISH : Z_NO_FLUSH)
                }
                if !final, result == Z_BUF_ERROR, stream.avail_in == 0 { break }
                guard result == Z_OK || (final && result == Z_STREAM_END) else {
                    throw ScreenshotTiledPNGError.encodingFailed(result)
                }
                let count = capacity - Int(stream.avail_out)
                if count > 0 { try emit(Data(output[0..<count])) }
                if result == Z_STREAM_END { ended = true; break }
            } while stream.avail_in > 0 || stream.avail_out == 0 || final
        }
    }
}
