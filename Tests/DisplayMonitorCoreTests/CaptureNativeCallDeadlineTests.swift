import Foundation
import XCTest
import DisplayMonitorCore
@testable import DisplayMonitor

@MainActor
final class CaptureNativeCallDeadlineTests: XCTestCase {
    private let timeout = CaptureError(code: "native_test_timeout", message: "test timeout")

    func testTimeoutReleasesTransitionQueueAndRetiresLateSuccessfulStart() async throws {
        let queue = CaptureTransitionQueue()
        let registry = CaptureNativeRequestRegistry()
        let entered = NativeCallTestLatch()
        let nativeReply = NativeCallTestLatch()
        let retired = NativeCallTestLatch()
        var streamIsRunning = false
        var retireCount = 0
        var settledCount = 0
        let start = queue.submit { [timeout] _ in
            let operationID = registry.begin()
            try await CaptureNativeCallDeadline<Void>().value(
                timeoutNanoseconds: 20_000_000,
                timeoutError: timeout,
                operation: {
                    entered.open()
                    // Deliberately ignores Swift cancellation, like a delayed
                    // native completion handler.
                    await nativeReply.wait()
                    streamIsRunning = true
                },
                onLateResult: { _ in
                    XCTAssertFalse(Task.isCancelled)
                    streamIsRunning = false
                    retireCount += 1
                },
                onSettled: {
                    registry.settle(operationID)
                    settledCount += 1
                    retired.open()
                }
            )
        }
        await entered.wait()
        do {
            try await start.value
            XCTFail("The native request must time out")
        } catch let error as CaptureError {
            XCTAssertEqual(error.code, timeout.code)
        }
        var stopRan = false
        let stop = queue.submit { _ in stopRan = true }
        try await stop.value
        XCTAssertTrue(stopRan)
        XCTAssertEqual(settledCount, 0, "An unresolved native callback still owns its recovery marker")
        XCTAssertFalse(registry.canStart)
        XCTAssertEqual(registry.pendingCount, 1)
        nativeReply.open()
        await retired.wait()
        XCTAssertFalse(streamIsRunning)
        XCTAssertEqual(retireCount, 1)
        XCTAssertEqual(settledCount, 1)
        XCTAssertTrue(registry.canStart)
    }

    func testCancellationReturnsPromptlyButStillRetiresLateResult() async throws {
        let entered = NativeCallTestLatch()
        let nativeReply = NativeCallTestLatch()
        let settled = NativeCallTestLatch()
        var lateResults = 0
        let request = Task { @MainActor [timeout] in
            try await CaptureNativeCallDeadline<Void>().value(
                timeoutNanoseconds: 1_000_000_000,
                timeoutError: timeout,
                operation: {
                    entered.open()
                    await nativeReply.wait()
                },
                onLateResult: { _ in
                    XCTAssertFalse(Task.isCancelled)
                    lateResults += 1
                },
                onSettled: { settled.open() }
            )
        }
        await entered.wait()
        request.cancel()
        do {
            try await request.value
            XCTFail("The caller must observe cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(lateResults, 0)
        nativeReply.open()
        await settled.wait()
        XCTAssertEqual(lateResults, 1)
    }

    func testPendingNativeMarkerIsKeptUntilLateRetirementFinishes() async throws {
        let nativeReply = NativeCallTestLatch()
        let retirementEntered = NativeCallTestLatch()
        let finishRetirement = NativeCallTestLatch()
        let settled = NativeCallTestLatch()
        var pendingNativeOperation = true
        let request = Task { @MainActor [timeout] in
            try await CaptureNativeCallDeadline<Void>().value(
                timeoutNanoseconds: 20_000_000,
                timeoutError: timeout,
                operation: { await nativeReply.wait() },
                onLateResult: { _ in
                    retirementEntered.open()
                    await finishRetirement.wait()
                },
                onSettled: {
                    pendingNativeOperation = false
                    settled.open()
                }
            )
        }
        _ = await request.result
        XCTAssertTrue(pendingNativeOperation)
        nativeReply.open()
        await retirementEntered.wait()
        XCTAssertTrue(pendingNativeOperation)
        finishRetirement.open()
        await settled.wait()
        XCTAssertFalse(pendingNativeOperation)
    }

    func testOnTimeNonSendableResultStaysOnMainActorAndSettlesOnce() async throws {
        let nativeObject = NSObject()
        var settledCount = 0
        var lateCount = 0
        let result = try await CaptureNativeCallDeadline<NSObject>().value(
            timeoutNanoseconds: 1_000_000_000,
            timeoutError: timeout,
            operation: { nativeObject },
            onLateResult: { _ in lateCount += 1 },
            onSettled: { settledCount += 1 }
        )
        XCTAssertTrue(result === nativeObject)
        XCTAssertEqual(settledCount, 1)
        XCTAssertEqual(lateCount, 0)
    }

    func testPendingCircuitRejectsRetryStormWithoutGrowingNativeRequests() async throws {
        let queue = CaptureTransitionQueue()
        let registry = CaptureNativeRequestRegistry()
        let unresolvedNativeCall = registry.begin()
        var issuedNativeRequests = 0
        for _ in 0..<1_000 {
            let retry = queue.submit { _ in
                guard registry.canStart else { return }
                _ = registry.begin()
                issuedNativeRequests += 1
            }
            try await retry.value
        }
        XCTAssertEqual(issuedNativeRequests, 0)
        XCTAssertEqual(registry.pendingCount, 1)
        registry.settle(unresolvedNativeCall)
        XCTAssertTrue(registry.canStart)
        registry.markStopFailure()
        XCTAssertFalse(registry.canStart, "A failed native stop needs process recovery, even after its callback settles")
    }
}

@MainActor
private final class NativeCallTestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
