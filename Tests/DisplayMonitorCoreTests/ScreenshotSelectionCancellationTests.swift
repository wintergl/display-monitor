import AppKit
import DisplayMonitorCore
import XCTest

@testable import DisplayMonitor

final class ScreenshotSelectionCancellationTests: XCTestCase {
    @MainActor
    func testCancelWhileFreezeCallbackIsPendingEndsSelectionBeforeCallbackReturns() async throws {
        let deferred = DeferredFrames()
        let controller = makeController { _ in await deferred.wait() }
        let task = selectionTask(controller)
        try await waitUntilStarted(deferred)
        XCTAssertTrue(controller.isSelecting)

        controller.cancel()
        let result = await task.value
        XCTAssertEqual(result, "screenshot_cancelled")
        XCTAssertFalse(controller.isSelecting)
        // A framework callback that disregards cancellation must not reopen panels.
        deferred.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(controller.isSelecting)
    }

    @MainActor
    func testCallerTaskCancellationReleasesPendingFreezeSelection() async throws {
        let deferred = DeferredFrames()
        let controller = makeController { _ in await deferred.wait() }
        let task = selectionTask(controller)
        try await waitUntilStarted(deferred)
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, "screenshot_cancelled")
        XCTAssertFalse(controller.isSelecting)
        deferred.finish()
    }

    @MainActor
    func testFreezeDeadlineReleasesSelectionEvenWhenFrameworkCallbackDoesNotReturn() async throws {
        let deferred = DeferredFrames()
        let controller = makeController(timeoutNanoseconds: 20_000_000) { _ in
            await deferred.wait()
        }
        let task = selectionTask(controller)
        try await waitUntilStarted(deferred)

        let result = await task.value
        XCTAssertEqual(result, "screenshot_selection_prepare_timeout")
        XCTAssertFalse(controller.isSelecting)
        deferred.finish()
    }

    @MainActor
    func testLateFreezeResultFromCancelledSelectionDoesNotAffectNextSelection() async throws {
        let firstFrames = DeferredFrames()
        let secondFrames = DeferredFrames()
        var invocationCount = 0
        let controller = makeController { _ in
            invocationCount += 1
            return await (invocationCount == 1 ? firstFrames : secondFrames).wait()
        }
        let first = selectionTask(controller)
        try await waitUntilStarted(firstFrames)
        controller.cancel()
        _ = await first.value

        let second = selectionTask(controller)
        try await waitUntilStarted(secondFrames)
        firstFrames.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.isSelecting)
        controller.cancel()
        let secondResult = await second.value
        XCTAssertEqual(secondResult, "screenshot_cancelled")
        XCTAssertFalse(controller.isSelecting)
        secondFrames.finish()
    }

    @MainActor
    func testPreparationSuccessAndCancellationBeforeStart() async throws {
        let completed = ScreenshotSelectionPreparation<Int>()
        let value = try await completed.value { 42 }
        XCTAssertEqual(value, 42)
        completed.cancel()

        let cancelled = ScreenshotSelectionPreparation<Int>()
        cancelled.cancel()
        do {
            _ = try await cancelled.value {
                XCTFail("A cancelled preparation must not start work")
                return 0
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeController(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        provider: @escaping @MainActor ([NSScreen]) async -> [CGDirectDisplayID: FrozenScreenshotFrame]
    ) -> ScreenshotWorkspaceController {
        // ArtifactStore initialization does not create files. These tests never
        // call a capture service, open a panel, or write an artifact.
        ScreenshotWorkspaceController(
            artifactStore: ArtifactStore(rootURL: URL(fileURLWithPath: "/private/tmp/unused-selection-test-\(UUID())")),
            frozenFrameProvider: provider,
            preparationTimeoutNanoseconds: timeoutNanoseconds
        )
    }

    @MainActor
    private func selectionTask(_ controller: ScreenshotWorkspaceController) -> Task<String, Never> {
        Task { @MainActor in
            do {
                _ = try await controller.selectCaptureAction()
                return "unexpected_success"
            } catch let error as CaptureError {
                return error.code
            } catch is CancellationError {
                return "task_cancelled"
            } catch {
                return String(describing: error)
            }
        }
    }

    @MainActor
    private func waitUntilStarted(_ deferred: DeferredFrames) async throws {
        for _ in 0..<1_000 {
            if deferred.continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Freeze preparation did not start")
        throw CancellationError()
    }
}

@MainActor
private final class DeferredFrames {
    var continuation: CheckedContinuation<[CGDirectDisplayID: FrozenScreenshotFrame], Never>?

    func wait() async -> [CGDirectDisplayID: FrozenScreenshotFrame] {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: [:])
        continuation = nil
    }
}
