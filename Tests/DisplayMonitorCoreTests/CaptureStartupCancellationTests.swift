import AppKit
import DisplayMonitorCore
import ScreenCaptureKit
import XCTest

@testable import DisplayMonitor

final class CaptureStartupCancellationTests: XCTestCase {
    @MainActor
    func testShutdownDuringScrollResourcePreflightDoesNotCreateArtifactOrStartStream() async throws {
        let provider = DeferredCaptureCapability()
        let resources = CaptureResourceCoordinator(capabilityProvider: provider)
        let input = InputModeCoordinator()
        let root = URL(fileURLWithPath: "/private/tmp/unused-scroll-startup-\(UUID())")
        let store = ArtifactStore(rootURL: root)
        let frames = DeferredShareableContent()
        let source = ScrollCaptureFrameSource { try await frames.wait() }
        let controller = ScrollCaptureSessionController(
            artifactStore: store,
            artifactShelfController: ArtifactShelfController(artifactStore: store),
            resourceCoordinator: resources,
            inputModeCoordinator: input,
            monitorActive: { true },
            frameSource: source
        )
        let operationID = UUID()
        let lease = try XCTUnwrap(input.acquire(.scrollCapture, operationID: operationID))
        var terminalReasons: [InputLeaseReleaseReason] = []
        controller.onTerminal = { terminalReasons.append($0) }
        let selection = try makeSelection()
        let start = Task { @MainActor in
            do {
                try await controller.start(
                    selection: selection,
                    requestedMode: .manual,
                    targetApplicationPID: nil,
                    operationID: operationID,
                    leaseToken: lease
                )
                return "unexpected_success"
            } catch let error as CaptureError {
                return error.code
            } catch {
                return String(describing: error)
            }
        }
        for _ in 0..<1_000 {
            if await provider.hasStarted { break }
            await Task.yield()
        }
        let started = await provider.hasStarted
        XCTAssertTrue(started)
        let release = Task { @MainActor in
            await Task.yield()
            await provider.finish()
        }
        await controller.shutdown()
        await release.value
        let result = await start.value

        XCTAssertEqual(result, "scroll_capture_application_exit")
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(resources.activeResources.isEmpty)
        XCTAssertNil(input.lease)
        XCTAssertEqual(terminalReasons, [.applicationTermination])
        XCTAssertEqual(frames.invocationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testCancelledFrameSourceRejectsRetryUntilLatePreflightFailureSettles() async throws {
        let first = DeferredShareableContent()
        let second = DeferredShareableContent()
        let native = CaptureSessionNativeOperations(prefix: "scroll_capture")
        var callCount = 0
        let source = ScrollCaptureFrameSource(nativeOperations: native) {
            callCount += 1
            return try await (callCount == 1 ? first : second).wait()
        }
        let selection = try makeSelection()
        let firstStart = startTask(source, selection: selection)
        try await waitUntilStarted(first)
        await source.stop()
        let firstResult = await firstStart.value
        XCTAssertEqual(firstResult, "cancelled")
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(native.pendingCount, 1)

        do {
            _ = try await source.start(region: selection.region, displayID: selection.displayID)
            XCTFail("An unresolved native request must reject reentry")
        } catch let error as CaptureError {
            XCTAssertEqual(error.code, "scroll_capture_native_operation_pending")
        }
        XCTAssertEqual(callCount, 1)
        first.fail()
        for _ in 0..<1_000 {
            if native.canStart { break }
            await Task.yield()
        }
        XCTAssertTrue(native.canStart)

        let secondStart = startTask(source, selection: selection)
        try await waitUntilStarted(second)
        XCTAssertTrue(source.isActive)
        XCTAssertEqual(callCount, 2)
        await source.stop()
        let secondResult = await secondStart.value
        XCTAssertEqual(secondResult, "cancelled")
        second.fail()
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(source.latestSequence, 0)
    }

    @MainActor
    func testRecordingCancelledDuringNativePreflightReleasesLeaseAndResourcesBeforeNativeReply() async throws {
        let resources = CaptureResourceCoordinator()
        let input = InputModeCoordinator()
        let root = URL(fileURLWithPath: "/private/tmp/recording-native-cancellation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let native = CaptureSessionNativeOperations(prefix: "recording")
        let frames = DeferredShareableContent()
        let controller = RecordingSessionController(
            artifactStore: store,
            resourceCoordinator: resources,
            inputModeCoordinator: input,
            nativeOperations: native,
            shareableContentProvider: { try await frames.wait() },
            monitorActive: { false }
        )
        let operationID = UUID()
        let lease = try XCTUnwrap(input.acquire(.recordingCapture, operationID: operationID))
        let selection = try makeSelection()
        var completedStartError: String?
        let start = Task { @MainActor in
            do {
                try await controller.start(
                    selection: selection, showsCursor: false,
                    operationID: operationID, leaseToken: lease
                )
                return "unexpected_success"
            } catch let error as CaptureError {
                completedStartError = error.description
                return error.code
            } catch {
                completedStartError = String(describing: error)
                return String(describing: error)
            }
        }
        do {
            try await waitUntilStarted(frames, completedStartError: { completedStartError })
        } catch {
            // A failed setup must still join the start path and release its
            // HUD/resource/lease before the isolated test directory is removed.
            await controller.stop()
            frames.fail()
            _ = await start.result
            XCTAssertFalse(controller.isBusy)
            XCTAssertTrue(resources.activeResources.isEmpty)
            XCTAssertNil(input.lease)
            throw error
        }
        await controller.stop()
        let result = await start.value
        XCTAssertEqual(result, "recording_cancelled")
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(resources.activeResources.isEmpty)
        XCTAssertNil(input.lease)
        XCTAssertEqual(native.pendingCount, 1)
        let artifacts = try await store.artifacts(includeDiscarded: true)
        XCTAssertTrue(artifacts.isEmpty)
        frames.fail()
    }

    @MainActor
    func testScrollControllerCancelInterruptsNativeWaitBeforeCallbackAndDiscardsZeroFrameArtifact() async throws {
        try await assertScrollNativePreflightTermination(shutdown: false)
    }

    @MainActor
    func testScrollControllerShutdownInterruptsNativeWaitBeforeCallbackAndReleasesOwnership() async throws {
        try await assertScrollNativePreflightTermination(shutdown: true)
    }

    @MainActor
    private func assertScrollNativePreflightTermination(shutdown: Bool) async throws {
        let resources = CaptureResourceCoordinator()
        let input = InputModeCoordinator()
        let root = URL(fileURLWithPath: "/private/tmp/scroll-native-cancellation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let native = CaptureSessionNativeOperations(prefix: "scroll_capture")
        let frames = DeferredShareableContent()
        let source = ScrollCaptureFrameSource(nativeOperations: native) { try await frames.wait() }
        let controller = ScrollCaptureSessionController(
            artifactStore: store,
            artifactShelfController: ArtifactShelfController(artifactStore: store),
            resourceCoordinator: resources,
            inputModeCoordinator: input,
            monitorActive: { false },
            frameSource: source
        )
        let operationID = UUID()
        let lease = try XCTUnwrap(input.acquire(.scrollCapture, operationID: operationID))
        let selection = try makeSelection()
        var terminalReasons: [InputLeaseReleaseReason] = []
        controller.onTerminal = { terminalReasons.append($0) }
        let start = Task { @MainActor in
            do {
                try await controller.start(
                    selection: selection, requestedMode: .manual,
                    targetApplicationPID: nil, operationID: operationID, leaseToken: lease
                )
                return "unexpected_success"
            } catch let error as CaptureError { return error.code }
            catch { return String(describing: error) }
        }
        try await waitUntilStarted(frames)
        let cancelledAt = Date()
        if shutdown { await controller.shutdown() }
        else { controller.cancel() }
        let result = await start.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.5, "Must cancel before the 5-second native deadline")
        XCTAssertEqual(result, shutdown ? "scroll_capture_application_exit" : "scroll_capture_cancelled")
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(source.isActive)
        XCTAssertTrue(resources.activeResources.isEmpty)
        XCTAssertNil(input.lease)
        XCTAssertEqual(terminalReasons, [shutdown ? .applicationTermination : .cancelled])
        XCTAssertEqual(native.pendingCount, 1, "UI ownership ends before the uncancellable native reply")
        let artifacts = try await store.artifacts(includeDiscarded: true)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.status, shutdown ? .failed : .discarded)
        frames.fail()
    }

    @MainActor
    func testRecordingCannotStartAfterShutdownReturns() async throws {
        let resources = CaptureResourceCoordinator()
        let input = InputModeCoordinator()
        let controller = RecordingSessionController(
            artifactStore: ArtifactStore(rootURL: URL(fileURLWithPath: "/private/tmp/unused-recording-startup-\(UUID())")),
            resourceCoordinator: resources,
            inputModeCoordinator: input,
            monitorActive: { false }
        )
        await controller.shutdown()
        let operationID = UUID()
        let lease = try XCTUnwrap(input.acquire(.recordingCapture, operationID: operationID))
        do {
            try await controller.start(selection: makeSelection(), showsCursor: false, operationID: operationID, leaseToken: lease)
            XCTFail("A late startup must be rejected")
        } catch let error as CaptureError {
            XCTAssertEqual(error.code, "recording_cancelled")
        }
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(resources.activeResources.isEmpty)
        // A rejected start never accepts ownership of the caller's lease.
        XCTAssertEqual(input.lease?.token, lease)
        input.release(lease, reason: .applicationTermination)
    }

    @MainActor
    private func makeSelection() throws -> ScreenshotWorkspaceController.SelectedRegion {
        ScreenshotWorkspaceController.SelectedRegion(
            displayID: 7,
            region: try ScreenCoordinateAdapter.makeRegion(
                displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                selectionRect: CGRect(x: 20, y: 20, width: 200, height: 100),
                pixelScale: 2
            )
        )
    }

    @MainActor
    private func startTask(
        _ source: ScrollCaptureFrameSource,
        selection: ScreenshotWorkspaceController.SelectedRegion
    ) -> Task<String, Never> {
        Task { @MainActor in
            do {
                _ = try await source.start(region: selection.region, displayID: selection.displayID)
                return "unexpected_success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return String(describing: error)
            }
        }
    }

    @MainActor
    private func waitUntilStarted(
        _ deferred: DeferredShareableContent,
        completedStartError: () -> String? = { nil }
    ) async throws {
        // A native preflight starts only after the real storage actor's disk
        // availability/write probe. Count elapsed time rather than scheduler
        // yields: a fast scheduler can burn 1,000 yields before fsync finishes.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if deferred.continuation != nil { return }
            if let error = completedStartError() {
                XCTFail("Startup exited before native preflight: \(error)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Fake preflight did not start within the storage preflight budget")
        throw CancellationError()
    }
}

private actor DeferredCaptureCapability: CaptureConcurrencyCapabilityProviding {
    var continuation: CheckedContinuation<CaptureSlotCapability, Never>?
    var hasStarted: Bool { continuation != nil }

    func capability(for _: CaptureConcurrencyCombination) async -> CaptureSlotCapability {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: .allowed(evidenceID: "fake-startup-race"))
        continuation = nil
    }
}

@MainActor
private final class DeferredShareableContent {
    var continuation: CheckedContinuation<SCShareableContent, Error>?
    var invocationCount = 0

    func wait() async throws -> SCShareableContent {
        invocationCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func fail() {
        continuation?.resume(throwing: CaptureError(code: "fake_preflight", message: "Fake preflight"))
        continuation = nil
    }
}
