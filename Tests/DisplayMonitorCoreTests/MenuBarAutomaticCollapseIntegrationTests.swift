import AppKit
import CoreGraphics
import Dispatch
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarAutomaticCollapseIntegrationTests: XCTestCase {
    func testClockAccessReleasesAssertionAndInvalidatesLateNativeCompletion() async throws {
        let fixture = Fixture()
        fixture.holdNativeCompletion = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { fixture.beginCount == 1 }
        coordinator.prepareForSystemPanelAccess()
        XCTAssertTrue(fixture.assertions[0].invalidated)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        fixture.completions[0](nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testCollapsePageRereadUsesTwoFreshOpaquePhysicalSnapshots() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawPhysicalResult(opaque: true), fixture.rawPhysicalResult(opaque: true)]
        fixture.beforeDiscover = { _ in XCTFail("Collapse reread must not use logical discovery") }
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.readInventory(preferCurrentPhysical: true)
        await eventually { !coordinator.isReading }
        XCTAssertTrue(coordinator.coverageIsComplete)
        XCTAssertEqual(coordinator.inventory?.items.count, 2)
        XCTAssertEqual(try coordinator.inventory?.validatedLayouts().count, 1)
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 2)
        XCTAssertEqual(fixture.beginCount, 0)
        await fixture.finish(coordinator)
    }

    func testCollapsePageRereadRejectsInvalidRawWithoutLogicalFallback() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawPhysicalResult(opaque: true), fixture.rawResult(complete: false)]
        fixture.beforeDiscover = { _ in XCTFail("Rejected raw proof must not fall back to a plausible logical inventory") }
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.readInventory(preferCurrentPhysical: true)
        await eventually { !coordinator.isReading }
        XCTAssertFalse(coordinator.coverageIsComplete)
        XCTAssertEqual(coordinator.inventory?.coverage.isComplete, false)
        XCTAssertTrue(coordinator.message.contains("两次完整读取"))
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 2)
        XCTAssertEqual(fixture.beginCount, 0)
        await fixture.finish(coordinator)
    }

    func testCollapsePageRereadRejectsOwnedEntryChangesDuringSampling() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 2)
        var visibleItemCount = 1
        fixture.beforeRawRead = { count in if count == 2 { visibleItemCount = 2 } }
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: visibleItemCount)
        }
        coordinator.readInventory(preferCurrentPhysical: true)
        await eventually { !coordinator.isReading }
        XCTAssertFalse(coordinator.coverageIsComplete)
        XCTAssertTrue(coordinator.message.contains("保持展开"))
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 2)
        await fixture.finish(coordinator)
    }

    func testCollapsePageRereadCancelledByTerminationCannotPublishOldInventory() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 2)
        var releaseRead = false
        var readSawCancellation = false
        fixture.beforeRawRead = { _ in
            while !releaseRead {
                readSawCancellation = readSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.readInventory(preferCurrentPhysical: true)
        await eventually { fixture.rawReadCount == 1 }
        coordinator.beginTermination()
        let shutdown = Task { @MainActor in await coordinator.shutdown() }
        await eventually { readSawCancellation }
        XCTAssertNil(coordinator.inventory)
        releaseRead = true
        await shutdown.value
        XCTAssertNil(coordinator.inventory)
        XCTAssertFalse(coordinator.isReading)
        XCTAssertEqual(fixture.rawReadCount, 1)
        XCTAssertEqual(fixture.scanCount, 0)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testCollapsePageRereadKeepsLegacyDiscoveryWhenOwnedEvidenceUnavailable() async throws {
        for preferCurrentPhysical in [false, true] {
            let fixture = Fixture()
            fixture.rawEnabled = true
            let coordinator = try fixture.coordinator()
            if !preferCurrentPhysical {
                coordinator.ownedStatusItemEvidence = {
                    .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                          mainEntryVisible: true, visibleItemCount: 1)
                }
            }
            if preferCurrentPhysical { coordinator.readInventory(preferCurrentPhysical: true) }
            else { coordinator.readInventory() }
            await eventually { !coordinator.isReading }
            XCTAssertTrue(coordinator.coverageIsComplete)
            XCTAssertEqual(fixture.scanCount, 1)
            XCTAssertEqual(fixture.rawReadCount, 0)
            await fixture.finish(coordinator)
        }
    }

    func testUnverifiedLaunchLocationNeverHidesOrRewritesSavedPreference() async throws {
        let fixture = Fixture()
        fixture.hidingLaunchIssue = MenuBarHidingLaunchPolicy.unavailableReason(
            applicationURL: URL(fileURLWithPath: "/tmp/Display Monitor.app"))
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(coordinator.isCollapseAvailable)
        XCTAssertTrue(coordinator.featureAvailabilityMessage.contains("应用程序"))
        XCTAssertEqual(fixture.beginCount, 0)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        await fixture.finish(coordinator)
    }

    func testHidingLaunchLocationRequiresSystemApplicationsAndResolvesSymlinks() throws {
        XCTAssertNil(MenuBarHidingLaunchPolicy.unavailableReason(
            applicationURL: URL(fileURLWithPath: "/Applications/Display Monitor.app")))
        for path in ["/tmp/Display Monitor.app", "/Users/test/Applications/Display Monitor.app",
                     "/Applications-old/Display Monitor.app", "/Applications/DisplayMonitor"] {
            XCTAssertNotNil(MenuBarHidingLaunchPolicy.unavailableReason(
                applicationURL: URL(fileURLWithPath: path)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Foundation does not resolve dangling links. Use any existing app in
        // /Applications (for example Xcode on CI), never require Display Monitor
        // to have been installed and never write to the system app directory.
        let applications = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil)
        guard let target = applications.first(where: {
            $0.pathExtension == "app"
                && $0.resolvingSymlinksInPath().deletingLastPathComponent().path == "/Applications"
        }) else {
            throw XCTSkip("The symlink check needs an existing app in /Applications")
        }
        let link = root.appendingPathComponent("LaunchPolicyFixture.app")
        try FileManager.default.createSymbolicLink(atPath: link.path,
            withDestinationPath: target.path)
        XCTAssertNil(MenuBarHidingLaunchPolicy.unavailableReason(applicationURL: link))

        let outside = root.appendingPathComponent("Outside.app")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideLink = root.appendingPathComponent("OutsideLink.app")
        try FileManager.default.createSymbolicLink(atPath: outsideLink.path,
            withDestinationPath: outside.path)
        XCTAssertNotNil(MenuBarHidingLaunchPolicy.unavailableReason(applicationURL: outsideLink))
    }

    func testSettingsCollapseCommandUsesExecutionStateNotFailedStartupIntent() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 2)
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier, mainEntryVisible: true, visibleItemCount: 1)
        }
        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(coordinator.canToggleCollapse, "cold settings command can obtain its own current proof")
        coordinator.toggleCollapseFromSettings()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 2)
        coordinator.toggleCollapseFromSettings()
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(fixture.assertions[0].invalidated)
        await fixture.finish(coordinator)
    }

    func testStartupUsesFreshPhysicalProofWithoutReadingOwnAppKitMenu() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 2)
        fixture.beforeDiscover = { _ in XCTFail("Must not require off-main reads of own menu") }
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier, mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 2)
        await fixture.finish(coordinator)
    }

    func testRejectedStartupPhysicalProofDoesNotLoopBackIntoBootstrap() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawResult(complete: false), fixture.rawResult(complete: false)]
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier, mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertLessThanOrEqual(fixture.rawReadCount, 4)
        await fixture.finish(coordinator)
    }

    func testStartupRetryRechecksPhysicalEntryAfterInitialProxyIsUnavailable() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawResult(complete: false), fixture.rawResult(complete: false),
                              fixture.rawPhysicalResult(opaque: true), fixture.rawPhysicalResult(opaque: true)]
        fixture.results = Array(repeating: fixture.result(complete: false), count: 10)
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.rawReadCount, 4)
        XCTAssertEqual(fixture.scanCount, 1, "Recovery must not keep using the failed logical path")
        XCTAssertEqual(fixture.delays.filter { $0 == .seconds(1) }.count, 1)
        await fixture.finish(coordinator)
    }

    func testRepeatedPhysicalBootstrapFailureDoesNotResetRetryBudget() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = Array(repeating: fixture.rawResult(complete: false), count: 20)
        fixture.results = Array(repeating: fixture.result(complete: false), count: 20)
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.prepare()
        await eventually { coordinator.message.contains("自动重试 3 次仍未就绪") }
        XCTAssertEqual(fixture.beginCount, 0)
        XCTAssertEqual(fixture.rawReadCount, 8)
        XCTAssertEqual(fixture.scanCount, 4)
        for delay: Duration in [.seconds(1), .seconds(2), .seconds(4)] {
            XCTAssertEqual(fixture.delays.filter { $0 == delay }.count, 1)
        }
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        await fixture.finish(coordinator)
    }
    func testDemoParityDoesNotUndoNativeRequestForUnreadableDiagnosticAX() async throws {
        let fixture = Fixture()
        fixture.physicalResultVerified = nil
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertEqual(fixture.physicalVerificationCount, 0)
        await fixture.finish(coordinator)
    }

    func testDemoParityKeepsAssertionWhenDiagnosticAXWouldReportFailure() async throws {
        let fixture = Fixture()
        fixture.physicalResultVerified = false
        let coordinator = try fixture.coordinator()
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: true, visibleItemCount: 1)
        }
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertTrue(coordinator.message.contains("系统已接受持续收起请求"))
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertEqual(fixture.physicalVerificationCount, 0)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        await fixture.finish(coordinator)
    }
    func testCrashDiagnosticModeNeverStartsNativeHidingOrChangesPreference() async throws {
        let fixture = Fixture()
        fixture.disableNativeHidingForDiagnostics = true
        fixture.instantEnabled = true
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(coordinator.isCollapseAvailable)
        XCTAssertEqual(fixture.beginCount, 0)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
        await fixture.finish(coordinator)
    }
    func testAcknowledgedNativeHideWithMissingEntryRestoresAndNeverRetries() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        var visible = true
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                  mainEntryVisible: visible, visibleItemCount: visible ? 1 : 0)
        }
        fixture.beforeNativeCompletion = { visible = false }
        coordinator.prepare()
        await eventually { coordinator.message.contains("本次运行不再尝试隐藏") }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertTrue(fixture.assertions[0].invalidated)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertFalse(coordinator.isPreparingCollapse)
        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertTrue(coordinator.wantsPersistentCollapse, "must preserve saved preference")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        coordinator.toggleCurrentCollapseVisibility()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.beginCount, 1, "neither observer nor click may repeat an unsafe native hide")
        await fixture.finish(coordinator)
    }

    func testRevealWinsBeforeDelayedNativeAcknowledgement() async throws {
        let fixture = Fixture()
        fixture.holdNativeCompletion = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { fixture.completions.count == 1 }
        XCTAssertFalse(coordinator.isCollapsed)
        coordinator.toggleCurrentCollapseVisibility()
        fixture.completions[0](nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(fixture.assertions[0].invalidated)
        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        await fixture.finish(coordinator)
    }
    func testIncompleteStartupReadRetriesFreshInventoryBeforeHiding() async throws {
        let fixture = Fixture()
        fixture.results = [fixture.result(complete: false), fixture.result(), fixture.result()]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.scanCount, 3)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.delays, [.milliseconds(900), .seconds(1)])
        await fixture.finish(coordinator)
    }

    func testPreparationChangeRetriesEntirePreparationBeforeHiding() async throws {
        let fixture = Fixture()
        fixture.revisions = ["old", "new", "stable", "stable"]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.scanCount, 4)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.delays, [.milliseconds(900), .seconds(1)])
        XCTAssertTrue(coordinator.notes.contains { $0.contains("菜单栏发生变化") })
        await fixture.finish(coordinator)
    }

    func testPermissionBecomingReadyDuringRetryRestoresCollapse() async throws {
        let fixture = Fixture()
        fixture.permissionGranted = false
        fixture.onSleep = { count in
            if count == 2 { fixture.permissionGranted = true }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.delays, [.milliseconds(900), .seconds(1)])
        await fixture.finish(coordinator)
    }

    func testPermissionGrantAfterExhaustionResumesWhenApplicationBecomesActive() async throws {
        let fixture = Fixture()
        fixture.permissionGranted = false
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.message.contains("自动重试 3 次仍未就绪") }
        XCTAssertEqual(fixture.beginCount, 0)
        fixture.permissionGranted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testNativeFailureReleasesOldAssertionAndRetriesWithFreshPlan() async throws {
        let fixture = Fixture()
        fixture.nativeFailuresRemaining = 1
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 2)
        XCTAssertEqual(fixture.scanCount, 4)
        XCTAssertTrue(fixture.assertions[0].invalidated)
        XCTAssertFalse(fixture.assertions[1].invalidated)
        await fixture.finish(coordinator)
    }

    func testNativeTimeoutStopsAfterThreeRetriesAndReleasesEveryAssertion() async throws {
        let fixture = Fixture()
        fixture.nativeNeverCompletes = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.message.contains("自动重试 3 次仍未就绪") }
        XCTAssertEqual(fixture.beginCount, 4)
        XCTAssertEqual(fixture.delays, [.milliseconds(900), .seconds(1), .seconds(2), .seconds(4)])
        XCTAssertTrue(fixture.assertions.allSatisfy(\.invalidated))
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertFalse(coordinator.isPreparingCollapse)
        await fixture.finish(coordinator)
    }

    func testPermanentCrossBoundaryConflictDoesNotRetryOrHide() async throws {
        let fixture = Fixture()
        fixture.results = [fixture.result(crossBoundary: true)]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.message.contains("长期收起未恢复") }
        XCTAssertEqual(fixture.scanCount, 1)
        XCTAssertEqual(fixture.delays, [.milliseconds(900)])
        XCTAssertEqual(fixture.beginCount, 0)
        await fixture.finish(coordinator)
    }

    func testManualRevealCancelsQueuedRetry() async throws {
        let fixture = Fixture()
        fixture.results = [fixture.result(complete: false)]
        fixture.holdRetry = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { fixture.delays.count == 2 }
        coordinator.revealTemporarily()
        await eventually { fixture.heldRetryWasCancelled }
        XCTAssertEqual(fixture.scanCount, 1)
        XCTAssertEqual(fixture.beginCount, 0)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        await fixture.finish(coordinator)
    }

    func testDisableTerminationAndTemporaryInteractionCancelQueuedRetry() async throws {
        for action in 0..<4 {
            let fixture = Fixture()
            fixture.results = [fixture.result(complete: false)]
            fixture.holdRetry = true
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { fixture.delays.count == 2 }
            switch action {
            case 0: coordinator.setPersistentCollapseDesired(false)
            case 1: coordinator.beginTermination()
            case 2:
                let token = coordinator.beginTemporaryRevealInteraction()
                XCTAssertNotNil(token)
                if let token {
                    coordinator.endTemporaryRevealInteraction(token, shouldRecollapse: false)
                }
            default: coordinator.prepareForOrderEditing()
            }
            await eventually { fixture.heldRetryWasCancelled }
            XCTAssertEqual(fixture.scanCount, 1)
            XCTAssertEqual(fixture.beginCount, 0)
            await fixture.finish(coordinator)
        }
    }

    func testLateNativeCompletionCannotUndoManualReveal() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        fixture.completions[0](nil)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertTrue(fixture.assertions[0].invalidated)
        await fixture.finish(coordinator)
    }

    func testPrimaryClickTogglesByLastUserIntent() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.quickBarCaptureCount, 1)

        coordinator.toggleCurrentCollapseVisibility()
        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(fixture.assertions[0].invalidated)

        coordinator.toggleCurrentCollapseVisibility()
        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 2)
        XCTAssertEqual(
            fixture.scanCount,
            3,
            "显式第二击应只保留准备阶段的一次 fresh discover"
        )
        XCTAssertEqual(
            fixture.quickBarCaptureCount,
            1,
            "显式第二击不应等待可选图标截图"
        )
        await fixture.finish(coordinator)
    }

    func testInstantSecondClickDoesNotWaitForFullDiscoveryOrTopology() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.physicalGuardCount, 1)
        fixture.beforeDiscover = { _ in XCTFail("第二击不得等待全量发现") }
        fixture.beforeTopologySnapshot = { _ in XCTFail("第二击不得等待全量拓扑") }

        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }

        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.topologyReadCount, 2)
        XCTAssertEqual(fixture.physicalGuardCount, 2)
        XCTAssertEqual(fixture.quickBarCaptureCount, 1)
        await fixture.finish(coordinator)
    }

    func testRawStructureSecondClickUsesFreshAppsAfterGuardAndNoFullRead() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.rawReadCount, 2)
        XCTAssertEqual(fixture.physicalGuardCount, 0)
        XCTAssertEqual(fixture.scanCount, 2)
        fixture.events = []
        fixture.beforeDiscover = { _ in XCTFail("raw 第二击不得全量读取") }
        fixture.beforeTopologySnapshot = { _ in XCTFail("raw 第二击不得读取全量拓扑") }
        fixture.beforeRawRead = { count in
            if count == 3 {
                fixture.additionalApplications = [RunningAppSnapshot(
                    bundleIdentifier: "example.fresh", name: "Fresh", processIdentifier: 99
                )]
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.rawReadCount, 3)
        XCTAssertEqual(fixture.physicalGuardCount, 0)
        XCTAssertTrue(fixture.plans.last?.allowedBundleIdentifiers.contains("example.fresh") == true)
        XCTAssertEqual(fixture.events, ["apps", "raw", "apps", "begin"])
        await fixture.finish(coordinator)
    }

    func testRawMismatchAndIncompleteGuardFallBackToFullSafeDiscovery() async throws {
        for complete in [true, false] {
            let fixture = Fixture()
            fixture.rawEnabled = true
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { coordinator.isCollapsed }
            fixture.rawResults = [fixture.rawResult(tag: "changed", complete: complete)]
            fixture.events = []
            coordinator.toggleCurrentCollapseVisibility()
            coordinator.toggleCurrentCollapseVisibility()
            await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
            XCTAssertGreaterThan(fixture.scanCount, 2)
            let guardIndex = try XCTUnwrap(fixture.events.firstIndex(of: "raw"))
            let discoverIndex = try XCTUnwrap(fixture.events.firstIndex(of: "discover"))
            let beginIndex = try XCTUnwrap(fixture.events.firstIndex(of: "begin"))
            XCTAssertLessThan(guardIndex, discoverIndex)
            XCTAssertLessThan(discoverIndex, beginIndex)
            await fixture.finish(coordinator)
        }
    }

    func testDifferentRawSnapshotsAroundFullReadCannotPrepareInstantPlan() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawResult(tag: "a"), fixture.rawResult(tag: "b")]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertGreaterThan(fixture.scanCount, 2, "不相等的前后围栏不得授权缓存路径")
        await fixture.finish(coordinator)
    }

    func testShutdownDrainsCancelledRawGuardAndLateReturnCannotHide() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var release = false
        var cancelled = false
        fixture.beforeRawRead = { count in
            guard count == 3 else { return }
            while !release {
                cancelled = cancelled || Task.isCancelled
                await Task.yield()
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.rawReadCount == 3 }
        coordinator.toggleCurrentCollapseVisibility()
        var shutdownFinished = false
        let shutdown = Task { @MainActor in
            await coordinator.shutdown()
            shutdownFinished = true
        }
        await eventually { cancelled }
        XCTAssertFalse(shutdownFinished)
        release = true
        await shutdown.value
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testRawWarmupRefreshesExpandedBaselineWithoutHiding() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.prewarmingEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.rawReadCount == 4 }
        await Task.yield()
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 3)
        XCTAssertEqual(fixture.rawReadCount, 5)
        await fixture.finish(coordinator)
    }

    func testSecondClickRenewsPhysicalBaselineAfterCollapsedTopologyOmissionWithoutWarmup() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.topologyMonitoringInterval = 0.01
        fixture.rawResults = [fixture.rawPhysicalResult(), fixture.rawPhysicalResult()]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.liveTopology = MenuBarTopologySnapshot(items: [])
        await eventually { fixture.topologyCompletedReadCount >= 3 }
        await Task.yield()
        fixture.rawResults = [fixture.rawPhysicalResult(tag: "revealed-container-order")]
        fixture.beforeDiscover = { _ in XCTFail("Second click must not restart full discovery") }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.rawReadCount, 3)
        await fixture.finish(coordinator)
    }

    func testDirectOpaquePhysicalSecondClickNeedsNoWarmupFullScanOrRepeatedTopology() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.rawResults = [fixture.rawResult(complete: false), fixture.rawResult(complete: false)]
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier), mainEntryVisible: true, visibleItemCount: 1)
        }
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 4)
        fixture.beforeDiscover = { _ in XCTFail("Physical-only clicks must not rediscover every application") }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.topologyReadCount, 3)
        fixture.beforeTopologySnapshot = { _ in XCTFail("Second cycle must not wait for logical topology") }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 3 }
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.rawReadCount, 6, "Every click must complete TWO fresh physical reads")
        XCTAssertEqual(fixture.quickBarCaptureCount, 1)
        XCTAssertEqual(fixture.plans.last?.targetBundleIdentifiers, ["example.target"])
        await fixture.finish(coordinator)
    }

    func testDirectPhysicalOwnedEntryChangeBetweenReadsCannotReachNative() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var visible = true
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier), mainEntryVisible: visible, visibleItemCount: visible ? 1 : 0)
        }
        fixture.rawResults = Array(repeating: fixture.rawPhysicalResult(opaque: true), count: 2)
        fixture.beforeRawRead = { count in if count == 4 { visible = false } }
        var release = false
        fixture.beforeDiscover = { _ in while !release { await Task.yield() } }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.scanCount == 3 }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        release = true
        await fixture.finish(coordinator)
    }

    func testDirectPhysicalReadIsCancelledAndDrainedWhenThirdClickAndExitWin() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.ownedStatusItemEvidence = {
            .init(processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier), mainEntryVisible: true, visibleItemCount: 1)
        }
        fixture.rawResults = [fixture.rawPhysicalResult(opaque: true)]
        var release = false
        var cancelled = false
        fixture.beforeRawRead = { count in
            if count == 3 {
                while !release { cancelled = cancelled || Task.isCancelled; await Task.yield() }
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.rawReadCount == 3 }
        coordinator.toggleCurrentCollapseVisibility()
        var finished = false
        let shutdown = Task { @MainActor in await coordinator.shutdown(); finished = true }
        await eventually { cancelled }
        XCTAssertFalse(finished)
        release = true
        await shutdown.value
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.rawReadCount, 3)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testExplicitSecondClickRetryNeverReintroducesOptionalScreenshotCapture() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let capturesBeforeClick = fixture.quickBarCaptureCount
        fixture.results = [fixture.result(targetX: 12), fixture.result(targetX: 12)]
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.quickBarCaptureCount, capturesBeforeClick)
        XCTAssertTrue(fixture.delays.contains(.seconds(1)), "Fixture must have exercised a retry")
        await fixture.finish(coordinator)
    }

    func testIndependentPhysicalBaselineCannotBypassSessionSuspendOrPermissionRevocation() async throws {
        for suspended in [false, true] {
            let fixture = Fixture()
            fixture.rawEnabled = true
            fixture.rawResults = [fixture.rawPhysicalResult(), fixture.rawPhysicalResult()]
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { coordinator.isCollapsed }
            coordinator.revealTemporarily()
            if suspended {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                for _ in 0..<10 { await Task.yield() }
            } else {
                fixture.permissionGranted = false
            }
            coordinator.toggleCurrentCollapseVisibility()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(fixture.beginCount, 1)
            XCTAssertFalse(coordinator.isCollapsed)
            await fixture.finish(coordinator)
        }
    }

    func testAnimationMismatchWarmupRetriesOnceThenUsesFreshGuard() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.prewarmingEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.rawResults = [fixture.rawResult(tag: "animation-a"), fixture.rawResult(tag: "animation-b"),
                              fixture.rawResult(), fixture.rawResult()]
        coordinator.revealTemporarily()
        await eventually { fixture.rawReadCount == 6 }
        await Task.yield()
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 4)
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 4, "Stable retry must avoid a new full click-path scan")
        XCTAssertEqual(fixture.rawReadCount, 7)
        await fixture.finish(coordinator)
    }

    func testAnimationWarmupRetryIsBoundedAndNeverHidesByItself() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        fixture.prewarmingEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.rawResults = ["a", "b", "c", "d"].map { fixture.rawResult(tag: $0) }
        coordinator.revealTemporarily()
        await eventually { fixture.rawReadCount == 6 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.rawReadCount, 6)
        XCTAssertEqual(fixture.scanCount, 4)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        await fixture.finish(coordinator)
    }

    func testFourthClickWinsWhileOldRawGuardIsStillReturning() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var releaseOld = false
        fixture.beforeRawRead = { count in
            if count == 3 {
                while !releaseOld { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.rawReadCount == 3 }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        releaseOld = true
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(fixture.beginCount, 2)
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertTrue(coordinator.isCollapsed)
        await fixture.finish(coordinator)
    }

    func testPermissionRevokedDuringRawGuardCannotBeginNativeHide() async throws {
        let fixture = Fixture()
        fixture.rawEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.beforeRawRead = { count in
            if count == 3 { fixture.permissionGranted = false }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.message.contains("自动重试 3 次仍未就绪") }
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        await fixture.finish(coordinator)
    }

    func testInstantGuardLayoutChangeFallsBackInsteadOfUsingCachedPlan() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.physicalGuardResults = [fixture.result(targetX: 12)]
        fixture.results = [fixture.result(targetX: 12), fixture.result(targetX: 12), fixture.result(targetX: 12)]

        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }

        XCTAssertGreaterThan(fixture.scanCount, 2)
        XCTAssertTrue(coordinator.notes.contains { $0.contains("菜单栏发生变化") })
        await fixture.finish(coordinator)
    }

    func testThirdClickCancelsInstantGuardWithoutLateNativeBegin() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var releaseGuard = false
        fixture.beforePhysicalGuard = { count in
            if count == 2 {
                while !releaseGuard { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.physicalGuardCount == 2 }
        coordinator.toggleCurrentCollapseVisibility()
        releaseGuard = true
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testFourthClickWinsBeforeCancelledInstantGuardReturns() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var releaseOldGuard = false
        fixture.beforePhysicalGuard = { count in
            if count == 2 {
                while !releaseOldGuard { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.physicalGuardCount == 2 }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        releaseOldGuard = true
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.physicalGuardCount, 3)
        await fixture.finish(coordinator)
    }

    func testCustomAutoHideDelayRestartsPendingRevealDeadline() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.setAutoHideDelaySeconds(12)
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.revealDelays.count == 1 }
        XCTAssertEqual(fixture.revealDelays, [.seconds(12)])
        coordinator.setAutoHideDelaySeconds(25)
        await eventually { fixture.revealDelays.count == 2 }
        XCTAssertEqual(fixture.revealDelays, [.seconds(12), .seconds(25)])
        XCTAssertFalse(coordinator.isCollapsed)
        await fixture.finish(coordinator)
    }

    func testEnabledPersistentCollapseAutomaticallyRecollapsesAfterIdleDeadline() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        var releaseDeadline = false
        fixture.beforeRevealSleep = { _, _ in
            while !releaseDeadline { try await Task.sleep(for: .milliseconds(1)) }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.revealDelays.count == 1 }
        XCTAssertEqual(fixture.revealDelays, [.seconds(4)])
        XCTAssertEqual(fixture.beginCount, 1)

        releaseDeadline = true
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        XCTAssertEqual(fixture.scanCount, 2)
        await fixture.finish(coordinator)
    }

    func testAutomaticRecollapseDefersForPointerButtonsMenuAndUnreadableState() async throws {
        let blockedStates = [
            MenuBarAutomaticRecollapseActivitySnapshot(isReadable: true, pointerInsideMenuBar: true, hasPressedMouseButtons: false, hasOpenMenuOrPopover: false),
            MenuBarAutomaticRecollapseActivitySnapshot(isReadable: true, pointerInsideMenuBar: false, hasPressedMouseButtons: true, hasOpenMenuOrPopover: false),
            MenuBarAutomaticRecollapseActivitySnapshot(isReadable: true, pointerInsideMenuBar: false, hasPressedMouseButtons: false, hasOpenMenuOrPopover: true),
            MenuBarAutomaticRecollapseActivitySnapshot(isReadable: false, pointerInsideMenuBar: false, hasPressedMouseButtons: false, hasOpenMenuOrPopover: false),
        ]
        for blocked in blockedStates {
            let fixture = Fixture()
            fixture.instantEnabled = true
            fixture.activities = [blocked]
            var releaseIdlePoll = false
            fixture.beforeRevealSleep = { count, _ in
                if count == 2 {
                    while !releaseIdlePoll { try await Task.sleep(for: .milliseconds(1)) }
                }
            }
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { coordinator.isCollapsed }
            coordinator.revealTemporarily()
            await eventually { fixture.revealDelays.count == 2 }
            XCTAssertFalse(coordinator.isCollapsed)
            XCTAssertEqual(fixture.beginCount, 1)
            XCTAssertEqual(fixture.activityReadCount, 1)
            XCTAssertEqual(fixture.revealDelays, [.seconds(4), .milliseconds(500)])

            releaseIdlePoll = true
            await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
            await fixture.finish(coordinator)
        }
    }

    func testDisablingPersistentCollapseCancelsAutomaticRevealTimer() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        var timerCancelled = false
        fixture.beforeRevealSleep = { _, _ in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { timerCancelled = true; throw error }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.revealDelays.count == 1 }
        coordinator.setPersistentCollapseDesired(false)
        await eventually { timerCancelled }
        XCTAssertFalse(coordinator.wantsPersistentCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.activityReadCount, 0)
        await fixture.finish(coordinator)
    }

    func testOrderEditingCancelsAutomaticRevealTimer() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        var timerCancelled = false
        fixture.beforeRevealSleep = { _, _ in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { timerCancelled = true; throw error }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.revealDelays.count == 1 }
        coordinator.prepareForOrderEditing()
        await eventually { timerCancelled }
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testExpandedPrewarmingRefreshesPlanWithoutHidingOrBlockingUI() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        fixture.prewarmingEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.physicalGuardCount == 2 }
        XCTAssertFalse(coordinator.isPreparingCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 3)
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 3)
        await fixture.finish(coordinator)
    }

    func testLateWarmupCannotOverwriteUnappliedDraft() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        fixture.prewarmingEnabled = true
        var releaseWarmup = false
        var warmupReturned = false
        fixture.beforeDiscover = { count in
            if count == 3 {
                while !releaseWarmup { try? await Task.sleep(for: .milliseconds(1)) }
                warmupReturned = true
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.scanCount == 3 }
        coordinator.moveAcross("target")
        XCTAssertTrue(coordinator.hasChanges)
        let draft = coordinator.draftIDs
        releaseWarmup = true
        await eventually { warmupReturned }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.draftIDs, draft)
        XCTAssertTrue(coordinator.hasChanges)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testAutomaticDeadlineAndExplicitClickCannotBypassUnappliedDraft() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        var releaseDeadline = false
        fixture.beforeRevealSleep = { count, _ in
            if count == 1 {
                while !releaseDeadline { try await Task.sleep(for: .milliseconds(1)) }
            } else {
                try await Task.sleep(for: .seconds(30))
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.revealTemporarily()
        await eventually { fixture.revealDelays.count == 1 }
        coordinator.moveAcross("target")
        let draft = coordinator.draftIDs
        releaseDeadline = true
        await eventually { fixture.revealDelays.count == 2 }
        coordinator.toggleCurrentCollapseVisibility()
        await Task.yield()

        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertEqual(coordinator.draftIDs, draft)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.activityReadCount, 0)
        await fixture.finish(coordinator)
    }

    func testApplicationEventDuringFinalFullPreparationCannotBeginOldPlan() async throws {
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let fixture = Fixture()
            var releaseFirstGuard = false
            var releaseRetry = false
            fixture.beforePhysicalGuard = { count in
                if count == 1 {
                    while !releaseFirstGuard { try? await Task.sleep(for: .milliseconds(1)) }
                }
            }
            fixture.beforeSleep = { count in
                if count == 2 {
                    while !releaseRetry { try await Task.sleep(for: .milliseconds(1)) }
                }
            }
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { fixture.physicalGuardCount == 1 }
            NSWorkspace.shared.notificationCenter.post(name: event, object: nil)
            await Task.yield()
            await Task.yield()
            releaseFirstGuard = true
            await eventually { fixture.delays.count == 2 }
            XCTAssertEqual(fixture.beginCount, 0)
            releaseRetry = true
            await eventually { coordinator.isCollapsed && fixture.beginCount == 1 }
            XCTAssertGreaterThanOrEqual(fixture.scanCount, 4)
            await fixture.finish(coordinator)
        }
    }

    func testNewSuspendCancelsOlderPendingWakeRecovery() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await eventually { !coordinator.isCollapsed && coordinator.inventory == nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        await Task.yield()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertNil(coordinator.inventory)
        await fixture.finish(coordinator)
    }

    func testScreenChangeCannotAuthorizeRecoveryWhileSuspended() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await eventually { !coordinator.isCollapsed && coordinator.inventory == nil }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.scanCount, 2)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testScreenChangeDoesNotCancelAuthorizedPendingWakeRecovery() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await eventually { !coordinator.isCollapsed && coordinator.inventory == nil }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        await Task.yield()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 4)
        await fixture.finish(coordinator)
    }

    func testShutdownDrainsCancelledInstantPhysicalGuard() async throws {
        let fixture = Fixture()
        fixture.instantEnabled = true
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        var releaseGuard = false
        var guardSawCancellation = false
        fixture.beforePhysicalGuard = { count in
            if count == 2 {
                while !releaseGuard {
                    guardSawCancellation = guardSawCancellation || Task.isCancelled
                    await Task.yield()
                }
            }
        }
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.physicalGuardCount == 2 }
        var shutdownCompleted = false
        let shutdown = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { guardSawCancellation }
        XCTAssertFalse(shutdownCompleted)
        releaseGuard = true
        await shutdown.value
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertFalse(coordinator.isPreparingCollapse)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testExplicitRecollapseStaleBaselineFallsBackToBoundedFullRecovery() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        fixture.results = [
            fixture.result(targetX: 12),
            fixture.result(targetX: 12),
            fixture.result(targetX: 12),
        ]
        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()

        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(
            fixture.scanCount,
            4,
            "旧基线失效后，重试必须做 fresh scan，但不再额外重复读取"
        )
        XCTAssertEqual(fixture.quickBarCaptureCount, 1, "显式收起重试不得重新采集截图")
        XCTAssertTrue(coordinator.notes.contains { $0.contains("菜单栏发生变化") })
        XCTAssertEqual(
            fixture.delays,
            [.milliseconds(900), .zero, .seconds(1)]
        )
        await fixture.finish(coordinator)
    }

    func testExplicitRecollapseKnownUnreadableProviderCannotReachNativeBegin() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        let stable = fixture.topology()
        let knownProvider = try XCTUnwrap(stable.items.first?.provider)
        let knownUnreadable = MenuBarTopologySnapshot(
            items: stable.items,
            unreadableProviders: [knownProvider]
        )
        fixture.topologySnapshots = [knownUnreadable, knownUnreadable, stable, stable]
        var releaseRecovery = false
        fixture.beforeSleep = { count in
            if count == 3 {
                while !releaseRecovery { await Task.yield() }
            }
        }

        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { fixture.delays.count == 3 }

        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, 3)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertTrue(coordinator.notes.contains { $0.contains("菜单栏发生变化") })

        releaseRecovery = true
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        XCTAssertEqual(fixture.scanCount, 4)
        XCTAssertEqual(fixture.quickBarCaptureCount, 1, "权限/提供者恢复后的显式重试也不得采集截图")
        await fixture.finish(coordinator)
    }

    func testRapidThirdClickWinsWhileFreshScanIsInFlight() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        var releaseScan = false
        let blockedScanNumber = fixture.scanCount + 1
        fixture.beforeDiscover = { count in
            if count == blockedScanNumber {
                while !releaseScan {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        coordinator.toggleCurrentCollapseVisibility() // revealed
        coordinator.toggleCurrentCollapseVisibility() // collapsed, begins fresh scan
        await eventually { fixture.scanCount == blockedScanNumber }
        coordinator.toggleCurrentCollapseVisibility() // last intent: revealed
        releaseScan = true
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertFalse(coordinator.isPreparingCollapse)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertEqual(fixture.scanCount, blockedScanNumber)
        XCTAssertEqual(fixture.quickBarCaptureCount, 1)
        await fixture.finish(coordinator)
    }

    func testRapidFourthClickWinsWhenCancelledScanReturnsLate() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        var releaseOldScan = false
        let blockedScanNumber = fixture.scanCount + 1
        fixture.beforeDiscover = { count in
            if count == blockedScanNumber {
                while !releaseOldScan {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        coordinator.toggleCurrentCollapseVisibility() // revealed
        coordinator.toggleCurrentCollapseVisibility() // collapsed, old scan blocks
        await eventually { fixture.scanCount == blockedScanNumber }
        coordinator.toggleCurrentCollapseVisibility() // revealed, cancels old generation
        coordinator.toggleCurrentCollapseVisibility() // collapsed, new generation wins

        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        releaseOldScan = true
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 2)
        XCTAssertEqual(fixture.scanCount, blockedScanNumber + 1)
        XCTAssertEqual(fixture.quickBarCaptureCount, 1)
        await fixture.finish(coordinator)
    }

    func testShutdownWaitsForSupersededAutomaticScanAfterNewGenerationWins() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        var releaseOldScan = false
        var oldScanSawCancellation = false
        let blockedScanNumber = fixture.scanCount + 1
        fixture.beforeDiscover = { count in
            guard count == blockedScanNumber else { return }
            while !releaseOldScan {
                oldScanSawCancellation = oldScanSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }

        coordinator.toggleCurrentCollapseVisibility() // revealed
        coordinator.toggleCurrentCollapseVisibility() // old generation blocks in discovery
        await eventually { fixture.scanCount == blockedScanNumber }
        coordinator.toggleCurrentCollapseVisibility() // cancels and clears the old public slot
        coordinator.toggleCurrentCollapseVisibility() // replacement generation wins
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }

        var shutdownCompleted = false
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { oldScanSawCancellation }
        await Task.yield()
        XCTAssertFalse(shutdownCompleted)
        XCTAssertFalse(coordinator.isReading)

        releaseOldScan = true
        await shutdownTask.value
        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(coordinator.isReading)
        XCTAssertFalse(coordinator.isPreparingCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testKeptExpandedInteractionNeedsOnlyOneClickToRecollapse() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        let token = try XCTUnwrap(coordinator.beginTemporaryRevealInteraction())
        coordinator.endTemporaryRevealInteraction(
            token,
            shouldRecollapse: false,
            keepExpandedAsUserIntent: true
        )

        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertFalse(coordinator.isCollapsed)
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
        XCTAssertEqual(fixture.beginCount, 2)
        await fixture.finish(coordinator)
    }

    func testOverlappingInteractionKeepExpandedWinsInEitherCompletionOrder() async throws {
        for keepEndsFirst in [true, false] {
            let fixture = Fixture()
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { coordinator.isCollapsed }

            let keep = try XCTUnwrap(coordinator.beginTemporaryRevealInteraction())
            let recollapse = try XCTUnwrap(coordinator.beginTemporaryRevealInteraction())
            if keepEndsFirst {
                coordinator.endTemporaryRevealInteraction(
                    keep,
                    shouldRecollapse: false,
                    keepExpandedAsUserIntent: true
                )
                coordinator.endTemporaryRevealInteraction(
                    recollapse,
                    shouldRecollapse: true,
                    delay: .zero
                )
            } else {
                coordinator.endTemporaryRevealInteraction(
                    recollapse,
                    shouldRecollapse: true,
                    delay: .zero
                )
                coordinator.endTemporaryRevealInteraction(
                    keep,
                    shouldRecollapse: false,
                    keepExpandedAsUserIntent: true
                )
            }

            XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
            XCTAssertFalse(coordinator.isCollapsed)
            XCTAssertEqual(fixture.beginCount, 1)
            coordinator.toggleCurrentCollapseVisibility()
            await eventually { coordinator.isCollapsed }
            XCTAssertEqual(fixture.beginCount, 2)
            await fixture.finish(coordinator)
        }
    }

    func testOverlappingInteractionRecollapseRequestSurvivesEitherCompletionOrder() async throws {
        for recollapseEndsFirst in [true, false] {
            let fixture = Fixture()
            let coordinator = try fixture.coordinator()
            coordinator.prepare()
            await eventually { coordinator.isCollapsed }

            let recollapse = try XCTUnwrap(coordinator.beginTemporaryRevealInteraction())
            let neutral = try XCTUnwrap(coordinator.beginTemporaryRevealInteraction())
            if recollapseEndsFirst {
                coordinator.endTemporaryRevealInteraction(
                    recollapse,
                    shouldRecollapse: true,
                    delay: .zero
                )
                coordinator.endTemporaryRevealInteraction(neutral, shouldRecollapse: false)
            } else {
                coordinator.endTemporaryRevealInteraction(neutral, shouldRecollapse: false)
                coordinator.endTemporaryRevealInteraction(
                    recollapse,
                    shouldRecollapse: true,
                    delay: .zero
                )
            }

            await eventually { coordinator.isCollapsed }
            XCTAssertEqual(coordinator.userVisibilityIntent, .collapsed)
            XCTAssertEqual(fixture.beginCount, 2)
            await fixture.finish(coordinator)
        }
    }

    func testApplicationNotificationCannotOverrideManualRevealIntent() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        coordinator.toggleCurrentCollapseVisibility()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(coordinator.userVisibilityIntent, .revealed)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(fixture.beginCount, 1)
        await fixture.finish(coordinator)
    }

    func testHelperApplicationNotificationKeepsActiveAssertion() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let readsBeforeNotification = fixture.topologyReadCount

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        await eventually { fixture.topologyReadCount > readsBeforeNotification }

        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertEqual(fixture.beginCount, 1)
        XCTAssertNil(coordinator.changePresentation)
        await fixture.finish(coordinator)
    }

    func testStrongContentChangeUsesProxyWithoutInvalidatingAssertion() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        fixture.liveTopology = fixture.topology(identity: "stable", title: "Target changed")

        await eventually { coordinator.changePresentation?.items.count == 1 }

        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertTrue(coordinator.changePresentation?.items[0].isChangeProxy == true)
        XCTAssertEqual(coordinator.changePresentation?.items[0].itemTitle, "Target changed")
        XCTAssertNotNil(coordinator.changePresentation?.items[0].activationBlockReason)
        await fixture.finish(coordinator)
    }

    func testNewHiddenItemUsesReadOnlyProxyWithoutInvalidatingAssertion() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let current = fixture.topology()
        let provider = try XCTUnwrap(current.items.first?.provider)
        let added = MenuBarTopologyItemSnapshot(
            provider: provider,
            identityKey: "identifier:late-item",
            structuralIdentityKey: "path:1",
            identityStrength: .strong,
            accessibilityIdentifier: "late-item",
            title: "Late Item",
            itemDescription: nil,
            value: nil
        )
        fixture.liveTopology = MenuBarTopologySnapshot(items: current.items + [added])

        await eventually { coordinator.changePresentation?.items.count == 1 }

        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertEqual(coordinator.changePresentation?.items[0].itemTitle, "Late Item")
        XCTAssertNotNil(coordinator.changePresentation?.items[0].activationBlockReason)
        await fixture.finish(coordinator)
    }

    func testRemovedItemDoesNotReleaseAssertionOrPresentUnrelatedProxy() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let current = fixture.topology()
        let provider = try XCTUnwrap(current.items.first?.provider)
        let second = MenuBarTopologyItemSnapshot(
            provider: provider,
            identityKey: "identifier:second",
            structuralIdentityKey: "path:1",
            identityStrength: .strong,
            accessibilityIdentifier: "second",
            title: "Second",
            itemDescription: nil,
            value: nil
        )
        fixture.liveTopology = MenuBarTopologySnapshot(items: current.items + [second])
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        fixture.liveTopology = current
        let readCount = fixture.topologyReadCount
        await eventually { fixture.topologyReadCount > readCount }

        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertNil(coordinator.changePresentation)
        await fixture.finish(coordinator)
    }

    func testUnrelatedRemovalDoesNotErasePendingChangeProxy() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let base = fixture.topology()
        let provider = try XCTUnwrap(base.items.first?.provider)
        let second = MenuBarTopologyItemSnapshot(
            provider: provider,
            identityKey: "identifier:second",
            structuralIdentityKey: "path:1",
            identityStrength: .strong,
            accessibilityIdentifier: "second",
            title: "Second",
            itemDescription: nil,
            value: nil
        )
        fixture.liveTopology = MenuBarTopologySnapshot(items: base.items + [second])
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        let changed = fixture.topology(identity: "stable", title: "Target changed")
        fixture.liveTopology = MenuBarTopologySnapshot(items: changed.items + [second])
        await eventually { coordinator.changePresentation?.items.count == 1 }
        let presentationID = coordinator.changePresentation?.id

        fixture.liveTopology = changed
        let readCount = fixture.topologyReadCount
        await eventually { fixture.topologyReadCount > readCount }

        XCTAssertEqual(coordinator.changePresentation?.items.count, 1)
        XCTAssertEqual(coordinator.changePresentation?.items[0].itemTitle, "Target changed")
        XCTAssertEqual(coordinator.changePresentation?.id, presentationID)
        coordinator.dismissChangePresentation(id: presentationID)
        XCTAssertNil(coordinator.changePresentation)
        await fixture.finish(coordinator)
    }

    func testDismissingOlderChangePanelCannotDropNewerBatch() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }

        fixture.liveTopology = fixture.topology(identity: "stable", title: "First")
        await eventually { coordinator.changePresentation?.items[0].itemTitle == "First" }
        let firstID = try XCTUnwrap(coordinator.changePresentation?.id)

        fixture.liveTopology = fixture.topology(identity: "stable", title: "Second")
        await eventually { coordinator.changePresentation?.items[0].itemTitle == "Second" }
        let secondID = try XCTUnwrap(coordinator.changePresentation?.id)
        XCTAssertNotEqual(firstID, secondID)

        coordinator.dismissChangePresentation(id: firstID)
        XCTAssertEqual(coordinator.changePresentation?.id, secondID)
        coordinator.dismissChangePresentation(id: nil)
        XCTAssertEqual(coordinator.changePresentation?.id, secondID)
        coordinator.dismissChangePresentation(id: secondID)
        XCTAssertNil(coordinator.changePresentation)
        await fixture.finish(coordinator)
    }

    func testRemovingProxiedItemClearsOnlyItsPendingProxy() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let base = fixture.topology()
        let provider = try XCTUnwrap(base.items.first?.provider)
        let added = MenuBarTopologyItemSnapshot(
            provider: provider,
            identityKey: "identifier:added",
            identityStrength: .strong,
            accessibilityIdentifier: "added",
            title: "Added",
            itemDescription: nil,
            value: nil
        )

        fixture.liveTopology = MenuBarTopologySnapshot(items: base.items + [added])
        await eventually { coordinator.changePresentation?.items.count == 1 }
        fixture.liveTopology = base
        let readCount = fixture.topologyReadCount
        await eventually { fixture.topologyReadCount > readCount }

        XCTAssertNil(coordinator.changePresentation)
        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        await fixture.finish(coordinator)
    }

    func testSameBundleDifferentPIDRemovalKeepsSiblingProxy() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let base = fixture.topology()
        let provider = try XCTUnwrap(base.items.first?.provider)
        let first = MenuBarTopologyItemSnapshot(
            provider: provider,
            identityKey: "identifier:first-added",
            identityStrength: .strong,
            accessibilityIdentifier: "first-added",
            title: "First Added",
            itemDescription: nil,
            value: nil
        )
        let siblingProvider = MenuBarTopologyProvider(
            bundleIdentifier: provider.bundleIdentifier,
            applicationName: "Target Helper",
            processIdentifier: 77
        )
        let sibling = MenuBarTopologyItemSnapshot(
            provider: siblingProvider,
            identityKey: "identifier:sibling-added",
            identityStrength: .strong,
            accessibilityIdentifier: "sibling-added",
            title: "Sibling Added",
            itemDescription: nil,
            value: nil
        )

        fixture.liveTopology = MenuBarTopologySnapshot(items: base.items + [first, sibling])
        await eventually { coordinator.changePresentation?.items.count == 2 }
        fixture.liveTopology = MenuBarTopologySnapshot(items: base.items + [first])
        await eventually {
            coordinator.changePresentation?.items.count == 1
                && coordinator.changePresentation?.items[0].processIdentifier == provider.processIdentifier
        }

        XCTAssertEqual(coordinator.changePresentation?.items[0].itemTitle, "First Added")
        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        await fixture.finish(coordinator)
    }

    func testUnreadableHelperDoesNotBlockConfirmedItemChange() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        let changed = fixture.topology(identity: "stable", title: "Target changed")
        let helper = MenuBarTopologyProvider(
            bundleIdentifier: "example.target",
            applicationName: "Helper",
            processIdentifier: 77
        )
        fixture.liveTopology = MenuBarTopologySnapshot(
            items: changed.items,
            runningProviders: changed.runningProviders.union([helper]),
            unreadableProviders: [helper]
        )

        await eventually { coordinator.changePresentation?.items.count == 1 }

        XCTAssertTrue(coordinator.isCollapsed)
        XCTAssertFalse(fixture.assertions[0].invalidated)
        XCTAssertEqual(coordinator.changePresentation?.items[0].itemTitle, "Target changed")
        await fixture.finish(coordinator)
    }

    func testStaleTopologyReadCannotClearNewSessionReadGate() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        var releaseOldRead = false
        var releaseNewRead = false
        var oldReadSawCancellation = false
        fixture.beforeTopologySnapshot = { count in
            if count == 3 {
                while !releaseOldRead {
                    oldReadSawCancellation = oldReadSawCancellation || Task.isCancelled
                    await Task.yield()
                }
            } else if count == 6 {
                while !releaseNewRead { await Task.yield() }
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        await eventually { fixture.topologyReadCount == 3 }

        coordinator.toggleCurrentCollapseVisibility()
        coordinator.toggleCurrentCollapseVisibility()
        await eventually { coordinator.isCollapsed && fixture.beginCount == 2 }
        await eventually { fixture.topologyReadCount == 5 }
        await eventually { oldReadSawCancellation }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            fixture.topologyReadCount,
            5,
            "旧监控读取实际返回前，新会话不能叠加另一轮监控读取"
        )

        releaseOldRead = true
        await eventually { fixture.topologyReadCount == 6 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            fixture.topologyReadCount,
            6,
            "当前监控读取未返回时必须保持 single-flight 门闩"
        )

        releaseNewRead = true
        await eventually { fixture.topologyReadCount >= 7 }
        await fixture.finish(coordinator)
    }

    func testShutdownWaitsForCancelledTopologyReadToReturn() async throws {
        let fixture = Fixture()
        fixture.topologyMonitoringInterval = 0.01
        var releaseRead = false
        var readSawCancellation = false
        var shutdownCompleted = false
        fixture.beforeTopologySnapshot = { count in
            guard count == 3 else { return }
            while !releaseRead {
                readSawCancellation = readSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        await eventually { fixture.topologyReadCount == 3 }

        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { readSawCancellation }
        XCTAssertFalse(shutdownCompleted)

        releaseRead = true
        await shutdownTask.value
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(fixture.topologyCompletedReadCount, fixture.topologyReadCount)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testShutdownAfterTerminationBarrierWaitsForManualReadToReturn() async throws {
        let fixture = Fixture()
        var releaseRead = false
        var readSawCancellation = false
        var shutdownCompleted = false
        fixture.beforeDiscover = { count in
            guard count == 1 else { return }
            while !releaseRead {
                readSawCancellation = readSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.readInventory()
        await eventually { fixture.scanCount == 1 }

        coordinator.beginTermination()
        XCTAssertFalse(coordinator.isReading)
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { readSawCancellation }
        XCTAssertFalse(shutdownCompleted)

        releaseRead = true
        await shutdownTask.value
        XCTAssertTrue(shutdownCompleted)
        XCTAssertFalse(coordinator.isReading)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testShutdownCancelsPendingWakeRecoveryBeforeItCanMutateInventory() async throws {
        let fixture = Fixture()
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { coordinator.isCollapsed }
        XCTAssertNotNil(coordinator.inventory)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await Task.yield()
        await Task.yield()
        await coordinator.shutdown()
        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertNotNil(
            coordinator.inventory,
            "退出屏障之后，已取消的唤醒延迟任务不得再清空清单"
        )
        XCTAssertFalse(coordinator.isReading)
        XCTAssertFalse(coordinator.isCollapsed)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testDetachedRuntimeReadPropagatesCancellationToWorker() async {
        let started = DispatchSemaphore(value: 0)
        let outerTask = Task.detached {
            await MenuBarCollapseRuntime.performDetachedRead(priority: .userInitiated) {
                started.signal()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return Task.isCancelled
            }
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        outerTask.cancel()
        let workerSawCancellation = await outerTask.value
        XCTAssertTrue(workerSawCancellation)
    }

    func testShutdownAfterTerminationBarrierWaitsForCollapsePreparationToReturn() async throws {
        let fixture = Fixture()
        var releasePreparationRead = false
        var preparationReadSawCancellation = false
        var shutdownCompleted = false
        fixture.beforeTopologySnapshot = { count in
            guard count == 1 else { return }
            while !releasePreparationRead {
                preparationReadSawCancellation = preparationReadSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { fixture.topologyReadCount == 1 }

        coordinator.beginTermination()
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { preparationReadSawCancellation }
        XCTAssertFalse(shutdownCompleted)

        releasePreparationRead = true
        await shutdownTask.value
        XCTAssertTrue(shutdownCompleted)
        XCTAssertEqual(fixture.topologyCompletedReadCount, fixture.topologyReadCount)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testShutdownAfterTerminationBarrierWaitsForAutomaticRediscoveryToReturn() async throws {
        let fixture = Fixture()
        var releaseRead = false
        var readSawCancellation = false
        var shutdownCompleted = false
        fixture.beforeDiscover = { count in
            guard count == 1 else { return }
            while !releaseRead {
                readSawCancellation = readSawCancellation || Task.isCancelled
                await Task.yield()
            }
        }
        let coordinator = try fixture.coordinator()
        coordinator.prepare()
        await eventually { fixture.scanCount == 1 }

        coordinator.beginTermination()
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownCompleted = true
        }
        await eventually { readSawCancellation }
        XCTAssertFalse(shutdownCompleted)

        releaseRead = true
        await shutdownTask.value
        XCTAssertTrue(shutdownCompleted)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testStartupWaitsForAnExistingManualReadWithoutClearingItsBusyState() async throws {
        let fixture = Fixture()
        var releaseRead = false
        fixture.beforeDiscover = { count in
            if count == 1 {
                while !releaseRead { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        let coordinator = try fixture.coordinator()
        fixture.beforeSleep = { [weak coordinator] count in
            if count > 1 {
                while !releaseRead || coordinator?.isReading == true {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        coordinator.readInventory()
        await eventually { fixture.scanCount == 1 }
        coordinator.prepare()
        await eventually { fixture.delays.count == 2 }
        XCTAssertTrue(coordinator.isReading)
        XCTAssertEqual(fixture.beginCount, 0)
        XCTAssertEqual(fixture.scanCount, 1)
        releaseRead = true
        await eventually { coordinator.isCollapsed }
        XCTAssertEqual(fixture.beginCount, 1, "\(coordinator.notes); delays=\(fixture.delays); scans=\(fixture.scanCount)")
        await fixture.finish(coordinator)
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Expected recovery state was not reached", file: file, line: line)
    }

    private final class Assertion: MenuBarCollapseAssertion {
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-AutomaticCollapse-\(UUID().uuidString)")
        var permissionGranted = true
        var disableNativeHidingForDiagnostics = false
        var hidingLaunchIssue: String?
        var results: [AnchoredMenuBarDiscoveryResult] = []
        var revisions: [String] = []
        var scanCount = 0
        var quickBarCaptureCount = 0
        var beginCount = 0
        var nativeFailuresRemaining = 0
        var nativeNeverCompletes = false
        var physicalResultVerified: Bool? = true
        var physicalVerificationCount = 0
        var beforeNativeCompletion: (() -> Void)?
        var holdNativeCompletion = false
        var delays: [Duration] = []
        var assertions: [Assertion] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var holdRetry = false
        var heldRetryWasCancelled = false
        var onSleep: ((Int) -> Void)?
        var beforeSleep: ((Int) async throws -> Void)?
        var beforeDiscover: ((Int) async -> Void)?
        var liveTopology: MenuBarTopologySnapshot?
        var topologySnapshots: [MenuBarTopologySnapshot] = []
        var topologyMonitoringInterval: TimeInterval = 60
        var topologyReadCount = 0
        var topologyCompletedReadCount = 0
        var beforeTopologySnapshot: ((Int) async -> Void)?
        var instantEnabled = false
        var prewarmingEnabled = false
        var physicalGuardCount = 0
        var physicalGuardResults: [AnchoredMenuBarDiscoveryResult] = []
        var beforePhysicalGuard: ((Int) async -> Void)?
        var rawEnabled = false
        var rawReadCount = 0
        var rawResults: [MenuBarRawPhysicalStructureSnapshot] = []
        var beforeRawRead: ((Int) async -> Void)?
        var additionalApplications: [RunningAppSnapshot] = []
        var events: [String] = []
        var plans: [MenuBarCollapsePlan] = []
        var revealDelays: [Duration] = []
        var beforeRevealSleep: ((Int, Duration) async throws -> Void)?
        var activityReadCount = 0
        var activities: [MenuBarAutomaticRecollapseActivitySnapshot] = []

        func coordinator() throws -> MenuBarManagementCoordinator {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("""
            {"schemaVersion":1,"isEnabled":true,"wantsPersistentCollapse":true}
            """.utf8).write(to: root.appendingPathComponent("settings-v1.json"))
            var runtime = MenuBarCollapseRuntime()
            runtime.hidingLaunchIssue = { [self] in hidingLaunchIssue }
            // All AX/CG reads in this suite must remain fixture-controlled.
            runtime.rawStructureGuardEnabled = rawEnabled
            runtime.applications = { [self] in
                events.append("apps")
                var applications = [RunningAppSnapshot(
                    bundleIdentifier: "example.target", name: "Target", processIdentifier: 42
                ), RunningAppSnapshot(
                    bundleIdentifier: AppConstants.bundleIdentifier,
                    name: AppConstants.appName,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                )] + additionalApplications
                if rawEnabled {
                    applications.append(RunningAppSnapshot(
                        bundleIdentifier: "com.apple.MenuBarAgent", name: "MenuBarAgent",
                        processIdentifier: 500
                    ))
                }
                return applications
            }
            runtime.discover = { [self] _, _, _, _ in
                events.append("discover")
                scanCount += 1
                await beforeDiscover?(scanCount)
                return results.isEmpty ? result() : results.removeFirst()
            }
            runtime.topologySnapshot = { [self] _ in
                events.append("topology")
                topologyReadCount += 1
                await beforeTopologySnapshot?(topologyReadCount)
                topologyCompletedReadCount += 1
                if !topologySnapshots.isEmpty {
                    return topologySnapshots.removeFirst()
                }
                if !revisions.isEmpty {
                    return topology(identity: revisions.removeFirst())
                }
                return liveTopology ?? topology()
            }
            runtime.physicalGuard = { [self] _, _, _, _ in
                physicalGuardCount += 1
                await beforePhysicalGuard?(physicalGuardCount)
                if !physicalGuardResults.isEmpty { return physicalGuardResults.removeFirst() }
                return result(complete: instantEnabled)
            }
            runtime.rawPhysicalStructure = { [self] _ in
                events.append("raw")
                rawReadCount += 1
                await beforeRawRead?(rawReadCount)
                return rawResults.isEmpty ? rawResult() : rawResults.removeFirst()
            }
            runtime.instantPrewarmingEnabled = prewarmingEnabled
            runtime.instantPreparationWarmupDelay = .zero
            runtime.revealSleep = { [self] delay in
                revealDelays.append(delay)
                if let beforeRevealSleep {
                    try await beforeRevealSleep(revealDelays.count, delay)
                } else {
                    try await Task.sleep(for: .seconds(30))
                }
            }
            runtime.revealActivity = { [self] in
                activityReadCount += 1
                if !activities.isEmpty { return activities.removeFirst() }
                return MenuBarAutomaticRecollapseActivitySnapshot(
                    isReadable: true, pointerInsideMenuBar: false,
                    hasPressedMouseButtons: false, hasOpenMenuOrPopover: false
                )
            }
            runtime.begin = { [self] plan, completion in
                events.append("begin")
                plans.append(plan)
                beginCount += 1
                let assertion = Assertion()
                assertions.append(assertion)
                completions.append(completion)
                if nativeFailuresRemaining > 0 {
                    nativeFailuresRemaining -= 1
                    completion(NSError(domain: "TestNativeHide", code: 1))
                } else if !nativeNeverCompletes && !holdNativeCompletion {
                    beforeNativeCompletion?()
                    completion(nil)
                }
                return assertion
            }
            runtime.sleep = { [self] delay in
                delays.append(delay)
                onSleep?(delays.count)
                try await beforeSleep?(delays.count)
                if holdRetry, delays.count > 1 {
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { heldRetryWasCancelled = true; throw error }
                } else {
                    await Task.yield()
                }
            }
            runtime.nativeConfirmationTimeout = nativeNeverCompletes ? .milliseconds(5) : .seconds(1)
            runtime.verifyPhysicalResult = { [self] _, _, _ in
                physicalVerificationCount += 1
                return physicalResultVerified
            }
            runtime.topologyMonitoringInterval = topologyMonitoringInterval
            return MenuBarManagementCoordinator(
                permissionClient: MenuBarControlPermissionClient(
                    checkAccessibility: { [self] in permissionGranted },
                    requestAccessibility: { false },
                    checkEventPosting: { true }, requestEventPosting: { false }
                ),
                storageRootURL: root, osMajorVersion: { 27 },
                nativeVisibilitySupported: { true },
                disableNativeHidingForDiagnostics: disableNativeHidingForDiagnostics,
                captureQuickBarIcons: { [self] _ in
                    quickBarCaptureCount += 1
                    return [:]
                },
                collapseRuntime: runtime,
                acquireInputLease: { _ in nil }, releaseInputLease: { _, _ in false }
            )
        }

        func finish(_ coordinator: MenuBarManagementCoordinator) async {
            await coordinator.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        func result(
            complete: Bool = true,
            crossBoundary: Bool = false,
            targetX: CGFloat = 10
        ) -> AnchoredMenuBarDiscoveryResult {
            let anchor = MenuBarManagementCoordinator.anchorIdentity
            var items = [MenuBarOrderItem(
                id: "target", bundleIdentifier: "example.target", applicationName: "Target",
                title: "Target", processIdentifier: 42, displayID: 1,
                frame: CGRect(x: targetX, y: 0, width: 20, height: 24)
            ), MenuBarOrderItem(
                id: "anchor", bundleIdentifier: anchor.bundleIdentifier,
                applicationName: AppConstants.appName, title: anchor.title,
                accessibilityIdentifier: anchor.accessibilityIdentifier,
                processIdentifier: ProcessInfo.processInfo.processIdentifier, displayID: 1,
                frame: CGRect(x: 40, y: 0, width: 20, height: 24)
            )]
            if crossBoundary {
                items.append(MenuBarOrderItem(
                    id: "right", bundleIdentifier: "example.target", applicationName: "Target",
                    title: "Right", processIdentifier: 42, displayID: 1,
                    frame: CGRect(x: 70, y: 0, width: 20, height: 24)
                ))
            }
            return AnchoredMenuBarDiscoveryResult(
                inventory: AnchoredMenuBarInventory(
                    items: items,
                    coverage: MenuBarInventoryCoverage(
                        expectedDisplayIDs: [1], observedCandidateCount: items.count,
                        resolvedItemCount: items.count, didTimeOut: !complete
                    ), anchorIdentity: anchor
                ), physicalItems: items, messages: []
            )
        }

        func topology(identity: String = "stable", title: String = "Target") -> MenuBarTopologySnapshot {
            let provider = MenuBarTopologyProvider(
                bundleIdentifier: "example.target",
                applicationName: "Target",
                processIdentifier: 42
            )
            return MenuBarTopologySnapshot(items: [
                MenuBarTopologyItemSnapshot(
                    provider: provider,
                    identityKey: "identifier:\(identity)",
                    identityStrength: .strong,
                    accessibilityIdentifier: identity,
                    title: title,
                    itemDescription: nil,
                    value: nil
                ),
            ])
        }

        func rawResult(tag: String = "stable", complete: Bool = true) -> MenuBarRawPhysicalStructureSnapshot {
            var diagnostics = MenuBarRawPhysicalStructureDiagnostics()
            if !complete { diagnostics.record(.childrenReadFailed) }
            return MenuBarRawPhysicalStructureSnapshot(
                model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: .value(500),
                    displays: [.init(id: 1, bounds: .value(.init(x: 0, y: 0, width: 100, height: 100)))],
                    nodes: [.init(
                        path: [], processIdentifier: .value(500), role: .absent,
                        identifier: .value(tag), frame: .absent,
                        position: .absent, size: .absent, children: .value([])
                    )]
                ), diagnostics: diagnostics
            )
        }

        func rawPhysicalResult(tag: String = "stable", opaque: Bool = false) -> MenuBarRawPhysicalStructureSnapshot {
            let items = result().inventory.items
            let nodes: [MenuBarRawPhysicalNode] = [.init(
                path: [], processIdentifier: .value(500), role: .value("AXApplication"),
                identifier: .value(tag), frame: .absent, position: .absent, size: .absent,
                children: .value([.node(path: [0])])
            ), .init(
                path: [0], processIdentifier: .value(500), role: .value("AXWindow"),
                identifier: .absent, frame: .value(.init(x: 0, y: 0, width: 100, height: 24)),
                position: .absent, size: .absent,
                children: .value(items.indices.map { .node(path: [0, $0]) })
            )] + items.enumerated().flatMap { index, item -> [MenuBarRawPhysicalNode] in
                if opaque {
                    return [.init(path: [0, index], processIdentifier: .value(500), role: .absent,
                        identifier: .absent, frame: .value(.init(x: Double(item.frame.minX), y: 0, width: 20, height: 24)),
                        position: .absent, size: .absent, children: .value([.node(path: [0, index, 0])])),
                        .init(path: [0, index, 0], processIdentifier: .value(item.processIdentifier), role: .absent,
                            identifier: .absent, frame: .absent, position: .absent, size: .absent,
                            children: .absent, isOpaqueApplicationProxy: true)]
                }
                return [MenuBarRawPhysicalNode(path: [0, index], processIdentifier: .value(item.processIdentifier),
                    role: .value("AXButton"), identifier: item.accessibilityIdentifier.map { .value($0) } ?? .absent,
                    frame: .value(.init(x: Double(item.frame.minX), y: 0, width: 20, height: 24)),
                    position: .absent, size: .absent, children: .value([]))]
            }
            return .init(model: .init(providerProcessIdentifier: .value(500),
                displays: [.init(id: 1, bounds: .value(.init(x: 0, y: 0, width: 100, height: 100)))], nodes: nodes))
        }
    }
}
