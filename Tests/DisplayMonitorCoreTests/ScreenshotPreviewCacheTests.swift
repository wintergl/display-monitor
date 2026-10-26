import CoreGraphics
import ImageIO
import XCTest
@testable import DisplayMonitor

@MainActor
final class ScreenshotPreviewCacheTests: XCTestCase {
    func testExplicitRetryRecoversASourceFailureAndDoesNotRetryOnEveryRedraw() async throws {
        let image = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let cache = ScreenshotPreviewCache(image: image, sourceURL: url)
        let region = CGRect(x: 0, y: 0, width: 256, height: 256)
        _ = cache.tiles(for: region, displayScale: 1, backingScale: 1)
        await cache.waitUntilIdle()
        XCTAssertNotNil(cache.failureMessage)
        let failedCount = cache.productionCount
        for _ in 0..<5 { _ = cache.tiles(for: region, displayScale: 1, backingScale: 1) }
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.productionCount, failedCount)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        cache.setSuspended(true)
        cache.retryFailedRequests()
        cache.setSuspended(false)
        await cache.waitUntilIdle()
        XCTAssertNil(cache.failureMessage)
        XCTAssertFalse(cache.tiles(for: region, displayScale: 1, backingScale: 1).isEmpty)
    }

    func testVisibleTilesUseOriginalPixelsAtHighZoomAndReuseTheirRaster() async throws {
        let source = try fixture()
        let cache = ScreenshotPreviewCache(image: source)
        let region = CGRect(x: 512, y: 0, width: 256, height: 256)
        _ = cache.tiles(for: region, displayScale: 2, backingScale: 2)
        await cache.waitUntilIdle()
        let tiles = cache.tiles(for: region, displayScale: 2, backingScale: 2)
        let detail = try XCTUnwrap(tiles.first { !$0.isOverview })
        XCTAssertEqual(detail.level, 0)
        XCTAssertEqual(CGFloat(detail.image.width), detail.sourceRect.width)
        XCTAssertTrue(detail.sourceRect.intersects(region))
        // CGColor's RGB components are color-managed when filling a DeviceRGB
        // context. Compare actual source pixels, not an assumed 255 green.
        XCTAssertEqual(try pixel(in: detail.image), try pixel(in: source, x: 512))
        let productionCount = cache.productionCount
        _ = cache.tiles(for: region, displayScale: 1, backingScale: 2)
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.productionCount, productionCount)
    }

    func testZoomLevelsAndPanKeepAdditionalRastersWithinTheBudget() async throws {
        var options = ScreenshotPreviewCache.Configuration()
        options.tilePixelEdge = 64
        options.tileByteLimit = 4 * 64 * 64 * 4
        options.overviewPixelLimit = 4_096
        options.overviewDimensionLimit = 128
        let cache = ScreenshotPreviewCache(image: try fixture(), configuration: options)
        for region in [
            CGRect(x: 0, y: 0, width: 512, height: 512),
            CGRect(x: 512, y: 512, width: 512, height: 512),
            CGRect(x: 256, y: 256, width: 256, height: 256)
        ] {
            _ = cache.tiles(for: region, displayScale: 0.25, backingScale: 1)
            XCTAssertLessThanOrEqual(cache.pendingTileCount, 4)
            await cache.waitUntilIdle()
            XCTAssertLessThanOrEqual(cache.tileBytes, options.tileByteLimit)
            XCTAssertLessThanOrEqual(cache.residentByteCount, cache.maximumResidentByteCount)
            XCTAssertLessThanOrEqual(cache.cachedTileCount, 4)
            let tiles = cache.tiles(for: region, displayScale: 0.25, backingScale: 1)
            XCTAssertEqual(tiles.filter { !$0.isOverview }.count, region.width == 512 ? 4 : 1)
            XCTAssertEqual(cache.requestedLevel, 2)
        }
    }

    func testNativePixelTilesPreserveTaggedRGBValuesAndColorSpace() async throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let colorSpace = try XCTUnwrap(CGColorSpace(name: name))
            let bytes = Data((0..<(32 * 32)).flatMap { _ in [UInt8(245), 12, 129, 255] })
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let source = try XCTUnwrap(CGImage(
                width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
            let cache = ScreenshotPreviewCache(image: source)
            let region = CGRect(x: 0, y: 0, width: 32, height: 32)
            _ = cache.tiles(for: region, displayScale: 1, backingScale: 1)
            await cache.waitUntilIdle()
            let detail = try XCTUnwrap(cache.tiles(for: region, displayScale: 1, backingScale: 1).first { !$0.isOverview })
            XCTAssertEqual(try pixel(in: detail.image), try pixel(in: source))
            XCTAssertEqual(detail.image.colorSpace?.name, source.colorSpace?.name)
        }
    }

    func testEnormousViewportCoarsensBeforeAllocatingWorkAndRejectsInvalidCoordinates() async throws {
        var options = ScreenshotPreviewCache.Configuration()
        options.tilePixelEdge = 32
        options.tileByteLimit = 32 * 32 * 4
        let cache = ScreenshotPreviewCache(image: try fixture(), configuration: options)
        _ = cache.tiles(for: CGRect(x: 0, y: 0, width: 1_024, height: 1_024), displayScale: 1, backingScale: 2)
        XCTAssertLessThanOrEqual(cache.pendingTileCount, 1)
        await cache.waitUntilIdle()
        let tiles = cache.tiles(for: CGRect(x: 0, y: 0, width: 1_024, height: 1_024), displayScale: 1, backingScale: 2)
        XCTAssertEqual(tiles.filter { !$0.isOverview }.count, 1)
        XCTAssertEqual(cache.requestedLevel, 5)
        XCTAssertTrue(cache.tiles(for: .infinite, displayScale: .nan, backingScale: 2).isEmpty)
        XCTAssertEqual(cache.pendingTileCount, 0)
    }

    func testRapidPanningAndCancellationDiscardObsoleteWork() async throws {
        var options = ScreenshotPreviewCache.Configuration()
        options.tilePixelEdge = 64
        options.tileByteLimit = 4 * 64 * 64 * 4
        let cache = ScreenshotPreviewCache(image: try fixture(), configuration: options)
        var finalRegion = CGRect.zero
        for index in 0..<100 {
            finalRegion = CGRect(x: (index % 2) * 512, y: ((index / 2) % 2) * 512, width: 128, height: 128)
            _ = cache.tiles(for: finalRegion, displayScale: 1, backingScale: 1)
            XCTAssertLessThanOrEqual(cache.pendingTileCount, 4)
        }
        await cache.waitUntilIdle()
        XCTAssertLessThanOrEqual(cache.productionCount, 5, "Only overview plus the latest visible region should run")
        let tiles = cache.tiles(for: finalRegion, displayScale: 1, backingScale: 1)
        XCTAssertTrue(tiles.filter { !$0.isOverview }.allSatisfy { $0.sourceRect.intersects(finalRegion) })

        cache.removeCachedTiles()
        _ = cache.tiles(for: CGRect(x: 0, y: 0, width: 128, height: 128), displayScale: 1, backingScale: 1)
        cache.removeCachedTiles()
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.residentByteCount, 0)
        XCTAssertEqual(cache.cachedTileCount, 0)
    }

    func testOversizedSourceIsRejectedBeforePreviewDecode() async throws {
        var options = ScreenshotPreviewCache.Configuration()
        options.maximumSourcePixels = 100
        let cache = ScreenshotPreviewCache(image: try fixture(), configuration: options)
        XCTAssertFalse(cache.isSourceWithinBudget)
        XCTAssertTrue(cache.tiles(for: CGRect(x: 0, y: 0, width: 128, height: 128), displayScale: 1, backingScale: 1).isEmpty)
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.productionCount, 0)
        XCTAssertEqual(cache.residentByteCount, 0)
    }

    func testSuspensionKeepsCachedImagesAndResumesOnlyTheLatestViewport() async throws {
        var options = ScreenshotPreviewCache.Configuration()
        options.tilePixelEdge = 64
        options.tileByteLimit = 4 * 64 * 64 * 4
        let cache = ScreenshotPreviewCache(image: try fixture(), configuration: options)
        let first = CGRect(x: 0, y: 0, width: 128, height: 128)
        let latest = CGRect(x: 512, y: 512, width: 128, height: 128)
        _ = cache.tiles(for: first, displayScale: 1, backingScale: 1)
        await cache.waitUntilIdle()
        let producedBeforeSuspending = cache.productionCount
        cache.setSuspended(true)
        XCTAssertEqual(cache.tiles(for: first, displayScale: 1, backingScale: 1).filter { !$0.isOverview }.count, 4)
        _ = cache.tiles(for: latest, displayScale: 1, backingScale: 1)
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.pendingTileCount, 0)
        XCTAssertEqual(cache.productionCount, producedBeforeSuspending)
        cache.setSuspended(false)
        await cache.waitUntilIdle()
        let details = cache.tiles(for: latest, displayScale: 1, backingScale: 1).filter { !$0.isOverview }
        XCTAssertEqual(details.count, 4)
        XCTAssertTrue(details.allSatisfy { $0.sourceRect.intersects(latest) })
        XCTAssertEqual(cache.productionCount, producedBeforeSuspending + 4)
    }

    func testSuspendingBeforeTheWorkerStartsCancelsItAndCanResume() async throws {
        let cache = ScreenshotPreviewCache(image: try fixture())
        let region = CGRect(x: 0, y: 0, width: 256, height: 256)
        _ = cache.tiles(for: region, displayScale: 1, backingScale: 1)
        cache.setSuspended(true)
        _ = cache.tiles(for: region, displayScale: 1, backingScale: 1)
        await cache.waitUntilIdle()
        XCTAssertEqual(cache.productionCount, 0)
        XCTAssertEqual(cache.pendingTileCount, 0)
        cache.setSuspended(false)
        await cache.waitUntilIdle()
        let tiles = cache.tiles(for: region, displayScale: 1, backingScale: 1)
        XCTAssertNotNil(tiles.first { $0.isOverview })
        XCTAssertNotNil(tiles.first { !$0.isOverview })
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1_024, height: 1_024, bitsPerComponent: 8, bytesPerRow: 4_096,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 512, y: 0, width: 512, height: 1_024))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(in image: CGImage, x: Int = 0, y: Int = 0) throws -> [UInt8] {
        let provider = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(provider))
        return Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow + x * 4, count: 4))
    }
}
