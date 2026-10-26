import AppKit
import DisplayMonitorCore
import XCTest

@testable import DisplayMonitor

final class ApplicationTerminationTests: XCTestCase {
    @MainActor
    func testFirstQuitUnwindsAndRepeatedQuitDoesNotDuplicateCleanup() async throws {
        let cleanup = SuspendedCleanup()
        var terminationCount = 0
        let coordinator = ApplicationTerminationCoordinator(
            cleanup: { await cleanup.run() },
            requestTermination: { terminationCount += 1 }
        )

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateCancel)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateCancel)
        try await eventually { cleanup.callCount == 1 }
        XCTAssertEqual(coordinator.state, .cleaning)
        XCTAssertEqual(terminationCount, 0)

        cleanup.finish()
        try await eventually { terminationCount == 1 }
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateNow)
        XCTAssertFalse(coordinator.didTimeOut)
        XCTAssertEqual(cleanup.callCount, 1)
    }

    @MainActor
    func testDeadlineExitsEvenWhenCleanupIgnoresCancellationAndLateCompletionIsIgnored() async throws {
        let cleanup = SuspendedCleanup()
        var terminationCount = 0
        var completions: [Bool] = []
        let coordinator = ApplicationTerminationCoordinator(
            timeoutSeconds: 0.02,
            cleanup: { await cleanup.run() },
            requestTermination: { terminationCount += 1 },
            onCompletion: { completions.append($0) }
        )

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateCancel)
        try await eventually { terminationCount == 1 }
        XCTAssertTrue(coordinator.didTimeOut)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateNow)
        cleanup.finish()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(completions, [true])
    }

    @MainActor
    func testShellTerminationBlocksNewCaptureAndReleasesInputAndResources() async throws {
        let suite = "DisplayMonitor.TerminationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor.TerminationTests.\(UUID().uuidString)")
        let monitor = AppModel(dependencies: .standard(settingsStore: SettingsStore(defaults: defaults)))
        let router = TerminationShortcutRouter()
        let shell = ToolSuiteShell(monitor: monitor, shortcutRouter: router, artifactRootURL: root)
        let lease = try XCTUnwrap(shell.inputModeCoordinator.acquire(.captureWorkflow))
        _ = await shell.captureResourceCoordinator.acquire(.still, monitorActive: false)

        shell.beginTermination()
        shell.beginTermination()
        shell.captureRegion()
        shell.captureFullScreen()
        await shell.startIfNeeded()
        XCTAssertEqual(router.stopCount, 1)
        XCTAssertFalse(shell.isStarted)
        XCTAssertEqual(shell.inputModeCoordinator.lease?.token, lease)
        XCTAssertTrue(shell.inputModeCoordinator.directPointerSuspended)

        await shell.prepareForTermination()
        XCTAssertNil(shell.inputModeCoordinator.lease)
        XCTAssertTrue(shell.captureResourceCoordinator.activeResources.isEmpty)
        XCTAssertTrue(shell.inputModeCoordinator.directPointerSuspended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testPreviewQuitRoutesThroughOwnerWithoutDoingIndependentShutdown() throws {
        let suite = "DisplayMonitor.PreviewQuitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AppModel(dependencies: .standard(settingsStore: SettingsStore(defaults: defaults)))
        var requests = 0
        monitor.onQuitRequested = { requests += 1 }
        monitor.quit()
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testTerminationRejectsAnAcquisitionThatWasAlreadyWaitingOnCapability() async throws {
        let provider = DeferredCapabilityProvider()
        let resources = CaptureResourceCoordinator(capabilityProvider: provider)
        let request = Task { await resources.acquire(.recording, monitorActive: true) }
        let deadline = Date().addingTimeInterval(1)
        while !(await provider.hasPendingRequest), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        resources.stopAcceptingRequests()
        await provider.finish()
        let decision = await request.value
        guard case .rejected = decision else { return XCTFail("Late capability must not acquire a resource during exit") }
        XCTAssertTrue(resources.activeResources.isEmpty)
    }

    @MainActor
    func testTerminatedGifServiceRejectsQueuedExportBeforeReadingOrCreatingFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor.GifTerminationTests.\(UUID())")
        let service = GifExportService(
            artifactStore: ArtifactStore(rootURL: root),
            isExtensionEnabled: { true },
            recordingBusy: { false }
        )
        let operationID = UUID()
        let source = ArtifactManifest(
            id: UUID(),
            kind: .recording,
            status: .completed,
            canonicalURL: root.appendingPathComponent("unread.mp4"),
            temporaryURL: root.appendingPathComponent("unread.mp4.tmp"),
            originOperationID: operationID,
            activeOperationID: operationID
        )
        service.beginTermination()
        do {
            _ = try await service.export(from: source)
            XCTFail("Export must be rejected after termination begins")
        } catch is CancellationError {
        }
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Lifecycle did not complete within its test deadline")
    }
}

@MainActor
private final class SuspendedCleanup {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TerminationShortcutRouter: ShortcutRouting {
    var registrations: [GlobalShortcutRegistration] = []
    private(set) var stopCount = 0
    var hasSafeOptionChordRegistration: Bool { true }

    func start(bindings: [ShortcutBinding], onCommand: @escaping (ToolSuiteCommand) -> Void) {}
    func stop() { stopCount += 1 }
}

private actor DeferredCapabilityProvider: CaptureConcurrencyCapabilityProviding {
    private var continuation: CheckedContinuation<CaptureSlotCapability, Never>?
    var hasPendingRequest: Bool { continuation != nil }

    func capability(for combination: CaptureConcurrencyCombination) async -> CaptureSlotCapability {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: .allowed(evidenceID: "isolated-test"))
        continuation = nil
    }
}
