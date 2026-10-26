import CoreGraphics
import Foundation
import XCTest
@testable import DisplayMonitor

final class MenuBarManagementSafetyTests: XCTestCase {
    private let anchorIdentity = MenuBarAnchorIdentity(
        bundleIdentifier: "com.hanshuai.DisplayMonitor",
        title: "Display Monitor"
    )

    private var protectionPolicy: MenuBarTargetProtectionPolicy {
        MenuBarTargetProtectionPolicy(ownBundleIdentifier: anchorIdentity.bundleIdentifier)
    }

    func testCompleteInventorySplitsAroundExactlyOneAnchor() throws {
        let items = [
            item("left", bundle: "com.example.left", x: 10),
            item("anchor", bundle: anchorIdentity.bundleIdentifier, title: anchorIdentity.title, x: 30),
            item("right", bundle: "com.example.right", x: 50),
        ]
        let inventory = completeInventory(items)

        let layout = try XCTUnwrap(inventory.validatedLayouts().first)
        XCTAssertEqual(layout.leftIDs, ["left"])
        XCTAssertEqual(layout.anchorID, "anchor")
        XCTAssertEqual(layout.rightIDs, ["right"])
        XCTAssertEqual(
            try inventory.collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
            ["com.example.left"]
        )
    }

    func testAnchorUsesStableAccessibilityIdentifierWhenSymbolTitleChanges() {
        let stableIdentity = MenuBarAnchorIdentity(
            bundleIdentifier: anchorIdentity.bundleIdentifier,
            title: anchorIdentity.title,
            accessibilityIdentifier: "com.hanshuai.DisplayMonitor.menuBar.anchor"
        )
        let anchor = MenuBarOrderItem(
            id: "anchor",
            bundleIdentifier: anchorIdentity.bundleIdentifier,
            applicationName: "Display Monitor",
            title: "Mac",
            accessibilityIdentifier: "com.hanshuai.DisplayMonitor.menuBar.anchor",
            processIdentifier: 10,
            displayID: 1,
            frame: CGRect(x: 30, y: 0, width: 20, height: 24)
        )
        let activity = MenuBarOrderItem(
            id: "activity",
            bundleIdentifier: anchorIdentity.bundleIdentifier,
            applicationName: "Display Monitor",
            title: "Monitor",
            processIdentifier: 10,
            displayID: 1,
            frame: CGRect(x: 50, y: 0, width: 20, height: 24)
        )

        XCTAssertTrue(stableIdentity.matches(anchor))
        XCTAssertFalse(stableIdentity.matches(activity))
    }

