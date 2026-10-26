import CoreGraphics
import Darwin
import Foundation
import zlib

/// A shared immutable source for preview and export workers. Supported PNGs
/// are decoded once, row by row, into a private file and then mapped read-only.
/// No decoded full-image heap buffer is created. File-backed pages and any
/// CoreGraphics internal caches still count towards the process's real RSS.
final class ScreenshotRasterSource: @unchecked Sendable {
    enum Strategy: Equatable, Sendable {
        case originalImage
        case mappedPNG
        case originalUnsupported(reason: String)
    }

    enum SourceError: LocalizedError {
        case malformed(String)
        case dimensionMismatch
        case tooLarge
        case insufficientDiskSpace
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let reason): return "PNG 像素源校验失败：\(reason)"
            case .dimensionMismatch: return "PNG 尺寸与截图元数据不一致"
            case .tooLarge: return "截图超过 2 亿像素或单边 120000 像素的处理范围"
            case .insufficientDiskSpace: return "磁盘空间不足，无法准备截图像素缓存"
            case .storage(let reason): return "截图像素缓存失败：\(reason)"
            }
        }
    }

    private let original: CGImage
    private let sourceURL: URL?
    private let temporaryDirectory: URL
    private let lock = NSLock()
    private var preparedImage: CGImage?
    private var preparationError: Error?
    private var preparationFinished = false
    private var currentStrategy: Strategy = .originalImage
    private var mappedStorage: MappedStorage?
    var strategy: Strategy { lock.withLock { currentStrategy } }
    /// Diagnostic path only. The file is unlinked when its final CGDataProvider
    /// reference is released, not merely when this source object goes away.
    var mappedFileURL: URL? { lock.withLock { mappedStorage?.url } }

    init(image: CGImage, sourceURL: URL?, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        original = image
        self.sourceURL = sourceURL
        self.temporaryDirectory = temporaryDirectory
    }

    /// Synchronous and potentially expensive. Invoke only from a background
    /// render worker; all sources share the same raster permit.
    func imageForRendering() throws -> CGImage {
        try ScreenshotRasterWorkGate.shared.withPermit {
            try lock.withLock {
                if preparationFinished {
                    if let preparationError { throw preparationError }
                    return preparedImage ?? original
                }
                do {
                    guard let sourceURL else {
                        preparationFinished = true
                        return original
                    }
                    let decoder = try PNGDecoder(url: sourceURL, image: original, directory: temporaryDirectory)
                    switch try decoder.prepare() {
                    case .unsupported(let reason):
                        currentStrategy = .originalUnsupported(reason: reason)
                        preparedImage = original
                    case .mapped(let storage):
                        let info = Unmanaged.passRetained(storage).toOpaque()
                        guard let provider = CGDataProvider(
                            dataInfo: info, data: storage.address, size: storage.byteCount,
                            releaseData: { info, _, _ in
                                if let info { Unmanaged<MappedStorage>.fromOpaque(info).release() }
                            }
                        ) else {
                            Unmanaged<MappedStorage>.fromOpaque(info).release()
                            throw SourceError.storage("无法创建文件映射像素提供器")
                        }
                        let space = original.colorSpace?.model == .rgb
                            ? original.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
                        guard let image = CGImage(
                            width: original.width, height: original.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: original.width * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                                | CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: original.renderingIntent
                        ) else { throw SourceError.storage("无法创建映射截图") }
                        mappedStorage = storage
                        preparedImage = image
                        currentStrategy = .mappedPNG
                    }
                    preparationFinished = true
                    return preparedImage ?? original
                } catch {
                    // Invalid image contents are permanent for this immutable
                    // source. Disk/permission/temporary I/O errors may recover
                    // after an explicit user save retry; do not poison the
                    // editor's shared source object for the rest of its life.
                    if let sourceError = error as? SourceError {
                        switch sourceError {
                        case .malformed, .dimensionMismatch, .tooLarge:
                            preparationFinished = true
                            preparationError = error
                        case .insufficientDiskSpace, .storage:
                            preparationFinished = false
                            preparationError = nil
                        }
                    } else {
                        preparationFinished = false
                        preparationError = nil
                    }
                    throw error
                }
            }
        }
    }

    /// A hint to retire clean pages after a worker finishes drawing. The OS is
    /// free to retain file-backed pages; this is not a hard RSS-limit promise.
    func discardResidentPages() {
        ScreenshotRasterWorkGate.shared.withPermit {
            lock.withLock { mappedStorage?.discardResidentPages() }
        }
    }

    func releaseReadPages() { discardResidentPages() }

    private final class MappedStorage {
        let url: URL
        let descriptor: Int32
        let address: UnsafeMutableRawPointer
        let byteCount: Int
        init(url: URL, descriptor: Int32, address: UnsafeMutableRawPointer, byteCount: Int) {
            self.url = url
            self.descriptor = descriptor
            self.address = address
            self.byteCount = byteCount
            _ = madvise(address, byteCount, MADV_RANDOM)
        }
        func discardResidentPages() { _ = madvise(address, byteCount, MADV_DONTNEED) }
        deinit {
            munmap(address, byteCount)
            close(descriptor)
            unlink(url.path)
        }
    }

    private final class PNGDecoder {
        enum Result {
            case unsupported(String)
            case mapped(MappedStorage)
        }
        private let input: FileHandle
        private let original: CGImage
        private let directory: URL
        private var outputFD: Int32 = -1
        private var outputURL: URL?
        private var width = 0
        private var height = 0
        private var channels = 0
        private var rowBytes = 0
        private var scanline: [UInt8] = []
        private var previous: [UInt8] = []
        private var decoded: [UInt8] = []
        private var rgba: [UInt8] = []
        private var scanlineCount = 0
        private var rowsWritten = 0
        private var transparentRGB: [UInt8]?
        private var stream = z_stream()
        private var inflaterInitialized = false
        private var streamEnded = false
        private var inflateOutput = [UInt8](repeating: 0, count: 64 * 1_024)

        init(url: URL, image: CGImage, directory: URL) throws {
            input = try FileHandle(forReadingFrom: url)
            original = image
            self.directory = directory
        }

        deinit {
            try? input.close()
            if inflaterInitialized { inflateEnd(&stream) }
            if outputFD >= 0 { close(outputFD) }
            if let outputURL { unlink(outputURL.path) }
        }

        func prepare() throws -> Result {
            let signature = try readExactly(8)
            guard Array(signature) == [137, 80, 78, 71, 13, 10, 26, 10] else {
                return .unsupported("非 PNG 像素源")
            }
            let header = try readExactly(8)
            guard uint32(header, 0) == 13, String(data: header.suffix(4), encoding: .ascii) == "IHDR" else {
                throw SourceError.malformed("缺少首个 IHDR")
            }
            let ihdr = try readExactly(13)
            try validateCRC(type: Data(header.suffix(4)), payload: ihdr)
            width = Int(uint32(ihdr, 0))
            height = Int(uint32(ihdr, 4))
            guard width == original.width, height == original.height else { throw SourceError.dimensionMismatch }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, width > 0, height > 0, max(width, height) <= 120_000,
                  pixels <= 200_000_000 else { throw SourceError.tooLarge }
            guard ihdr[10] == 0, ihdr[11] == 0, ihdr[12] <= 1 else {
                throw SourceError.malformed("无效压缩、过滤或交错方式")
            }
            let depth = ihdr[8], color = ihdr[9]
            guard [0, 2, 3, 4, 6].contains(color), [1, 2, 4, 8, 16].contains(depth),
                  !(color == 2 || color == 4 || color == 6) || depth == 8 || depth == 16,
                  color != 3 || depth <= 8 else { throw SourceError.malformed("无效位深或颜色类型") }
            guard ihdr[8] == 8, ihdr[9] == 2 || ihdr[9] == 6, ihdr[12] == 0 else {
                return .unsupported("仅对 8 位非交错 RGB/RGBA PNG 使用文件映射")
            }
            channels = ihdr[9] == 2 ? 3 : 4
            rowBytes = width * channels
            scanline = [UInt8](repeating: 0, count: rowBytes + 1)
            previous = [UInt8](repeating: 0, count: rowBytes)
            decoded = previous
            rgba = [UInt8](repeating: 0, count: width * 4)
            try createOutput(byteCount: pixels * 4)
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw SourceError.storage("无法初始化 PNG 解压器")
            }
            inflaterInitialized = true

            var sawIDAT = false
            var idatSequenceEnded = false
            var sawPalette = false
            while true {
                let chunkHeader = try readExactly(8)
                let length = Int(uint32(chunkHeader, 0))
                guard length <= 0x7fff_ffff else { throw SourceError.malformed("块长度无效") }
                let typeBytes = Data(chunkHeader.suffix(4))
                guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      typeBytes[2] & 32 == 0,
                      let type = String(data: typeBytes, encoding: .ascii) else {
                    throw SourceError.malformed("块类型无效")
                }
                if type == "IHDR" { throw SourceError.malformed("重复 IHDR") }
                if type == "tRNS" {
                    guard !sawIDAT, channels == 3, length == 6, transparentRGB == nil else {
                        throw SourceError.malformed("tRNS 透明色无效")
                    }
                }
                if type == "IDAT" {
                    guard !idatSequenceEnded else { throw SourceError.malformed("IDAT 块不连续") }
                    sawIDAT = true
                } else if sawIDAT {
                    idatSequenceEnded = true
                }
                if type == "PLTE" {
                    guard !sawIDAT, !sawPalette, length > 0, length <= 768, length % 3 == 0 else {
                        throw SourceError.malformed("PLTE 无效")
                    }
                    sawPalette = true
                }
                if type == "IEND" {
                    guard length == 0, sawIDAT else { throw SourceError.malformed("IEND 无效") }
                } else if type != "IDAT", type != "PLTE", typeBytes[0] & 32 == 0 {
                    throw SourceError.malformed("不支持的关键 PNG 块：\(type)")
                }
                var checksum = crc32(0, nil, 0)
                checksum = crc(typeBytes, initial: checksum)
                var remaining = length
                var transparencyData = Data()
                while remaining > 0 {
                    let data = try readExactly(min(64 * 1_024, remaining))
                    checksum = crc(data, initial: checksum)
                    if type == "IDAT" { try consumeCompressed(data) }
                    if type == "tRNS" { transparencyData.append(data) }
                    remaining -= data.count
                }
                guard uint32(try readExactly(4), 0) == UInt32(checksum) else {
                    throw SourceError.malformed("\(type) CRC 不一致")
                }
                if type == "tRNS" {
                    guard transparencyData[0] == 0, transparencyData[2] == 0, transparencyData[4] == 0 else {
                        throw SourceError.malformed("tRNS 样本超出 8 位范围")
                    }
                    transparentRGB = [transparencyData[1], transparencyData[3], transparencyData[5]]
                }
                if type == "IEND" {
                    guard streamEnded, rowsWritten == height, scanlineCount == 0 else {
                        throw SourceError.malformed("PNG 解压数据不完整")
                    }
                    guard try input.read(upToCount: 1)?.isEmpty != false else {
                        throw SourceError.malformed("IEND 后有额外数据")
                    }
                    break
                }
            }
            guard fsync(outputFD) == 0 else { throw storageError("fsync") }
            let byteCount = width * height * 4
            guard let address = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, outputFD, 0), address != MAP_FAILED else {
                throw storageError("mmap")
            }
            let storage = MappedStorage(url: outputURL!, descriptor: outputFD, address: address, byteCount: byteCount)
            outputFD = -1
            outputURL = nil
            return .mapped(storage)
        }

        private func createOutput(byteCount: Int) throws {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            guard let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
                  free >= Int64(byteCount) + 64 * 1_024 * 1_024 else {
                throw SourceError.insufficientDiskSpace
            }
            var template = Array(directory.appendingPathComponent("DisplayMonitor-Raster-XXXXXX").path.utf8CString)
            outputFD = mkstemp(&template)
            guard outputFD >= 0 else { throw storageError("mkstemp") }
            outputURL = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            guard fchmod(outputFD, S_IRUSR | S_IWUSR) == 0 else { throw storageError("chmod") }
            // Sequential uncached writes avoid a writable 800 MB mapping and
            // keep the dirty-page set out of this process's address space.
            guard fcntl(outputFD, F_NOCACHE, 1) == 0 else { throw storageError("F_NOCACHE") }
        }

        private func consumeCompressed(_ data: Data) throws {
            guard !streamEnded else {
                if !data.isEmpty { throw SourceError.malformed("zlib 流结束后仍有压缩数据") }
                return
            }
            try data.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(raw.count)
                repeat {
                    let inputBefore = stream.avail_in
                    let status = inflateOutput.withUnsafeMutableBytes { buffer -> Int32 in
                        stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(buffer.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let produced = inflateOutput.count - Int(stream.avail_out)
                    if produced > 0 { try consumeScanlines(count: produced) }
                    if status == Z_STREAM_END {
                        streamEnded = true
                        guard stream.avail_in == 0 else { throw SourceError.malformed("zlib 流后存在多余数据") }
                        break
                    }
                    if status == Z_BUF_ERROR, stream.avail_in == 0, produced == 0 { break }
                    guard status == Z_OK, inputBefore != stream.avail_in || produced > 0 else {
                        throw SourceError.malformed("zlib 解压或 Adler 校验失败（\(status)）")
                    }
                } while stream.avail_in > 0 || stream.avail_out == 0
                stream.next_in = nil
            }
        }

        private func consumeScanlines(count: Int) throws {
            var offset = 0
            while offset < count {
                guard rowsWritten < height else { throw SourceError.malformed("解压后行数超出 IHDR") }
                let amount = min(count - offset, scanline.count - scanlineCount)
                _ = scanline.withUnsafeMutableBytes { target in
                    inflateOutput.withUnsafeBytes { source in
                        memcpy(target.baseAddress! + scanlineCount, source.baseAddress! + offset, amount)
                    }
                }
                offset += amount
                scanlineCount += amount
                if scanlineCount == scanline.count {
                    try writeRow()
                    rowsWritten += 1
                    scanlineCount = 0
                }
            }
        }

        private func writeRow() throws {
            let filter = scanline[0]
            guard filter <= 4 else { throw SourceError.malformed("无效行过滤器") }
            for index in 0..<rowBytes {
                let left = index >= channels ? decoded[index - channels] : 0
                let up = previous[index]
                let upperLeft = index >= channels ? previous[index - channels] : 0
                let predictor: UInt8
                switch filter {
                case 0: predictor = 0
                case 1: predictor = left
                case 2: predictor = up
                case 3: predictor = UInt8((Int(left) + Int(up)) / 2)
                default: predictor = Self.paeth(left, up, upperLeft)
                }
                decoded[index] = scanline[index + 1] &+ predictor
            }
            for x in 0..<width {
                let input = x * channels
                let output = x * 4
                let alpha: UInt8
                if channels == 4 { alpha = decoded[input + 3] }
                else if let key = transparentRGB,
                        decoded[input] == key[0], decoded[input + 1] == key[1], decoded[input + 2] == key[2] { alpha = 0 }
                else { alpha = 255 }
                for component in 0..<3 {
                    rgba[output + component] = UInt8((Int(decoded[input + component]) * Int(alpha) + 127) / 255)
                }
                rgba[output + 3] = alpha
            }
            try rgba.withUnsafeBytes { data in
                var written = 0
                while written < data.count {
                    let result = Darwin.write(outputFD, data.baseAddress! + written, data.count - written)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw storageError("write") }
                    written += result
                }
            }
            swap(&previous, &decoded)
        }

        private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
            let estimate = Int(a) + Int(b) - Int(c)
            let da = abs(estimate - Int(a)), db = abs(estimate - Int(b)), dc = abs(estimate - Int(c))
            return da <= db && da <= dc ? a : (db <= dc ? b : c)
        }

        private func readExactly(_ count: Int) throws -> Data {
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                guard let next = try input.read(upToCount: count - result.count), !next.isEmpty else {
                    throw SourceError.malformed("文件被截断")
                }
                result.append(next)
            }
            return result
        }

        private func validateCRC(type: Data, payload: Data) throws {
            let checksum = crc(payload, initial: crc(type, initial: crc32(0, nil, 0)))
            guard UInt32(checksum) == uint32(try readExactly(4), 0) else {
                throw SourceError.malformed("IHDR CRC 不一致")
            }
        }

        private func crc(_ data: Data, initial: uLong) -> uLong {
            data.withUnsafeBytes { raw in crc32(initial, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)) }
        }

        private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        private func storageError(_ operation: String) -> SourceError {
            .storage("\(operation)：\(String(cString: strerror(errno)))")
        }
    }
}
