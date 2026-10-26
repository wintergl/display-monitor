import CoreGraphics
import DisplayMonitorCore
import Foundation
import ImageIO
import XCTest
import zlib

@testable import DisplayMonitor

@MainActor
final class ScreenshotTiledPNGExporterTests: XCTestCase {
    func testManyBandsPreserveOrientationAlphaAndFullResolution() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.png")
        let width = 12, height = 11
        let budget = ScreenshotTiledRasterPlan.fixedWorkingReserveBytes + width * 24 * 3
        var bands: [CGRect] = []
        try ScreenshotTiledPNGExporter.write(
            width: width, height: height, destination: output,
            maximumWorkingBytes: budget, haloRows: 1, availableDiskBytes: Int64.max
        ) { rect in
            bands.append(rect)
            return try self.image(width: width, top: Int(rect.minY), height: Int(rect.height))
        }
        XCTAssertEqual(bands.count, height)
        XCTAssertEqual(bands.first?.minY, 0)
        XCTAssertEqual(bands.last?.maxY, CGFloat(height))
        XCTAssertTrue(bands.allSatisfy { $0.height <= 3 })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(try normalizedPixels(decoded), try normalizedPixels(image(width: width, top: 0, height: height)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["output.png"])
    }

    func testPNGCrcZlibTrailerAndUnassociatedAlphaAreComplete() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.png")
        let width = 5, height = 9
        try ScreenshotTiledPNGExporter.write(
            width: width, height: height, destination: output, availableDiskBytes: Int64.max
        ) { rect in try self.image(width: width, top: Int(rect.minY), height: Int(rect.height)) }
        let parsed = try pngPayload(Data(contentsOf: output))
        XCTAssertEqual(parsed.types.first, "IHDR")
        XCTAssertEqual(parsed.types.last, "IEND")
        var rows = [UInt8](repeating: 0, count: (width * 4 + 1) * height)
        var length = uLongf(rows.count)
        let result = parsed.compressed.withUnsafeBytes { compressed in
            uncompress(&rows, &length, compressed.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(compressed.count))
        }
        XCTAssertEqual(result, Z_OK)
        XCTAssertEqual(Int(length), rows.count)
        for y in 0..<height {
            XCTAssertEqual(rows[y * (width * 4 + 1)], 0)
            // The first pixel has alpha 128 and premultiplied red 64. PNG
            // requires straight red 128, rather than darkening it a second time.
            XCTAssertEqual(rows[y * (width * 4 + 1) + 1], 128)
            XCTAssertEqual(rows[y * (width * 4 + 1) + 4], 128)
        }
        var badTrailer = parsed.compressed
        badTrailer[badTrailer.count - 1] ^= 0xff
        length = uLongf(rows.count)
        let badResult = badTrailer.withUnsafeBytes { compressed in
            uncompress(&rows, &length, compressed.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(compressed.count))
        }
        XCTAssertEqual(badResult, Z_DATA_ERROR, "zlib trailer must be validated, not raw DEFLATE")
    }

    func testWideIncompressibleBandsProduceMultipleIDATChunks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("noise.png")
        let width = 1_024, height = 48
        try ScreenshotTiledPNGExporter.write(
            width: width, height: height, destination: output,
            maximumWorkingBytes: ScreenshotTiledRasterPlan.fixedWorkingReserveBytes + width * 24 * 3,
            availableDiskBytes: Int64.max
        ) { rect in
            var state = UInt32(Int(rect.minY) + 1)
            var data = Data(repeating: 0, count: width * Int(rect.height) * 4)
            for offset in stride(from: 0, to: data.count, by: 4) {
                for channel in 0..<3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    data[offset + channel] = UInt8(truncatingIfNeeded: state >> 24)
                }
                data[offset + 3] = 255
            }
            return try self.makeImage(width: width, height: Int(rect.height), bytes: data)
        }
        let parsed = try pngPayload(Data(contentsOf: output))
        XCTAssertGreaterThan(parsed.types.filter { $0 == "IDAT" }.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
    }

    func testCancellationAndRenderFailureLeaveNoPartialOutputAndKeepSource() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        let original = Data("original source must stay intact".utf8)
        try original.write(to: source)
        let output = directory.appendingPathComponent("revision.png")
        var cancelled = false
        XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
            width: 10, height: 10, destination: output,
            maximumWorkingBytes: ScreenshotTiledRasterPlan.fixedWorkingReserveBytes + 10 * 24 * 2,
            availableDiskBytes: Int64.max, isCancelled: { cancelled }
        ) { rect in
            cancelled = true
            return try self.image(width: 10, top: Int(rect.minY), height: Int(rect.height))
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["original.png"])
        XCTAssertEqual(try Data(contentsOf: source), original)

        enum FixtureError: Error { case renderer }
        var calls = 0
        XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
            width: 10, height: 10, destination: output,
            maximumWorkingBytes: ScreenshotTiledRasterPlan.fixedWorkingReserveBytes + 10 * 24 * 2,
            availableDiskBytes: Int64.max
        ) { rect in
            calls += 1
            if calls == 2 { throw FixtureError.renderer }
            return try self.image(width: 10, top: Int(rect.minY), height: Int(rect.height))
        })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["original.png"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRejectsWrongBandSizeAndExistingDestinationWithoutReplacingEither() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("revision.png")
        XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
            width: 10, height: 10, destination: output, availableDiskBytes: Int64.max
        ) { _ in try self.image(width: 9, top: 0, height: 10) })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let existing = Data("existing destination".utf8)
        try existing.write(to: output)
        var calledRenderer = false
        XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
            width: 10, height: 10, destination: output, availableDiskBytes: Int64.max
        ) { rect in
            calledRenderer = true
            return try self.image(width: 10, top: 0, height: Int(rect.height))
        })
        XCTAssertFalse(calledRenderer)
        XCTAssertEqual(try Data(contentsOf: output), existing)
    }

    func testDiskAndScratchLimitsRejectBeforeRenderingOrCreatingTemporaryFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("revision.png")
        var rendered = false
        for disk: Int64 in [0, 100] {
            XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
                width: 10, height: 10, destination: output, availableDiskBytes: disk
            ) { rect in
                rendered = true
                return try self.image(width: 10, top: 0, height: Int(rect.height))
            })
        }
        XCTAssertThrowsError(try ScreenshotTiledPNGExporter.write(
            width: 10, height: 10, destination: output,
            maximumWorkingBytes: 1, availableDiskBytes: Int64.max
        ) { rect in
            rendered = true
            return try self.image(width: 10, top: 0, height: Int(rect.height))
        })
        XCTAssertFalse(rendered)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPlanBoundsBandsHalosAndVeryLargeDimensionsWithoutFullImageAllocation() throws {
        for width in [1, 1_440, 20_000, 30_000] {
            let plan = try ScreenshotTiledRasterPlan(width: width, height: 120_000)
            XCTAssertLessThanOrEqual(plan.estimatedWorkingBytes, plan.maximumWorkingBytes)
            XCTAssertGreaterThan(plan.bandHeight, 0)
            XCTAssertLessThanOrEqual(plan.bandHeight, 2_048)
        }
        let haloPlan = try ScreenshotTiledRasterPlan(width: 1_440, height: 120_000, haloRows: 32)
        XCTAssertEqual(haloPlan.renderRect(forBandTop: haloPlan.bandHeight).minY, CGFloat(haloPlan.bandHeight - 32))
        XCTAssertLessThanOrEqual(haloPlan.estimatedWorkingBytes, haloPlan.maximumWorkingBytes)
        for size in [(Int.max, 2), (2, Int.max), (0, 2), (-2, 2)] {
            XCTAssertThrowsError(try ScreenshotTiledRasterPlan(width: size.0, height: size.1))
        }
        XCTAssertThrowsError(try ScreenshotTiledRasterPlan(width: 20_000, height: 120_000, maximumOutputBytes: 1_024))
        XCTAssertThrowsError(try ScreenshotTiledRasterPlan(width: 20_000, height: 120_000, haloRows: 20_000))
    }

    private func image(width: Int, top: Int, height: Int) throws -> CGImage {
        var bytes = Data(repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = x % 3 == 0 ? 128 : (x % 3 == 1 ? 255 : 0)
                bytes[offset] = UInt8(alpha / 2)
                bytes[offset + 1] = alpha == 0 ? 0 : UInt8(min(alpha, (y + top) * 11))
                bytes[offset + 2] = alpha == 0 ? 0 : UInt8(min(alpha, x * 13))
                bytes[offset + 3] = UInt8(alpha)
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makeImage(width: Int, height: Int, bytes: Data) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func normalizedPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotTiledPNGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pngPayload(_ data: Data) throws -> (compressed: Data, types: [String]) {
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        var offset = 8, compressed = Data(), types: [String] = []
        func uint32(_ at: Int) -> UInt32 {
            data[at..<(at + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        while offset + 12 <= data.count {
            let length = Int(uint32(offset))
            guard length <= data.count - offset - 12 else { throw ScreenshotTiledPNGError.incompleteRows }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let crcBytes = data[(offset + 4)..<(offset + 8 + length)]
            let crc = crcBytes.withUnsafeBytes { zlib.crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
            XCTAssertEqual(UInt32(truncatingIfNeeded: crc), uint32(offset + 8 + length))
            types.append(type)
            if type == "IDAT" { compressed.append(data[(offset + 8)..<(offset + 8 + length)]) }
            offset += length + 12
        }
        XCTAssertEqual(offset, data.count)
        return (compressed, types)
    }
}
