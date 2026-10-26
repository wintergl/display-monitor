import DisplayMonitorCore
import Foundation
import ScreenCaptureKit
import XCTest
@testable import DisplayMonitor

@MainActor
final class CaptureSessionNativeOperationsTests: XCTestCase {
    func testNeverReturningShareableRequestReleasesWaitButBlocksRetryUntilCallback() async throws {
        let scope = makeScope()
        let native = SessionNativeTestLatch()
        try scope.beginSession()
        let wait = Task { @MainActor in
            try await scope.startupValue(stage: "shareable") { await native.wait() }
        }
        _ = await wait.result
        XCTAssertFalse(scope.canStart)
        XCTAssertEqual(scope.pendingCount, 1)
        for _ in 0..<100 {
            XCTAssertThrowsError(try scope.beginSession())
        }
        XCTAssertEqual(scope.pendingCount, 1)
        native.open()
        try await eventually { scope.canStart }
        try scope.beginSession()
        let value = try await scope.startupValue(stage: "shareable") { NSObject() }
        XCTAssertNotNil(value)
    }

    func testCancelReturnsBeforeNativeReplyAndLateSuccessfulStartRetiresSeparately() async throws {
        let scope = makeScope(startupTimeout: 1_000_000_000)
        let entered = SessionNativeTestLatch()
        let native = SessionNativeTestLatch()
        let retiring = SessionNativeTestLatch()
        let stopReply = SessionNativeTestLatch()
        var running = false
        var lateCount = 0
        try scope.beginSession()
        let wait = Task { @MainActor in
            try await scope.startupValue(
                stage: "start",
                operation: {
                    entered.open()
                    await native.wait()
                    running = true
                },
                onLateResult: { _ in
                    XCTAssertFalse(Task.isCancelled)
                    lateCount += 1
                    try? await scope.stop {
                        retiring.open()
                        await stopReply.wait()
                        running = false
                    }
                }
            )
        }
        await entered.wait()
        scope.cancelStartupWait()
        do { try await wait.value; XCTFail("The UI wait must be cancelled") }
        catch is CancellationError {}
        XCTAssertFalse(running)
        XCTAssertFalse(scope.canStart)
        native.open()
        await retiring.wait()
        XCTAssertTrue(running)
        XCTAssertFalse(scope.canStart)
        XCTAssertEqual(scope.pendingCount, 2)
        stopReply.open()
        try await eventually { scope.canStart }
        XCTAssertFalse(running)
        XCTAssertEqual(lateCount, 1)
    }

    func testCallerCancellationAndLateFailureDoNotPoisonNextSession() async throws {
        let scope = makeScope(startupTimeout: 1_000_000_000)
        let entered = SessionNativeTestLatch()
        let native = SessionNativeTestLatch()
        try scope.beginSession()
        let wait = Task { @MainActor in
            try await scope.startupValue(stage: "shareable") {
                entered.open()
                await native.wait()
                throw CaptureError(code: "fake", message: "fake native failure")
            }
        }
        await entered.wait()
        wait.cancel()
        do { try await wait.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertThrowsError(try scope.beginSession())
        native.open()
        try await eventually { scope.canStart }
        XCTAssertFalse(scope.needsRecovery)
        try scope.beginSession()
        try await scope.startupValue(stage: "start") {}
    }

    func testStopTimeoutKeepsMarkerAndLateStopFailureRequiresRecovery() async throws {
        let scope = makeScope()
        let native = SessionNativeTestLatch()
        let stop = Task { @MainActor in
            try await scope.stop {
                await native.wait()
                throw CaptureError(code: "fake_stop", message: "fake stop failure")
            }
        }
        do { try await stop.value; XCTFail("Expected stop timeout") }
        catch let error as CaptureError { XCTAssertEqual(error.code, "test_native_stop_timeout") }
        XCTAssertEqual(scope.pendingCount, 1)
        XCTAssertThrowsError(try scope.beginSession())
        native.open()
        try await eventually { scope.pendingCount == 0 }
        XCTAssertTrue(scope.needsRecovery)
        XCTAssertThrowsError(try scope.beginSession())
    }

    func testStopSuccessAlreadyStoppedAndImmediateFailure() async throws {
        let scope = makeScope()
        try await scope.stop {}
        try await scope.stop { throw NSError(domain: SCStreamErrorDomain, code: -3808) }
        XCTAssertTrue(scope.canStart)
        do {
            try await scope.stop { throw CaptureError(code: "fake_stop", message: "fake") }
            XCTFail("Expected native failure")
        } catch {}
        XCTAssertEqual(scope.pendingCount, 0)
        XCTAssertTrue(scope.needsRecovery)
    }

    private func makeScope(startupTimeout: UInt64 = 20_000_000) -> CaptureSessionNativeOperations {
        CaptureSessionNativeOperations(
            prefix: "test", startupTimeoutNanoseconds: startupTimeout,
            stopTimeoutNanoseconds: 100_000_000
        )
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Native request did not settle")
        throw CancellationError()
    }
}

@MainActor
private final class SessionNativeTestLatch {
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
        continuations.forEach { $0.resume() }
    }
}
