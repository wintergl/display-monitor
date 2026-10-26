import CoreGraphics
import Darwin
import DisplayMonitorCore
import Foundation
import ImageIO
import XCTest
import zlib

@testable import DisplayMonitor

/// Explicitly opt in after source-provider integration. The ordinary suite
/// never creates a 100M-pixel export or reads personal screenshots.
@MainActor
final class ScreenshotLargeImageAcceptanceTests: XCTestCase {
    func test100MillionPixelTiledPNGAcceptance() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISPLAY_MONITOR_LARGE_IMAGE_PROBE"] == "1",
                          "Set DISPLAY_MONITOR_LARGE_IMAGE_PROBE=1 to run the synthetic 100M-pixel acceptance probe")
        let fixture = URL(fileURLWithPath: "/private/tmp/v-monitor-preview-100m.png")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "Generate the separate synthetic 100M fixture first")
        let originalCompressedBytes = try Data(contentsOf: fixture)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture as CFURL, options))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, options))
        XCTAssertEqual(image.width, 10_000)
        XCTAssertEqual(image.height, 10_000)
        let provider = ScreenshotRasterSource(image: image, sourceURL: fixture)
        let snapshot = ScreenshotRenderSnapshot(source: image, stateID: UUID(),
            cropRect: CGRect(x: 0, y: 0, width: image.width, height: image.height), annotations: [], rasterSource: provider)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportDirectory = root.appendingPathComponent("reports/capture-p1-large-20261020")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let name = "100m-tiled-export-\(UUID().uuidString)"
        let output = reportDirectory.appendingPathComponent(name + ".png")
        let report = reportDirectory.appendingPathComponent(name + ".json")
        let result = try await Task.detached(priority: .userInitiated) { @Sendable in
            let before = Self.memory()
            let began = Date()
            let renderer = ScreenshotDocumentRenderer(snapshot: snapshot)
            let data = try renderer.pngData(strategy: .tiled(maximumWorkingBytes: 64 * 1_024 * 1_024, haloRows: 2))
            let renderedAt = Date()
            let afterRender = Self.memory()
            try data.write(to: output, options: .atomic)
            let publishedAt = Date()
            let validationBegan = Date()
            let samplePoints = [0, 70, 5_000, 5_070, 9_999].flatMap { y in
                [0, 4_999, 9_999].map { CGPoint(x: $0, y: y) }
            }
            let expected = try Self.samples(from: provider.imageForRendering(), points: samplePoints)
            let inspection = try PNGInspection.inspect(url: output, expectedWidth: 10_000, expectedHeight: 10_000,
                samplePoints: samplePoints)
            let sourceUnchanged = try Data(contentsOf: fixture) == originalCompressedBytes
            var sampleDifferences: [[String: Any]] = []
            for (key, actual) in inspection.samples {
                let wanted = expected[key]!
                let difference = zip(actual, wanted).map { abs(Int($0) - Int($1)) }.max() ?? 0
                sampleDifferences.append(["point": key, "expectedPremultipliedSRGBA": wanted,
                                          "actualPremultipliedSRGBA": actual, "maximumDifference": difference])
            }
            let details: [String: Any] = [
                "fixture": fixture.path, "output": output.path,
                "width": inspection.width, "height": inspection.height,
                "renderSeconds": renderedAt.timeIntervalSince(began),
                "publishSeconds": publishedAt.timeIntervalSince(renderedAt),
                "validationSeconds": Date().timeIntervalSince(validationBegan),
                "pngByteCount": data.count, "chunkCount": inspection.chunkCount,
                "allChunkCRCsValid": true, "zlibTrailerValid": true, "completeIENDAndEOF": true,
                "decodedRows": inspection.rows, "sourceStrategy": String(describing: provider.strategy),
                "sourceFileUnchanged": sourceUnchanged,
                "memoryBeforeRender": before, "memoryAfterRenderBeforeValidation": afterRender,
                "memoryAfterValidation": Self.memory(),
                "canonicalRasterCacheBytes": renderer.canonicalCachedBytes,
                "canonicalTilesRendered": renderer.canonicalTileRenderCount,
                "sampleResults": sampleDifferences.sorted { String(describing: $0["point"]!) < String(describing: $1["point"]!) },
                "note": "Synthetic fixture is opaque; transparent RGBA fidelity is covered separately by focused renderer/exporter tests. RSS includes mapped source pages, runtime and system caches."
            ]
            try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
            return (inspection.width, inspection.height, inspection.rows, inspection.samples.count,
                    sampleDifferences.compactMap { $0["maximumDifference"] as? Int }.max() ?? Int.max,
                    provider.strategy == .mappedPNG, sourceUnchanged)
        }.value
        XCTAssertEqual(result.0, 10_000)
        XCTAssertEqual(result.1, 10_000)
        XCTAssertEqual(result.2, 10_000)
        XCTAssertEqual(result.3, 15)
        XCTAssertLessThanOrEqual(result.4, 1, "Sample alpha/color changed; inspect \(report.path)")
        XCTAssertTrue(result.5, "The probe must use the streaming mapped PNG source, not repeated ImageIO whole-source decode")
        XCTAssertTrue(result.6)
        print("100M acceptance output: \(output.path)")
        print("100M acceptance report: \(report.path)")
    }

    nonisolated private static func memory() -> [String: UInt64] {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ["rss": status == KERN_SUCCESS ? UInt64(info.resident_size) : 0, "peakRSS": UInt64(usage.ru_maxrss)]
    }

    nonisolated private static func samples(from image: CGImage, points: [CGPoint]) throws -> [String: [UInt8]] {
        var values: [String: [UInt8]] = [:]
        for point in points {
            let pixel = try XCTUnwrap(image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            values["\(Int(point.x)),\(Int(point.y))"] = Array(UnsafeBufferPointer(start: bytes, count: 4))
        }
        return values
    }
}

