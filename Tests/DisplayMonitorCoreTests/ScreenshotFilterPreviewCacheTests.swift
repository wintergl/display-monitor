import CoreGraphics
import XCTest
@testable import DisplayMonitor

@MainActor
final class ScreenshotFilterPreviewCacheTests: XCTestCase {
    func testVisibleFiltersAreProducedOffMainAndReusedWithinTheRasterBudget() async throws {
        let cache = ScreenshotFilterPreviewCache(byteLimit: 8_192)
        let producer = RasterProducer()
        let keys = [key(), key()]
        XCTAssertTrue(frame(cache, keys: keys, producer: producer).allSatisfy { $0 == nil })
        await cache.waitUntilIdle()
        XCTAssertTrue(frame(cache, keys: keys, producer: producer).allSatisfy { $0 != nil })
        await cache.waitUntilIdle()
        XCTAssertEqual(producer.calls, 2)
        XCTAssertFalse(producer.usedMainThread)
        XCTAssertEqual(cache.residentByteCount, 8_192)
    }

    func testFailedKeyDoesNotRetryOnEveryFrameButNewStateCanRetry() async {
        let cache = ScreenshotFilterPreviewCache()
        let producer = RasterProducer(fails: true)
        let failed = key()
        for _ in 0..<12 {
            _ = frame(cache, keys: [failed], producer: producer)
            await cache.waitUntilIdle()
        }
        XCTAssertEqual(producer.calls, 1)
        let edited = ScreenshotFilterPreviewCache.Key(
            stateID: UUID(), nodeID: failed.nodeID, sourceRect: failed.sourceRect, level: failed.level
        )
        _ = frame(cache, keys: [edited], producer: producer)
        await cache.waitUntilIdle()
        XCTAssertEqual(producer.calls, 2)
        XCTAssertEqual(cache.residentByteCount, 0)
    }

    func testVisibleFiltersOverBudgetKeepPlaceholdersInsteadOfEvictionLoops() async {
        let cache = ScreenshotFilterPreviewCache(byteLimit: 4_096)
        let producer = RasterProducer()
        let keys = [key(), key()]
        _ = frame(cache, keys: keys, producer: producer)
        await cache.waitUntilIdle()
        for _ in 0..<10 {
            let images = frame(cache, keys: keys, producer: producer)
            XCTAssertEqual(images.compactMap { $0 }.count, 1)
            await cache.waitUntilIdle()
        }
        XCTAssertEqual(producer.calls, 2)
        XCTAssertEqual(cache.residentByteCount, 4_096)

        // Panning the first filter away permits the previously blocked one.
        _ = frame(cache, keys: [keys[1]], producer: producer)
        await cache.waitUntilIdle()
        XCTAssertNotNil(frame(cache, keys: [keys[1]], producer: producer).first!)
        XCTAssertEqual(producer.calls, 3)
        XCTAssertEqual(cache.residentByteCount, 4_096)
    }

    func testExplicitRetryRecoversTheSameFailedFilterWithoutChangingTheDocumentKey() async {
        let cache = ScreenshotFilterPreviewCache()
        let failedProducer = RasterProducer(fails: true)
        let recoveredProducer = RasterProducer()
        let unchanged = key()
        _ = frame(cache, keys: [unchanged], producer: failedProducer)
        await cache.waitUntilIdle()
        _ = frame(cache, keys: [unchanged], producer: recoveredProducer)
        await cache.waitUntilIdle()
        XCTAssertEqual(recoveredProducer.calls, 0)
        cache.setSuspended(true)
        cache.retryFailedRequests()
        cache.setSuspended(false)
        await cache.waitUntilIdle()
        XCTAssertNotNil(frame(cache, keys: [unchanged], producer: recoveredProducer).first!)
        XCTAssertEqual(recoveredProducer.calls, 1)
    }

    func testSuspensionCancelsQueuedWorkAndResumesTheLatestVisibleFilters() async {
        let cache = ScreenshotFilterPreviewCache()
        let producer = RasterProducer()
        let first = key()
        let latest = key()
        _ = frame(cache, keys: [first], producer: producer)
        cache.setSuspended(true)
        _ = frame(cache, keys: [latest], producer: producer)
        await cache.waitUntilIdle()
        XCTAssertEqual(producer.calls, 0)
        XCTAssertEqual(cache.pendingRequestCount, 0)
        cache.setSuspended(false)
        await cache.waitUntilIdle()
        XCTAssertNotNil(frame(cache, keys: [latest], producer: producer).first!)
        XCTAssertEqual(producer.calls, 1)
        cache.setSuspended(true)
        XCTAssertNotNil(frame(cache, keys: [latest], producer: producer).first!)
        await cache.waitUntilIdle()
        XCTAssertEqual(producer.calls, 1)
    }

    func testNewFrameReplacesAnObsoleteQueueBeforeItStarts() async {
        let cache = ScreenshotFilterPreviewCache()
        let producer = RasterProducer()
        let oldKeys = (0..<100).map { _ in key() }
        _ = frame(cache, keys: oldKeys, producer: producer)
        XCTAssertLessThanOrEqual(cache.pendingRequestCount, 64)
        let latest = key()
        _ = frame(cache, keys: [latest], producer: producer)
        await cache.waitUntilIdle()
        XCTAssertEqual(producer.calls, 1)
        XCTAssertEqual(cache.cachedImageCount, 1)
        XCTAssertNotNil(frame(cache, keys: [latest], producer: producer).first!)
    }

    func testOversizedProducerResultFailsOnceInsteadOfGrowingTheCache() async {
        let cache = ScreenshotFilterPreviewCache(byteLimit: 16)
        let producer = RasterProducer()
        let node = key()
        for _ in 0..<3 {
            _ = frame(cache, keys: [node], producer: producer)
            await cache.waitUntilIdle()
        }
        XCTAssertEqual(producer.calls, 1)
        XCTAssertEqual(cache.residentByteCount, 0)
    }

    private func key() -> ScreenshotFilterPreviewCache.Key {
        ScreenshotFilterPreviewCache.Key(
            stateID: UUID(), nodeID: UUID(), sourceRect: CGRect(x: 0, y: 0, width: 32, height: 32), level: 0
        )
    }

    private func frame(
        _ cache: ScreenshotFilterPreviewCache,
        keys: [ScreenshotFilterPreviewCache.Key],
        producer: RasterProducer
    ) -> [CGImage?] {
        cache.beginFrame()
        let result = keys.map { key in cache.image(for: key) { producer.makeImage() } }
        cache.endFrame()
        return result
    }

    private final class RasterProducer: @unchecked Sendable {
        private let lock = NSLock()
        private let fails: Bool
        private(set) var calls = 0
        private(set) var usedMainThread = false
        init(fails: Bool = false) { self.fails = fails }
        func makeImage() -> CGImage? {
            lock.lock()
            calls += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            lock.unlock()
            guard !fails else { return nil }
            return CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }
}
