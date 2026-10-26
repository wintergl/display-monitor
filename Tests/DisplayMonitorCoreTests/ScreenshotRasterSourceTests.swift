import CoreGraphics
import Foundation
import XCTest
import zlib
@testable import DisplayMonitor

final class ScreenshotRasterSourceTests: XCTestCase {
    func testAllFiveFiltersAndStraightAlphaProduceExactPremultipliedRows() throws {
        for channels in [3, 4] {
            let fixture = try Fixture(channels: channels)
            defer { fixture.remove() }
            let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
            let image = try source.imageForRendering()
            XCTAssertEqual(source.strategy, .mappedPNG)
            XCTAssertEqual(image.dataProvider?.data as Data?, fixture.expectedRGBA)
            XCTAssertTrue(image === (try source.imageForRendering()))
            source.releaseReadPages()
            XCTAssertEqual(image.dataProvider?.data as Data?, fixture.expectedRGBA)
            let permissions = try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(source.mappedFileURL).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testTrueColorTransparencyKeyIsPreserved() throws {
        let fixture = try Fixture(channels: 3, transparentKey: [0, 17, 34])
        defer { fixture.remove() }
        let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
        XCTAssertEqual(try source.imageForRendering().dataProvider?.data as Data?, fixture.expectedRGBA)
        XCTAssertEqual(Array(fixture.expectedRGBA.prefix(4)), [0, 0, 0, 0])
    }

    func testCRCAdlerFilterAndTruncationFailuresRetainNoRawFileAndNeverFallback() throws {
        for corruption in [Fixture.Corruption.crc, .adler, .filter, .truncated, .extraData, .extraRows, .missingIEND] {
            let fixture = try Fixture(channels: 4, corruption: corruption)
            defer { fixture.remove() }
            let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
            XCTAssertThrowsError(try source.imageForRendering(), "\(corruption)")
            XCTAssertNil(source.mappedFileURL)
            XCTAssertTrue(try rawFiles(in: fixture.directory).isEmpty)
            XCTAssertThrowsError(try source.imageForRendering(), "A cached failure must not silently return the original")
        }
    }

    func testDimensionsAndIllegalDepthAreRejectedBeforeMapping() throws {
        let fixture = try Fixture(channels: 4)
        defer { fixture.remove() }
        let mismatch = ScreenshotRasterSource(image: try Fixture.placeholder(width: 7, height: 10), sourceURL: fixture.url, temporaryDirectory: fixture.directory)
        XCTAssertThrowsError(try mismatch.imageForRendering())

        var illegal = fixture.data
        // Rebuild IHDR CRC after changing to illegal 1-bit grayscale+alpha.
        illegal[24] = 1
        illegal[25] = 4
        illegal.replaceSubrange(29..<33, with: Fixture.be(Fixture.crc(illegal.subdata(in: 12..<29))))
        try illegal.write(to: fixture.url)
        let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
        XCTAssertThrowsError(try source.imageForRendering())
        XCTAssertTrue(try rawFiles(in: fixture.directory).isEmpty)
    }

    func testUnsupportedInterlaceIsExplicitAndNilURLRetainsOriginal() throws {
        let fixture = try Fixture(channels: 4)
        defer { fixture.remove() }
        let direct = ScreenshotRasterSource(image: fixture.image, sourceURL: nil)
        XCTAssertTrue(try direct.imageForRendering() === fixture.image)
        XCTAssertEqual(direct.strategy, .originalImage)

        var interlaced = fixture.data
        interlaced[28] = 1
        interlaced.replaceSubrange(29..<33, with: Fixture.be(Fixture.crc(interlaced.subdata(in: 12..<29))))
        try interlaced.write(to: fixture.url)
        let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
        XCTAssertTrue(try source.imageForRendering() === fixture.image)
        guard case .originalUnsupported = source.strategy else { return XCTFail("Unsupported path must be visible") }
        XCTAssertNil(source.mappedFileURL)
    }

    func testRGBProfilesAndProviderLifetimeArePreserved() throws {
        for spaceName in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let fixture = try Fixture(channels: 4, colorSpace: try XCTUnwrap(CGColorSpace(name: spaceName)))
            defer { fixture.remove() }
            var source: ScreenshotRasterSource? = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: fixture.directory)
            var retained: CGImage? = try source!.imageForRendering()
            let rawURL = try XCTUnwrap(source?.mappedFileURL)
            XCTAssertEqual(retained?.colorSpace?.name, fixture.image.colorSpace?.name)
            source = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
            XCTAssertEqual(retained?.width, fixture.image.width)
            retained = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: rawURL.path))
        }
    }

    func testTemporaryStorageFailureCanRecoverOnTheSameSourceWithoutChangingItsInput() throws {
        let fixture = try Fixture(channels: 4)
        defer { fixture.remove() }
        let temporary = fixture.directory.appendingPathComponent("not-created-yet", isDirectory: true)
        let originalPixels = fixture.image.dataProvider?.data as Data?
        let source = ScreenshotRasterSource(image: fixture.image, sourceURL: fixture.url, temporaryDirectory: temporary)
        XCTAssertThrowsError(try source.imageForRendering())
        XCTAssertNil(source.mappedFileURL)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let recovered = try source.imageForRendering()
        XCTAssertEqual(source.strategy, .mappedPNG)
        XCTAssertEqual(recovered.dataProvider?.data as Data?, fixture.expectedRGBA)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.data)
        XCTAssertEqual(fixture.image.dataProvider?.data as Data?, originalPixels)
    }

    private func rawFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("DisplayMonitor-Raster-") }
    }

    private struct Fixture {
        enum Corruption { case crc, adler, filter, truncated, extraData, extraRows, missingIEND }
        let directory: URL
        let url: URL
        let image: CGImage
        let data: Data
        let expectedRGBA: Data

        init(channels: Int, transparentKey: [UInt8]? = nil, corruption: Corruption? = nil, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
            let width = 8, height = 10
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("raster-source-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("fixture.png")
            image = try Self.placeholder(width: width, height: height, colorSpace: colorSpace)
            var raw = Data(), expected = Data()
            var previous = [UInt8](repeating: 0, count: width * channels)
            for y in 0..<(height + (corruption == .extraRows ? 1 : 0)) {
                var row = [UInt8](repeating: 0, count: width * channels)
                for x in 0..<width {
                    for c in 0..<3 { row[x * channels + c] = UInt8((x * 23 + y * 31 + c * 17) % 256) }
                    if channels == 4 { row[x * channels + 3] = UInt8(((x + y) % 4) * 85) }
                    let alpha: UInt8 = channels == 4 ? row[x * channels + 3]
                        : (transparentKey == Array(row[(x * channels)..<(x * channels + 3)]) ? 0 : 255)
                    for c in 0..<3 { expected.append(UInt8((Int(row[x * channels + c]) * Int(alpha) + 127) / 255)) }
                    expected.append(alpha)
                }
                let filter = y % 5
                raw.append(corruption == .filter && y == 0 ? 5 : UInt8(filter))
                for index in row.indices {
                    let left = index >= channels ? row[index - channels] : 0
                    let up = previous[index]
                    let corner = index >= channels ? previous[index - channels] : 0
                    let predictor: UInt8
                    switch filter {
                    case 0: predictor = 0
                    case 1: predictor = left
                    case 2: predictor = up
                    case 3: predictor = UInt8((Int(left) + Int(up)) / 2)
                    default:
                        let p = Int(left) + Int(up) - Int(corner)
                        let a = abs(p - Int(left)), b = abs(p - Int(up)), c = abs(p - Int(corner))
                        predictor = a <= b && a <= c ? left : (b <= c ? up : corner)
                    }
                    raw.append(row[index] &- predictor)
                }
                previous = row
            }
            expectedRGBA = expected
            var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(raw.count))))
            var size = uLongf(compressed.count)
            let status = raw.withUnsafeBytes { input in
                compressed.withUnsafeMutableBufferPointer { output in
                    compress2(output.baseAddress, &size, input.bindMemory(to: Bytef.self).baseAddress, uLong(raw.count), Z_DEFAULT_COMPRESSION)
                }
            }
            guard status == Z_OK else { throw NSError(domain: "PNGFixture", code: Int(status)) }
            var payload = Data(compressed.prefix(Int(size)))
            if corruption == .adler { payload[payload.count - 1] ^= 1 }
            var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
            png.append(Self.chunk("IHDR", Self.be(UInt32(width)) + Self.be(UInt32(height)) + Data([8, channels == 4 ? 6 : 2, 0, 0, 0])))
            if let transparentKey {
                png.append(Self.chunk("tRNS", Data(transparentKey.flatMap { [UInt8(0), $0] })))
            }
            // Split the zlib stream across odd boundaries, including a zero
            // length IDAT, to exercise streaming rather than one-shot decode.
            let split = min(7, payload.count)
            png.append(Self.chunk("IDAT", payload.prefix(split)))
            png.append(Self.chunk("IDAT", Data()))
            png.append(Self.chunk("IDAT", payload.dropFirst(split)))
            if corruption != .missingIEND { png.append(Self.chunk("IEND", Data())) }
            if corruption == .crc { png[48] ^= 1 }
            if corruption == .truncated { png.removeLast(5) }
            if corruption == .extraData { png.append(42) }
            data = png
            try png.write(to: url)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        static func placeholder(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        static func be(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        static func crc(_ data: Data) -> UInt32 {
            data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        }
        static func chunk(_ type: String, _ payload: Data) -> Data {
            let body = Data(type.utf8) + payload
            return be(UInt32(payload.count)) + body + be(crc(body))
        }
    }
}