private final class PNGInspection {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var rows = 0
    private(set) var chunkCount = 0
    private(set) var samples: [String: [UInt8]] = [:]
    private let samplePoints: [CGPoint]
    private var stream = z_stream()
    private var ended = false
    private var row: [UInt8] = []
    private var rowOffset = 0
    private var output = [UInt8](repeating: 0, count: 64 * 1_024)

    private init(samplePoints: [CGPoint]) throws {
        self.samplePoints = samplePoints
        let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ProbeError.invalid("inflate initialization") }
    }

    deinit { inflateEnd(&stream) }

    static func inspect(url: URL, expectedWidth: Int, expectedHeight: Int, samplePoints: [CGPoint]) throws -> PNGInspection {
        let result = try PNGInspection(samplePoints: samplePoints)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try read(8, from: handle) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw ProbeError.invalid("signature") }
        var foundHeader = false
        var foundData = false
        while true {
            let length = Int(uint32(try read(4, from: handle)))
            guard length <= 8 * 1_024 * 1_024 else { throw ProbeError.invalid("unbounded chunk") }
            let typeData = try read(4, from: handle)
            let payload = try read(length, from: handle)
            let expectedCRC = uint32(try read(4, from: handle))
            var crc = typeData.withUnsafeBytes { zlib.crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
            if !payload.isEmpty {
                crc = payload.withUnsafeBytes { zlib.crc32(crc, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
            }
            guard UInt32(truncatingIfNeeded: crc) == expectedCRC else { throw ProbeError.invalid("chunk CRC") }
            result.chunkCount += 1
            let type = String(decoding: typeData, as: UTF8.self)
            switch type {
            case "IHDR":
                guard !foundHeader, payload.count == 13, result.chunkCount == 1,
                      Array(payload[8..<13]) == [8, 6, 0, 0, 0] else { throw ProbeError.invalid("IHDR format") }
                result.width = Int(uint32(payload.subdata(in: 0..<4)))
                result.height = Int(uint32(payload.subdata(in: 4..<8)))
                guard result.width == expectedWidth, result.height == expectedHeight else { throw ProbeError.invalid("dimensions") }
                result.row = [UInt8](repeating: 0, count: result.width * 4 + 1)
                foundHeader = true
            case "IDAT":
                guard foundHeader, !result.ended else { throw ProbeError.invalid("IDAT order") }
                foundData = true
                try result.inflate(payload)
            case "IEND":
                guard length == 0, foundData, result.ended, result.rows == result.height, result.rowOffset == 0,
                      (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw ProbeError.invalid("IEND/trailer/row count") }
                return result
            default: break
            }
        }
    }

    private func inflate(_ data: Data) throws {
        try data.withUnsafeBytes { input in
            stream.next_in = input.baseAddress.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
            stream.avail_in = uInt(input.count)
            defer { stream.next_in = nil; stream.next_out = nil }
            repeat {
                let status = output.withUnsafeMutableBufferPointer {
                    stream.next_out = $0.baseAddress!
                    stream.avail_out = uInt($0.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = output.count - Int(stream.avail_out)
                if status == Z_BUF_ERROR, stream.avail_in == 0, count == 0 { break }
                guard status == Z_OK || status == Z_STREAM_END else { throw ProbeError.invalid("zlib stream/trailer") }
                try output.withUnsafeBufferPointer { try consume(UnsafeBufferPointer(start: $0.baseAddress, count: count)) }
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw ProbeError.invalid("extra compressed data") }
                    ended = true
                    break
                }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
    }

    private func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        var offset = 0
        while offset < bytes.count {
            let count = min(row.count - rowOffset, bytes.count - offset)
            row.replaceSubrange(rowOffset..<(rowOffset + count), with: bytes[offset..<(offset + count)])
            rowOffset += count
            offset += count
            if rowOffset == row.count {
                guard rows < height, row[0] == 0 else { throw ProbeError.invalid("row count/filter") }
                for point in samplePoints where Int(point.y) == rows {
                    let start = Int(point.x) * 4 + 1
                    let straight = Array(row[start..<(start + 4)])
                    let alpha = Int(straight[3])
                    samples["\(Int(point.x)),\(Int(point.y))"] = [
                        UInt8((Int(straight[0]) * alpha + 127) / 255),
                        UInt8((Int(straight[1]) * alpha + 127) / 255),
                        UInt8((Int(straight[2]) * alpha + 127) / 255), straight[3]
                    ]
                }
                rows += 1
                rowOffset = 0
            }
        }
    }

    private static func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            let part = try handle.read(upToCount: count - data.count) ?? Data()
            guard !part.isEmpty else { throw ProbeError.invalid("truncated file") }
            data.append(part)
        }
        return data
    }

    private static func uint32(_ data: Data) -> UInt32 { data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    private enum ProbeError: Error { case invalid(String) }
}
