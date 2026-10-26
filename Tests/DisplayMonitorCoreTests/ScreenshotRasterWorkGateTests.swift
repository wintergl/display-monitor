import Foundation
import XCTest
@testable import DisplayMonitor

final class ScreenshotRasterWorkGateTests: XCTestCase {
    func testConcurrentBackgroundWorkersNeverDecodeTogether() async {
        let gate = ScreenshotRasterWorkGate()
        let counter = ConcurrentCounter()
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                gate.withPermit {
                    counter.enter()
                    Thread.sleep(forTimeInterval: 0.002)
                    counter.leave()
                }
            }
        }.value
        XCTAssertEqual(counter.maximum, 1)
        XCTAssertEqual(counter.finished, 16)
    }

    func testNestedRendererAndFilterScopesReleaseThePermitAfterFailure() async {
        enum Expected: Error { case failure }
        let gate = ScreenshotRasterWorkGate()
        let failed = await Task.detached {
            do {
                try gate.withPermit { try gate.withPermit { throw Expected.failure } }
                return false
            } catch { return true }
        }.value
        XCTAssertTrue(failed)
        let nextResult = await Task.detached { gate.withPermit { 42 } }.value
        XCTAssertEqual(nextResult, 42)
    }

    private final class ConcurrentCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var maximum = 0
        private(set) var finished = 0
        func enter() {
            lock.lock()
            current += 1
            maximum = max(maximum, current)
            lock.unlock()
        }
        func leave() {
            lock.lock()
            current -= 1
            finished += 1
            lock.unlock()
        }
    }
}
