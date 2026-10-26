import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarInstantCollapsePreparationTests: XCTestCase {
    private let contextRevision: UInt64 = 17
    private let targetBundle = "com.example.target"
    private let rightBundle = "com.example.right"
    private let ownBundle = "com.example.controller"

    func testCompletePreparationAcceptsCrossSourceIDsAndExposesBaseline() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())

        XCTAssertEqual(preparation.inventory, fixture.discovery().inventory)
        XCTAssertEqual(preparation.topology, fixture.topology())
        XCTAssertEqual(
            preparation.planIfUnchanged(
                physicalGuard: fixture.guardResult(),
                applications: fixture.applications(),
                contextRevision: contextRevision,
                protectionPolicy: fixture.policy()
            )?.targetBundleIdentifiers,
            [targetBundle]
        )
    }

    func testCurrentNewNonTargetApplicationIsAllowedByFreshPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let applications = fixture.applications() + [RunningAppSnapshot(
            bundleIdentifier: "com.example.new-helper",
            name: "New Helper",
            processIdentifier: 91
        )]

        let plan = try XCTUnwrap(preparation.planIfUnchanged(
            physicalGuard: fixture.guardResult(),
            applications: applications,
            contextRevision: contextRevision,
            protectionPolicy: fixture.policy()
        ))

        XCTAssertTrue(plan.allowedBundleIdentifiers.contains("com.example.new-helper"))
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains(targetBundle))
    }

    func testAddedPhysicalItemRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        var items = fixture.items(source: "guard")
        items.append(fixture.item(
            id: "guard-added",
            bundle: "com.example.added",
            processIdentifier: 81,
            x: 25
        ))

        XCTAssertNil(fixture.plan(preparation, guardItems: items))
    }

    func testRemovedPhysicalItemRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let items = fixture.items(source: "guard").filter {
            $0.bundleIdentifier != rightBundle
        }

        XCTAssertNil(fixture.plan(preparation, guardItems: items))
    }

    func testTargetMovingAcrossAnchorRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let items = fixture.items(source: "guard", targetX: 90)

        XCTAssertNil(fixture.plan(preparation, guardItems: items))
    }

    func testExactFrameChangeRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let items = fixture.items(source: "guard", targetX: 10.001)

        XCTAssertNil(fixture.plan(preparation, guardItems: items))
    }

    func testRestartedTargetWithSameBundleRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let items = fixture.items(source: "guard", targetPID: 43)
        let applications = fixture.applications(targetPID: 43)

        XCTAssertNil(fixture.plan(
            preparation,
            guardItems: items,
            applications: applications
        ))
    }

    func testNewHelperPIDForTargetBundleRejectsUnchangedPhysicalGuard() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let applications = fixture.applications() + [RunningAppSnapshot(
            bundleIdentifier: targetBundle,
            name: "Target Helper",
            processIdentifier: 43
        )]

        XCTAssertNil(fixture.plan(preparation, applications: applications))
    }

    func testIncompleteDiscoveryOrInitialPhysicalGuardCannotCreatePreparation() {
        let fixture = Fixture(owner: self)

        XCTAssertNil(fixture.preparation(
            discovery: fixture.discovery(complete: false)
        ))
        XCTAssertNil(fixture.preparation(
            guardResult: fixture.guardResult(complete: false)
        ))
    }

    func testIncompleteCurrentPhysicalGuardRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())

        XCTAssertNil(preparation.planIfUnchanged(
            physicalGuard: fixture.guardResult(complete: false),
            applications: fixture.applications(),
            contextRevision: contextRevision,
            protectionPolicy: fixture.policy()
        ))
    }

    func testUnknownOwnerCannotCreatePreparation() {
        let fixture = Fixture(owner: self)
        XCTAssertNil(fixture.preparation(
            discovery: fixture.discovery(unknownOwnershipCount: 1)
        ))
    }

    func testDuplicatePhysicalIdentityCannotCreatePreparation() {
        let fixture = Fixture(owner: self)
        let discovery = fixture.discovery()
        let duplicate = fixture.item(
            id: "other-source-duplicate",
            bundle: targetBundle,
            processIdentifier: 42,
            x: 10
        )
        let duplicated = AnchoredMenuBarDiscoveryResult(
            inventory: discovery.inventory,
            physicalItems: discovery.physicalItems + [duplicate],
            messages: []
        )

        XCTAssertNil(fixture.preparation(discovery: duplicated))
    }

    func testKnownUnreadableProviderCannotCreatePreparation() {
        let fixture = Fixture(owner: self)
        let topology = fixture.topology()
        let targetProvider = topology.items.first {
            $0.provider.bundleIdentifier == targetBundle
        }!.provider
        let unreadable = MenuBarTopologySnapshot(
            items: topology.items,
            runningProviders: topology.runningProviders,
            unreadableProviders: [targetProvider]
        )

        XCTAssertNil(fixture.preparation(topology: unreadable))
    }

    func testUnknownUnreadableHelperDoesNotInvalidatePreparation() {
        let fixture = Fixture(owner: self)
        let topology = fixture.topology()
        let helper = MenuBarTopologyProvider(
            bundleIdentifier: "com.example.unknown-helper",
            applicationName: "Unknown Helper",
            processIdentifier: 88
        )
        let withUnreadableHelper = MenuBarTopologySnapshot(
            items: topology.items,
            runningProviders: topology.runningProviders.union([helper]),
            unreadableProviders: [helper]
        )

        XCTAssertNotNil(fixture.preparation(topology: withUnreadableHelper))
    }

    func testContextRevisionChangeRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())

        XCTAssertNil(preparation.planIfUnchanged(
            physicalGuard: fixture.guardResult(),
            applications: fixture.applications(),
            contextRevision: contextRevision + 1,
            protectionPolicy: fixture.policy()
        ))
    }

    func testChangedGuardNativeIdentityRejectsInstantPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let items = fixture.items(source: "guard").map { item in
            guard item.bundleIdentifier == targetBundle else { return item }
            return fixture.item(
                id: "guard-target-replaced",
                bundle: item.bundleIdentifier,
                processIdentifier: item.processIdentifier,
                x: item.frame.origin.x,
                accessibilityIdentifier: "replacement.target.ax"
            )
        }

        XCTAssertNil(fixture.plan(preparation, guardItems: items))
    }

    func testSingleGuardSourceIdentityMismatchCannotCreatePreparation() {
        let fixture = Fixture(owner: self)
        let guardResult = fixture.guardResult()
        let physicalItems = guardResult.physicalItems.map { item in
            guard item.bundleIdentifier == targetBundle else { return item }
            return fixture.item(
                id: "guard-physical-target-mismatch",
                bundle: item.bundleIdentifier,
                processIdentifier: item.processIdentifier,
                x: item.frame.origin.x,
                accessibilityIdentifier: item.accessibilityIdentifier
            )
        }
        let inconsistent = AnchoredMenuBarDiscoveryResult(
            inventory: guardResult.inventory,
            physicalItems: physicalItems,
            messages: []
        )

        XCTAssertNil(fixture.preparation(guardResult: inconsistent))
    }

    func testCrossBoundaryTargetCannotCreatePreparation() {
        let fixture = Fixture(owner: self)
        var discoveryItems = fixture.items(source: "discovery")
        discoveryItems.append(fixture.item(
            id: "discovery-target-right",
            bundle: targetBundle,
            processIdentifier: 42,
            x: 90,
            accessibilityIdentifier: "target.right.ax"
        ))
        let discoveryPhysical = fixture.reidentified(
            discoveryItems,
            source: "discovery-physical"
        )
        let discovery = fixture.result(
            inventoryItems: discoveryItems,
            physicalItems: discoveryPhysical
        )
        let guardItems = fixture.reidentified(discoveryItems, source: "guard")

        XCTAssertNil(fixture.preparation(
            discovery: discovery,
            guardResult: fixture.result(
                inventoryItems: guardItems,
                physicalItems: guardItems
            ),
            topology: fixture.topology(items: discoveryItems)
        ))
    }

    func testCurrentProtectionPolicyCanInvalidateCachedTarget() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let protectedPolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: ownBundle,
            protectedBundleIdentifiers: [targetBundle]
        )

        XCTAssertNil(preparation.planIfUnchanged(
            physicalGuard: fixture.guardResult(),
            applications: fixture.applications(),
            contextRevision: contextRevision,
            protectionPolicy: protectedPolicy
        ))
    }

    private struct Fixture {
        unowned let owner: MenuBarInstantCollapsePreparationTests

        private var anchorIdentity: MenuBarAnchorIdentity {
            MenuBarAnchorIdentity(
                bundleIdentifier: owner.ownBundle,
                title: "Controller",
                accessibilityIdentifier: "controller.anchor.ax"
            )
        }

        func policy() -> MenuBarTargetProtectionPolicy {
            MenuBarTargetProtectionPolicy(ownBundleIdentifier: owner.ownBundle)
        }

        func applications(targetPID: Int32 = 42) -> [RunningAppSnapshot] {
            [
                RunningAppSnapshot(
                    bundleIdentifier: owner.targetBundle,
                    name: "Target",
                    processIdentifier: targetPID
                ),
                RunningAppSnapshot(
                    bundleIdentifier: owner.ownBundle,
                    name: "Controller",
                    processIdentifier: 7
                ),
                RunningAppSnapshot(
                    bundleIdentifier: owner.rightBundle,
                    name: "Right",
                    processIdentifier: 50
                ),
            ]
        }

        func item(
            id: String,
            bundle: String,
            processIdentifier: Int32,
            x: CGFloat,
            accessibilityIdentifier: String? = nil
        ) -> MenuBarOrderItem {
            MenuBarOrderItem(
                id: id,
                bundleIdentifier: bundle,
                applicationName: bundle == owner.ownBundle ? "Controller" : bundle,
                title: bundle == owner.ownBundle ? "Controller" : id,
                accessibilityIdentifier: accessibilityIdentifier,
                processIdentifier: processIdentifier,
                displayID: 1,
                frame: CGRect(x: x, y: 0, width: 20, height: 24)
            )
        }

        func items(
            source: String,
            targetPID: Int32 = 42,
            targetX: CGFloat = 10
        ) -> [MenuBarOrderItem] {
            [
                item(
                    id: "\(source)-target",
                    bundle: owner.targetBundle,
                    processIdentifier: targetPID,
                    x: targetX,
                    accessibilityIdentifier: "target.ax"
                ),
                item(
                    id: "\(source)-anchor",
                    bundle: owner.ownBundle,
                    processIdentifier: 7,
                    x: 40,
                    accessibilityIdentifier: anchorIdentity.accessibilityIdentifier
                ),
                item(
                    id: "\(source)-right",
                    bundle: owner.rightBundle,
                    processIdentifier: 50,
                    x: 70,
                    accessibilityIdentifier: "right.ax"
                ),
            ]
        }

        func reidentified(
            _ items: [MenuBarOrderItem],
            source: String
        ) -> [MenuBarOrderItem] {
            items.enumerated().map { index, item in
                self.item(
                    id: "\(source)-\(index)",
                    bundle: item.bundleIdentifier,
                    processIdentifier: item.processIdentifier,
                    x: item.frame.origin.x,
                    accessibilityIdentifier: item.accessibilityIdentifier
                )
            }
        }

        func result(
            inventoryItems: [MenuBarOrderItem],
            physicalItems: [MenuBarOrderItem],
            complete: Bool = true,
            unknownOwnershipCount: Int = 0,
            ambiguousIdentityCount: Int = 0
        ) -> AnchoredMenuBarDiscoveryResult {
            AnchoredMenuBarDiscoveryResult(
                inventory: AnchoredMenuBarInventory(
                    items: inventoryItems,
                    coverage: MenuBarInventoryCoverage(
                        expectedDisplayIDs: [1],
                        observedCandidateCount: inventoryItems.count
                            + unknownOwnershipCount + ambiguousIdentityCount,
                        resolvedItemCount: inventoryItems.count,
                        unknownOwnershipCount: unknownOwnershipCount,
                        ambiguousIdentityCount: ambiguousIdentityCount,
                        didTimeOut: !complete
                    ),
                    anchorIdentity: anchorIdentity
                ),
                physicalItems: physicalItems,
                messages: []
            )
        }

        func discovery(
            complete: Bool = true,
            unknownOwnershipCount: Int = 0
        ) -> AnchoredMenuBarDiscoveryResult {
            result(
                inventoryItems: items(source: "discovery"),
                physicalItems: items(source: "discovery-physical"),
                complete: complete,
                unknownOwnershipCount: unknownOwnershipCount
            )
        }

        func guardResult(
            items: [MenuBarOrderItem]? = nil,
            complete: Bool = true
        ) -> AnchoredMenuBarDiscoveryResult {
            let guardItems = items ?? self.items(source: "guard")
            return result(
                inventoryItems: guardItems,
                physicalItems: guardItems,
                complete: complete
            )
        }

        func topology(
            items: [MenuBarOrderItem]? = nil
        ) -> MenuBarTopologySnapshot {
            let sourceItems = items ?? self.items(source: "discovery")
            return MenuBarTopologySnapshot(items: sourceItems.enumerated().map { index, item in
                let provider = MenuBarTopologyProvider(
                    bundleIdentifier: item.bundleIdentifier,
                    applicationName: item.applicationName,
                    processIdentifier: item.processIdentifier
                )
                return MenuBarTopologyItemSnapshot(
                    provider: provider,
                    identityKey: "identifier:\(index)",
                    identityStrength: .strong,
                    accessibilityIdentifier: "topology.\(index)",
                    title: item.title,
                    itemDescription: nil,
                    value: nil
                )
            })
        }

        func preparation(
            discovery: AnchoredMenuBarDiscoveryResult? = nil,
            guardResult: AnchoredMenuBarDiscoveryResult? = nil,
            topology: MenuBarTopologySnapshot? = nil
        ) -> MenuBarInstantCollapsePreparation? {
            MenuBarInstantCollapsePreparation(
                discovery: discovery ?? self.discovery(),
                physicalGuard: guardResult ?? self.guardResult(),
                topology: topology ?? self.topology(),
                applications: applications(),
                contextRevision: owner.contextRevision,
                protectionPolicy: policy()
            )
        }

        func plan(
            _ preparation: MenuBarInstantCollapsePreparation,
            guardItems: [MenuBarOrderItem]? = nil,
            applications: [RunningAppSnapshot]? = nil
        ) -> MenuBarCollapsePlan? {
            preparation.planIfUnchanged(
                physicalGuard: guardResult(items: guardItems),
                applications: applications ?? self.applications(),
                contextRevision: owner.contextRevision,
                protectionPolicy: policy()
            )
        }
    }
}