    func testSameBundleOnBothSidesBlocksCollapse() throws {
        let items = [
            item("left", bundle: "com.example.shared", x: 10),
            item("anchor", bundle: anchorIdentity.bundleIdentifier, title: anchorIdentity.title, x: 30),
            item("right", bundle: "com.example.shared", x: 50),
        ]

        XCTAssertThrowsError(
            try completeInventory(items).collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy)
        ) { error in
            XCTAssertEqual(
                error as? AnchoredMenuBarValidationError,
                .crossBoundaryBundles(["com.example.shared"])
            )
        }
    }

    func testIncompleteCoverageFailsClosed() {
        let anchor = item(
            "anchor",
            bundle: anchorIdentity.bundleIdentifier,
            title: anchorIdentity.title,
            x: 30
        )
        let inventory = AnchoredMenuBarInventory(
            items: [anchor],
            coverage: MenuBarInventoryCoverage(
                expectedDisplayIDs: [1],
                observedCandidateCount: 2,
                resolvedItemCount: 1,
                unknownOwnershipCount: 1
            ),
            anchorIdentity: anchorIdentity
        )

        XCTAssertThrowsError(try inventory.validatedLayouts()) { error in
            XCTAssertEqual(error as? AnchoredMenuBarValidationError, .incompleteCoverage)
        }
    }

    func testPlannerNeverEmitsAnchorAsSource() throws {
        let left = item("left", bundle: "com.example.left", x: 10)
        let anchor = item(
            "anchor",
            bundle: anchorIdentity.bundleIdentifier,
            title: anchorIdentity.title,
            x: 30
        )
        let right = item("right", bundle: "com.example.right", x: 50)

        let move = try XCTUnwrap(AnchoredMenuBarPlanner.nextMove(
            current: [left, anchor, right],
            desiredIDs: ["right", "anchor", "left"],
            anchorID: "anchor",
            movableItemIDs: ["left", "right"]
        ))
        XCTAssertNotEqual(move.itemID, "anchor")
    }

    func testCollapsePlanKeepsControllerAndRemovesOnlyTargets() throws {
        let plan = try MenuBarCollapsePlan(
            runningBundleIdentifiers: [
                anchorIdentity.bundleIdentifier,
                "com.example.left",
                "com.example.right",
            ],
            targetBundleIdentifiers: ["com.example.left"],
            protectionPolicy: protectionPolicy
        )

        XCTAssertTrue(plan.allowedBundleIdentifiers.contains(anchorIdentity.bundleIdentifier))
        XCTAssertTrue(plan.allowedBundleIdentifiers.contains("com.example.right"))
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains("com.example.left"))
        XCTAssertEqual(plan.targetBundleIdentifiers, ["com.example.left"])
    }

    func testTextInputMenuAgentCanBeExplicitlyTreatedAsCollapseTarget() throws {
        let textInputBundle = MenuBarTargetProtectionPolicy.textInputMenuAgentBundleIdentifier
        let defaultPolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: anchorIdentity.bundleIdentifier
        )
        let inputAwarePolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: anchorIdentity.bundleIdentifier,
            collapsibleSystemBundleIdentifiers: [textInputBundle]
        )
        let inventory = completeInventory([
            item("input", bundle: textInputBundle, title: "微信输入法", x: 10),
            item("anchor", bundle: anchorIdentity.bundleIdentifier, title: anchorIdentity.title, x: 30),
            item("system", bundle: "com.apple.controlcenter", title: "控制中心", x: 50),
        ])

        XCTAssertNotNil(defaultPolicy.reason(bundleIdentifier: textInputBundle))
        XCTAssertNil(inputAwarePolicy.reason(bundleIdentifier: textInputBundle))
        XCTAssertNotNil(inputAwarePolicy.reason(bundleIdentifier: "com.apple.controlcenter"))
        XCTAssertNotNil(inputAwarePolicy.reason(bundleIdentifier: "com.apple.MenuBarAgent"))
        XCTAssertEqual(
            try inventory.collapseTargetBundleIdentifiers(protectionPolicy: inputAwarePolicy),
            [textInputBundle]
        )

        let plan = try MenuBarCollapsePlan(
            runningBundleIdentifiers: [
                anchorIdentity.bundleIdentifier,
                textInputBundle,
                "com.apple.controlcenter",
            ],
            targetBundleIdentifiers: [textInputBundle],
            protectionPolicy: inputAwarePolicy
        )
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains(textInputBundle))
        XCTAssertTrue(plan.allowedBundleIdentifiers.contains("com.apple.controlcenter"))
    }

    @MainActor
    func testSystemHostedInputMethodRemainsProtectedFromSorting() {
        let coordinator = makeCoordinator(
            storageRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("DisplayMonitor-MenuBarInputPolicy-\(UUID().uuidString)")
        )
        let inputItem = item(
            "input",
            bundle: MenuBarTargetProtectionPolicy.textInputMenuAgentBundleIdentifier,
            title: "微信输入法",
            x: 10
        )

        XCTAssertFalse(coordinator.canMove(inputItem))
    }

    func testPersistentSessionIgnoresLateCallbacks() throws {
        var session = PersistentHideSession()
        let first = try XCTUnwrap(session.begin(topologyRevision: "revision-1"))
        XCTAssertEqual(
            session.planPersistenceCompleted(token: first, succeeded: true),
            .beginNative(token: first)
        )
        XCTAssertEqual(session.end(token: first), .releaseNativeAssertion)

        let second = try XCTUnwrap(session.begin(topologyRevision: "revision-2"))
        XCTAssertFalse(session.confirm(token: first))
        XCTAssertEqual(session.fail(token: first), .none)
        XCTAssertTrue(session.isCurrent(second))
    }

    func testChangedDraftCanApplyEvenThoughItMustBlockReread() {
        XCTAssertNil(MenuBarManagementCoordinator.basicApplyBlockingReason(
            featureAvailable: true,
            availabilityMessage: "",
            enabled: true,
            applying: false,
            collapseActive: false,
            reading: false,
            accessibilityGranted: true,
            coverageComplete: true,
            eventPostingGranted: true,
            hasChanges: true
        ))

        XCTAssertEqual(
            MenuBarManagementCoordinator.basicApplyBlockingReason(
                featureAvailable: true,
                availabilityMessage: "",
                enabled: true,
                applying: false,
                collapseActive: false,
                reading: false,
                accessibilityGranted: true,
                coverageComplete: true,
                eventPostingGranted: true,
                hasChanges: false
            ),
            "草稿与真实顺序相同，无需应用。"
        )
    }

    func testRecoveryJournalPreservesFullItemIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-MenuBarRecovery-\(UUID().uuidString)")
        let url = root.appendingPathComponent("order-recovery-v1.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let items = [
            item("left", bundle: "com.example.left", x: 10),
            item("anchor", bundle: anchorIdentity.bundleIdentifier, title: anchorIdentity.title, x: 30),
            item("right", bundle: "com.example.right", x: 50),
        ]
        let recovery = MenuBarOrderRecovery(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            displayID: 1,
            anchorIdentity: anchorIdentity,
            originalItems: items,
            desiredItemIDs: ["right", "anchor", "left"]
        )

        try MenuBarOrderJournal.save(recovery, to: url)
        let loaded = try MenuBarOrderJournal.load(from: url)

        XCTAssertEqual(loaded, recovery)
        XCTAssertEqual(loaded.originalItems.map(\.bundleIdentifier), items.map(\.bundleIdentifier))
        XCTAssertEqual(loaded.originalItemIDs, ["left", "anchor", "right"])
    }

    @MainActor
    func testOrderingRemainsAvailableWhenCollapseBridgeIsUnavailable() {
        let permissionClient = MenuBarControlPermissionClient(
            checkAccessibility: { true },
            requestAccessibility: { true },
            checkEventPosting: { true },
            requestEventPosting: { true }
        )
        let coordinator = MenuBarManagementCoordinator(
            permissionClient: permissionClient,
            storageRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("DisplayMonitor-MenuBarCapability-\(UUID().uuidString)"),
            osMajorVersion: { 27 },
            nativeVisibilitySupported: { false },
            acquireInputLease: { _ in nil },
            releaseInputLease: { _, _ in false }
        )

        XCTAssertTrue(coordinator.isFeatureAvailable)
        XCTAssertTrue(coordinator.isOrderingAvailable)
        XCTAssertFalse(coordinator.isCollapseAvailable)
        XCTAssertTrue(coordinator.featureAvailabilityMessage.contains("可读取并排序"))
    }

    @MainActor
    func testLegacyEnabledSettingsMigrateToPersistentCollapseIntent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-MenuBarSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {
          "schemaVersion" : 1,
          "isEnabled" : true
        }
        """.utf8).write(to: root.appendingPathComponent("settings-v1.json"))

        let coordinator = makeCoordinator(storageRootURL: root)

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
        XCTAssertEqual(coordinator.primaryPresentationMode, .nativeMenuBar)
        XCTAssertFalse(coordinator.showQuickBarOnHover)
        coordinator.revealTemporarily()
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        XCTAssertFalse(coordinator.isCollapsed)
    }

    @MainActor
    func testQuickBarPresentationModePersistsWithoutChangingCollapseIntent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-MenuBarSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = makeCoordinator(storageRootURL: root)
        coordinator.setEnabled(true)
        coordinator.setPrimaryPresentationMode(.quickBar)

        let reloaded = makeCoordinator(storageRootURL: root)
        XCTAssertTrue(reloaded.wantsPersistentCollapse)
        XCTAssertEqual(reloaded.primaryPresentationMode, .quickBar)
    }

    @MainActor
    func testOnlyTurningOffIntentPersistsPermanentExpansion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-MenuBarSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = makeCoordinator(storageRootURL: root)
        coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)

        coordinator.setPersistentCollapseDesired(false)
        let reloaded = makeCoordinator(storageRootURL: root)

        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertFalse(reloaded.wantsPersistentCollapse)
        XCTAssertFalse(reloaded.isCollapsed)
    }

    @MainActor
    func testHoverPreferencePersistsAcrossPresentationAndEnableChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-MenuBarHoverSettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(storageRootURL: root)
        XCTAssertFalse(coordinator.showQuickBarOnHover)
        coordinator.setShowQuickBarOnHover(true)
        coordinator.setEnabled(true)
        coordinator.setPrimaryPresentationMode(.quickBar)
        coordinator.setPrimaryPresentationMode(.nativeMenuBar)
        coordinator.setEnabled(false)

        let reloaded = makeCoordinator(storageRootURL: root)
        XCTAssertTrue(reloaded.showQuickBarOnHover)
        XCTAssertEqual(reloaded.primaryPresentationMode, .nativeMenuBar)
        XCTAssertFalse(reloaded.isEnabled)
        reloaded.setShowQuickBarOnHover(false)
        XCTAssertFalse(makeCoordinator(storageRootURL: root).showQuickBarOnHover)
    }

    private func completeInventory(_ items: [MenuBarOrderItem]) -> AnchoredMenuBarInventory {
        AnchoredMenuBarInventory(
            items: items,
            coverage: MenuBarInventoryCoverage(
                expectedDisplayIDs: [1],
                observedCandidateCount: items.count,
                resolvedItemCount: items.count
            ),
            anchorIdentity: anchorIdentity
        )
    }

    @MainActor
    private func makeCoordinator(storageRootURL: URL) -> MenuBarManagementCoordinator {
        MenuBarManagementCoordinator(
            permissionClient: MenuBarControlPermissionClient(
                checkAccessibility: { true },
                requestAccessibility: { true },
                checkEventPosting: { true },
                requestEventPosting: { true }
            ),
            storageRootURL: storageRootURL,
            osMajorVersion: { 27 },
            nativeVisibilitySupported: { false },
            acquireInputLease: { _ in nil },
            releaseInputLease: { _, _ in false }
        )
    }

    private func item(
        _ id: String,
        bundle: String,
        title: String? = nil,
        x: CGFloat
    ) -> MenuBarOrderItem {
        MenuBarOrderItem(
            id: id,
            bundleIdentifier: bundle,
            applicationName: bundle,
            title: title ?? id,
            processIdentifier: Int32(abs(id.hashValue % 10_000) + 1),
            displayID: 1,
            frame: CGRect(x: x, y: 0, width: 20, height: 24)
        )
    }
}
