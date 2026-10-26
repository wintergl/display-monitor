import XCTest
@testable import DisplayMonitor

@MainActor
final class CaptureTransitionQueueTests: XCTestCase {
    func testStopWaitsForPendingStartAndCannotEraseTheNextStream() async throws {
        let queue = CaptureTransitionQueue()
        let startEntered = TransitionTestLatch()
        let finishStart = TransitionTestLatch()
        let stopEntered = TransitionTestLatch()
        let finishStop = TransitionTestLatch()
        var stream: String?
        var events: [String] = []

        let start = queue.submit { _ in
            events.append("start.begin")
            startEntered.open()
            await finishStart.wait()
            stream = "old"
            events.append("start.end")
        }
        await startEntered.wait()
        let stop = queue.submit { _ in
            events.append("stop.begin")
            stream = nil
            stopEntered.open()
            await finishStop.wait()
            events.append("stop.end")
        }
        let restart = queue.submit { _ in
            stream = "new"
            events.append("restart")
        }
        XCTAssertEqual(events, ["start.begin"])
        finishStart.open()
        await stopEntered.wait()
        XCTAssertNil(stream)
        XCTAssertEqual(events, ["start.begin", "start.end", "stop.begin"])
        finishStop.open()
        try await start.value
        try await stop.value
        try await restart.value
        XCTAssertEqual(stream, "new")
        XCTAssertEqual(events, ["start.begin", "start.end", "stop.begin", "stop.end", "restart"])
    }

    func testStopInvalidatesInFlightStartBeforeNativeStreamCreation() async throws {
        let queue = CaptureTransitionQueue()
        let lookupEntered = TransitionTestLatch()
        let finishLookup = TransitionTestLatch()
        var createdStream = false
        let start = queue.submit { revision in
            lookupEntered.open()
            await finishLookup.wait()
            guard queue.isCurrent(revision) else { throw CancellationError() }
            createdStream = true
        }
        await lookupEntered.wait()
        let stop = queue.submit { _ in }
        finishLookup.open()
        do {
            try await start.value
            XCTFail("A start superseded by stop must be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try await stop.value
        XCTAssertFalse(createdStream)
    }

    func testCancelledQueuedStartDoesNotRunOrBlockTheNextStop() async throws {
        let queue = CaptureTransitionQueue()
        let entered = TransitionTestLatch()
        let finish = TransitionTestLatch()
        let first = queue.submit { _ in
            entered.open()
            await finish.wait()
        }
        await entered.wait()
        var cancelledStartRan = false
        let cancelled = queue.submit { _ in cancelledStartRan = true }
        cancelled.cancel()
        var stopped = false
        let stop = queue.submit { _ in stopped = true }
        finish.open()
        try await first.value
        _ = await cancelled.result
        try await stop.value
        XCTAssertFalse(cancelledStartRan)
        XCTAssertTrue(stopped)
    }

    func testFailedStartDoesNotPoisonLaterTransitions() async throws {
        let queue = CaptureTransitionQueue()
        let failed = queue.submit { _ in throw TransitionTestError.failed }
        var stopped = false
        let stop = queue.submit { _ in stopped = true }
        _ = await failed.result
        try await stop.value
        XCTAssertTrue(stopped)
    }
}

private enum TransitionTestError: Error { case failed }

@MainActor
private final class TransitionTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
