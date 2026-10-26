import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarInstantStructureCollapsePreparationTests: XCTestCase {
    private let contextRevision: UInt64 = 17
    private let targetBundle = "com.example.target"
    private let rightBundle = "com.example.right"
    private let ownBundle = "com.example.controller"
    private let providerBundle = "com.apple.MenuBarAgent"

    func testSettlingCheckDoesNotRejectTransientFirstSampleOrConfirmOneGoodRead() {
        var check = MenuBarCollapsePostcondition.SettlingCheck()
        XCTAssertEqual(check.record(.restricted), .wait)
        XCTAssertEqual(check.record(.verified), .wait)
        XCTAssertEqual(check.record(.transient), .wait)
        XCTAssertEqual(check.record(.verified), .wait)
        XCTAssertEqual(check.record(.verified), .verified)
        var denied = MenuBarCollapsePostcondition.SettlingCheck()
        XCTAssertEqual(denied.record(.restricted), .wait)
        XCTAssertEqual(denied.record(.restricted), .restricted)
        XCTAssertEqual(denied.record(.unsafe), .unsafe)
    }

    func testRestrictedRootAllowsReadableRoleButNeverMeansEmptyOrForeignRoot() {
        for role: MenuBarRawPhysicalRead<String> in [.failed, .value("AXApplication")] {
            func snapshot(pid: Int32 = 500, children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]> = .failed) -> MenuBarRawPhysicalStructureSnapshot {
                .init(model: .init(providerProcessIdentifier: .value(500), displays: [], nodes: [
                    .init(path: [], processIdentifier: .value(pid), role: role, identifier: .absent,
                        frame: .absent, position: .absent, size: .absent, children: children)
                ]))
            }
            XCTAssertTrue(MenuBarCollapseRuntime.physicalTreeIsRestricted(snapshot()))
            XCTAssertFalse(MenuBarCollapseRuntime.physicalTreeIsRestricted(snapshot(pid: 7)))
            XCTAssertFalse(MenuBarCollapseRuntime.physicalTreeIsRestricted(snapshot(children: .value([]))))
            XCTAssertFalse(MenuBarCollapseRuntime.physicalTreeIsRestricted(snapshot(children: .absent)))
        }
    }

    func testPhysicalPostconditionRejectsMissingEntryOrRightItemAndRemainingTarget() throws {
        let fixture = Fixture(owner: self)
        let before = fixture.discovery().inventory
        let plan = try MenuBarCollapsePlan(
            runningBundleIdentifiers: Set(fixture.applications().map(\.bundleIdentifier)),
            targetBundleIdentifiers: [targetBundle], protectionPolicy: fixture.policy())
        let retained = fixture.reidentified(before.items.filter { $0.bundleIdentifier != targetBundle }, source: "after")
        func verified(_ items: [MenuBarOrderItem]) -> Bool {
            MenuBarCollapsePostcondition.isSatisfied(before: before,
                after: fixture.discovery(items: items).inventory, plan: plan)
        }
        XCTAssertTrue(verified(retained))
        XCTAssertFalse(verified(retained.filter { $0.bundleIdentifier != ownBundle }), "all hidden is not success")
        XCTAssertFalse(verified(retained.filter { $0.bundleIdentifier != rightBundle }))
        XCTAssertFalse(verified(before.items), "acknowledged but unchanged is not success")
        XCTAssertFalse(verified([]))
        XCTAssertFalse(verified(retained + [fixture.item(id: "unexpected", bundle: "new.app", processIdentifier: 99, x: 120)]))
        XCTAssertFalse(verified(retained + [fixture.item(id: "duplicate", bundle: ownBundle, processIdentifier: 7, x: 120)]))
    }

    func testOpaqueProxyInventoryRequiresOwnedEntryEvidenceAndNeverReadsAppChildren() throws {
        let fixture = Fixture(owner: self)
        let raw = fixture.physicalSnapshot(items: fixture.items(source: "proxy"), opaque: true)
        XCTAssertTrue(raw.isComplete)
        XCTAssertTrue(raw.model.nodes.filter(\.isOpaqueApplicationProxy).allSatisfy {
            $0.children == .absent && $0.identifier == .absent && $0.frame == .absent && $0.role == .absent
        })
        func inventory(_ owned: MenuBarOwnedStatusItemEvidence?) -> AnchoredMenuBarInventory? {
            MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: raw,
                applicationsBefore: fixture.applications(), applicationsAfter: fixture.applications(),
                anchor: fixture.discovery().inventory.anchorIdentity, ownedStatusItems: owned)
        }
        XCTAssertNil(inventory(nil))
        XCTAssertNil(inventory(.init(processIdentifier: 7, mainEntryVisible: false, visibleItemCount: 1)))
        XCTAssertNil(inventory(.init(processIdentifier: 8, mainEntryVisible: true, visibleItemCount: 1)))
        XCTAssertNil(inventory(.init(processIdentifier: 7, mainEntryVisible: true, visibleItemCount: 2)))
        let actual = try XCTUnwrap(inventory(.init(processIdentifier: 7, mainEntryVisible: true, visibleItemCount: 1)))
        XCTAssertEqual(try actual.collapseTargetBundleIdentifiers(protectionPolicy: fixture.policy()), [targetBundle])
    }

    func testOpaqueOwnEntriesMustHaveInvariantTargetsForEveryPossibleBoundary() throws {
        let fixture = Fixture(owner: self)
        let base = fixture.items(source: "base")
        let evidence = MenuBarOwnedStatusItemEvidence(processIdentifier: 7, mainEntryVisible: true, visibleItemCount: 2)
        for (activityX, expected) in [(CGFloat(60), true), (CGFloat(5), false)] {
            let activity = fixture.item(id: "activity", bundle: ownBundle, processIdentifier: 7, x: activityX)
            let raw = fixture.physicalSnapshot(items: base + [activity], opaque: true)
            let inventory = MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: raw,
                applicationsBefore: fixture.applications(), applicationsAfter: fixture.applications(),
                anchor: fixture.discovery().inventory.anchorIdentity, ownedStatusItems: evidence)
            XCTAssertEqual(inventory != nil, expected)
        }
    }

    func testEmptyQualifiedSecondaryDisplayDoesNotRequireAnotherAnchor() throws {
        let fixture = Fixture(owner: self)
        let raw = fixture.physicalSnapshot(items: fixture.items(source: "one-populated"), emptyDisplay: true)
        let inventory = try XCTUnwrap(MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: raw,
            applicationsBefore: fixture.applications(), applicationsAfter: fixture.applications(), anchor: fixture.discovery().inventory.anchorIdentity))
        XCTAssertEqual(inventory.coverage.expectedDisplayIDs, [1])
    }

    func testTypedPhysicalEvidenceEnablesMissingLegacyPhysicalItemsAndRenewsAtClick() throws {
        let fixture = Fixture(owner: self)
        let full = fixture.discovery()
        let discovery = AnchoredMenuBarDiscoveryResult(
            inventory: full.inventory, physicalItems: [], messages: []
        )
        let raw = fixture.physicalSnapshot(items: full.inventory.items)
        XCTAssertNotNil(MenuBarPhysicalInventoryEvidence(snapshot: raw, inventory: full.inventory))
        let preparation = try XCTUnwrap(fixture.preparation(
            discovery: discovery, before: raw, after: raw
        ))
        XCTAssertEqual(fixture.plan(preparation, structure: raw)?.targetBundleIdentifiers, [targetBundle])
        XCTAssertNil(fixture.plan(preparation, structure: fixture.rawSnapshot()))
    }

    func testFreshPhysicalProofRenewsAcrossNonPhysicalRawChangesButRejectsRealChanges() throws {
        let fixture = Fixture(owner: self)
        let items = fixture.discovery().inventory.items
        let original = fixture.physicalSnapshot(items: items)
        let preparation = try XCTUnwrap(fixture.preparation(before: original, after: original))
        XCTAssertTrue(preparation.hasIndependentPhysicalBaseline)
        let fresh = fixture.physicalSnapshot(items: items, marker: "new-container-metadata")
        XCTAssertNotEqual(original.revision, fresh.revision)
        XCTAssertNotNil(fixture.plan(preparation, structure: fresh))
        for mode in ["wrongOwner", "wrongIdentifier", "unknownLeaf", "outsideDisplay", "cycle", "changedDisplay"] {
            XCTAssertNil(fixture.plan(preparation,
                structure: fixture.physicalSnapshot(items: items, invalid: mode, marker: "fresh")), mode)
        }
        XCTAssertNil(fixture.plan(preparation, structure: fixture.physicalSnapshot(
            items: fixture.reidentified(items, source: "moved", targetX: 11), marker: "moved"
        )))
        XCTAssertNil(fixture.plan(preparation, structure: fresh, contextRevision: contextRevision + 1))
        XCTAssertNil(fixture.plan(preparation, structure: fresh, applications: fixture.applications(targetPID: 43)))
    }

    func testCurrentPhysicalPlanAllowsSystemItemRemovalAndChangedPixelsWithoutChangingTargets() throws {
        let fixture = Fixture(owner: self)
        let base = fixture.items(source: "base")
        let system = fixture.item(id: "system", bundle: providerBundle, processIdentifier: 900, x: 100)
        let original = fixture.physicalSnapshot(items: base + [system])
        let preparation = try XCTUnwrap(fixture.preparation(
            discovery: fixture.discovery(items: base + [system]), before: original, after: original,
            topology: fixture.topology(items: base + [system])
        ))
        let current = fixture.physicalSnapshot(items: fixture.reidentified(base, source: "shifted", targetX: 12))
        let result = try XCTUnwrap(preparation.currentPhysicalPlan(structure: current,
            applicationsBeforeRead: fixture.applications(), applications: fixture.applications(),
            contextRevision: contextRevision, protectionPolicy: fixture.policy()))
        XCTAssertEqual(result.plan.targetBundleIdentifiers, [targetBundle])
        XCTAssertEqual(result.inventory.items.count, 3)
        XCTAssertTrue(result.inventory.items.contains { $0.bundleIdentifier == targetBundle && $0.frame.minX == 12 })
    }

    func testCurrentPhysicalPlanRejectsUnknownOwnershipMissingBoundaryAndChangedTargets() throws {
        let fixture = Fixture(owner: self)
        let items = fixture.items(source: "base")
        let original = fixture.physicalSnapshot(items: items)
        let preparation = try XCTUnwrap(fixture.preparation(before: original, after: original))
        func plan(_ raw: MenuBarRawPhysicalStructureSnapshot) -> MenuBarCollapsePlan? {
            preparation.currentPhysicalPlan(structure: raw, applicationsBeforeRead: fixture.applications(),
                applications: fixture.applications(), contextRevision: contextRevision,
                protectionPolicy: fixture.policy())?.plan
        }
        for invalid in ["unknownLeaf", "wrongOwner", "wrongIdentifier", "badWindow", "cycle", "changedDisplay"] {
            XCTAssertNil(plan(fixture.physicalSnapshot(items: items, invalid: invalid)), invalid)
        }
        XCTAssertNil(plan(fixture.physicalSnapshot(items: Array(items.dropFirst()))))
        XCTAssertNil(plan(fixture.physicalSnapshot(items: Array(items.prefix(1)))))
        let rightNowLeft = fixture.item(id: "right-left", bundle: rightBundle, processIdentifier: 50, x: 2)
        XCTAssertNil(plan(fixture.physicalSnapshot(items: [rightNowLeft] + items.dropLast())))
        let crossBoundary = fixture.item(id: "target-right", bundle: targetBundle, processIdentifier: 42, x: 100)
        XCTAssertNil(plan(fixture.physicalSnapshot(items: items + [crossBoundary])))
    }

    func testTypedPhysicalEvidenceFailsClosedForMissingExtraDuplicateOrWrongGeometryItems() {
        let fixture = Fixture(owner: self)
        let items = fixture.discovery().inventory.items
        let inventory = fixture.discovery().inventory
        let variants = [
            Array(items.dropLast()), items + [items[0]],
            fixture.reidentified(items, source: "moved", targetX: 11),
            items + [fixture.item(id: "extra", bundle: rightBundle, processIdentifier: 50, x: 100)]
        ]
        for variant in variants {
            XCTAssertNil(MenuBarPhysicalInventoryEvidence(
                snapshot: fixture.physicalSnapshot(items: variant), inventory: inventory
            ))
        }
    }

    func testTypedPhysicalEvidenceRejectsUnqualifiedRootUnknownLeafAndWrongOwner() {
        let fixture = Fixture(owner: self)
        let inventory = fixture.discovery().inventory
        for mode in ["unknownLeaf", "wrongOwner", "badWindow", "duplicateRoot", "cycle", "wrongIdentifier", "failedRole", "outsideDisplay"] {
            XCTAssertNil(MenuBarPhysicalInventoryEvidence(
                snapshot: fixture.physicalSnapshot(items: inventory.items, invalid: mode),
                inventory: inventory
            ), mode)
        }
    }

    func testStableCompletePreparationBuildsFreshPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())

        XCTAssertEqual(preparation.inventory, fixture.discovery().inventory)
        XCTAssertEqual(preparation.topology, fixture.topology())
        XCTAssertEqual(
            fixture.plan(preparation)?.targetBundleIdentifiers,
            [targetBundle]
        )
    }

    func testRawBeforeAfterMismatchOrIncompleteReadRejectsPreparation() {
        let fixture = Fixture(owner: self)

        XCTAssertNil(fixture.preparation(
            before: fixture.rawSnapshot(marker: "before"),
            after: fixture.rawSnapshot(marker: "after")
        ))
        XCTAssertNil(fixture.preparation(
            before: fixture.rawSnapshot(incomplete: true)
        ))
        XCTAssertNil(fixture.preparation(
            after: fixture.rawSnapshot(incomplete: true)
        ))
    }

    func testChangedOrIncompleteCurrentRawReadRejectsPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())

        XCTAssertNil(fixture.plan(
            preparation,
            structure: fixture.rawSnapshot(marker: "changed")
        ))
        XCTAssertNil(fixture.plan(
            preparation,
            structure: fixture.rawSnapshot(incomplete: true)
        ))
    }

    func testTargetProcessMapMustMatchBeforeDuringAndAfterDiscovery() {
        let fixture = Fixture(owner: self)
        let stable = fixture.applications()
        let restarted = fixture.applications(targetPID: 43)
        let variants: [(String, [RunningAppSnapshot], [RunningAppSnapshot], [RunningAppSnapshot])] = [
            ("before", restarted, stable, stable),
            ("during", stable, restarted, stable),
            ("after", stable, stable, restarted),
        ]

        for (stage, before, during, after) in variants {
            XCTAssertNil(
                fixture.preparation(
                    applicationsBefore: before,
                    applicationsDuring: during,
                    applicationsAfter: after
                ),
                "changed target process map at \(stage) must fail closed"
            )
        }
    }

    func testTargetHelperSetMustMatchBeforeDuringAndAfterDiscovery() {
        let fixture = Fixture(owner: self)
        let stable = fixture.applications()
        let withHelper = stable + [RunningAppSnapshot(
            bundleIdentifier: targetBundle,
            name: "Target Helper",
            processIdentifier: 43
        )]
        let variants: [(String, [RunningAppSnapshot], [RunningAppSnapshot], [RunningAppSnapshot])] = [
            ("before", withHelper, stable, stable),
            ("during", stable, withHelper, stable),
            ("after", stable, stable, withHelper),
        ]

        for (stage, before, during, after) in variants {
            XCTAssertNil(
                fixture.preparation(
                    applicationsBefore: before,
                    applicationsDuring: during,
                    applicationsAfter: after
                ),
                "changed target helper set at \(stage) must fail closed"
            )
        }
    }

    func testProviderProcessMustMatchBeforeDuringAndAfterDiscovery() {
        let fixture = Fixture(owner: self)
        let stable = fixture.applications()
        let restarted = fixture.applications(providerPID: 901)
        let variants: [(String, [RunningAppSnapshot], [RunningAppSnapshot], [RunningAppSnapshot])] = [
            ("before", restarted, stable, stable),
            ("during", stable, restarted, stable),
            ("after", stable, stable, restarted),
        ]

        for (stage, before, during, after) in variants {
            XCTAssertNil(
                fixture.preparation(
                    applicationsBefore: before,
                    applicationsDuring: during,
                    applicationsAfter: after
                ),
                "changed MenuBarAgent process at \(stage) must fail closed"
            )
        }
    }

    func testMissingAmbiguousOrInvalidProviderRejectsPreparation() {
        let fixture = Fixture(owner: self)
        let withoutProvider = fixture.applications().filter {
            $0.bundleIdentifier != providerBundle
        }
        let duplicateProvider = fixture.applications() + [RunningAppSnapshot(
            bundleIdentifier: providerBundle,
            name: "Second MenuBarAgent",
            processIdentifier: 901
        )]
        let invalidProvider = fixture.applications(providerPID: 0)

        XCTAssertNil(fixture.preparation(applicationsBefore: withoutProvider))
        XCTAssertNil(fixture.preparation(applicationsDuring: duplicateProvider))
        XCTAssertNil(fixture.preparation(applicationsAfter: invalidProvider))
    }

    func testIncompleteFullInventoryRejectsPreparation() {
        let fixture = Fixture(owner: self)

        XCTAssertNil(fixture.preparation(discovery: fixture.discovery(complete: false)))
    }

    func testInventoryPhysicalParityMismatchRejectsPreparation() {
        let fixture = Fixture(owner: self)

        XCTAssertNil(fixture.preparation(
            discovery: fixture.discovery(physicalTargetX: 11)
        ))
    }

    func testKnownUnreadableTargetTopologyRejectsPreparation() throws {
        let fixture = Fixture(owner: self)
        let topology = fixture.topology()
        let targetProvider = try XCTUnwrap(topology.items.first {
            $0.provider.bundleIdentifier == targetBundle
        }?.provider)
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
            bundleIdentifier: "com.example.unseen-helper",
            applicationName: "Unseen Helper",
            processIdentifier: 88
        )
        let withUnknownUnreadableHelper = MenuBarTopologySnapshot(
            items: topology.items,
            runningProviders: topology.runningProviders.union([helper]),
            unreadableProviders: [helper]
        )

        XCTAssertNotNil(fixture.preparation(topology: withUnknownUnreadableHelper))
    }

    func testProtectedTargetRejectsPreparation() {
        let fixture = Fixture(owner: self)
        let protectedPolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: ownBundle,
            protectedBundleIdentifiers: [targetBundle]
        )

        XCTAssertNil(fixture.preparation(protectionPolicy: protectedPolicy))
    }

    func testCrossBoundaryTargetRejectsPreparation() {
        let fixture = Fixture(owner: self)
        let crossBoundaryItems = fixture.items(source: "discovery") + [fixture.item(
            id: "discovery-target-right",
            bundle: targetBundle,
            processIdentifier: 42,
            x: 100,
            accessibilityIdentifier: "target.right.ax"
        )]
        let discovery = fixture.discovery(items: crossBoundaryItems)

        XCTAssertNil(fixture.preparation(
            discovery: discovery,
            topology: fixture.topology(items: crossBoundaryItems)
        ))
    }

    func testContextAndCurrentProtectionChangesRejectPlan() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let protectedPolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: ownBundle,
            protectedBundleIdentifiers: [targetBundle]
        )

        XCTAssertNil(fixture.plan(
            preparation,
            contextRevision: contextRevision + 1
        ))
        XCTAssertNil(fixture.plan(
            preparation,
            protectionPolicy: protectedPolicy
        ))
    }

    func testCurrentTargetAndProviderMapsMustMatchOnBothSidesOfRawRead() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let stable = fixture.applications()
        let variants: [(String, [RunningAppSnapshot], [RunningAppSnapshot])] = [
            ("target before read", fixture.applications(targetPID: 43), stable),
            ("target after read", stable, fixture.applications(targetPID: 43)),
            ("provider before read", fixture.applications(providerPID: 901), stable),
            ("provider after read", stable, fixture.applications(providerPID: 901)),
        ]

        for (stage, beforeRead, current) in variants {
            XCTAssertNil(
                fixture.plan(
                    preparation,
                    applicationsBeforeRead: beforeRead,
                    applications: current
                ),
                "changed process map at \(stage) must fail closed"
            )
        }
    }

    func testFreshCurrentApplicationsDriveAllowlist() throws {
        let fixture = Fixture(owner: self)
        let preparation = try XCTUnwrap(fixture.preparation())
        let newHelper = "com.example.new-helper"
        let currentApplications = fixture.applications() + [RunningAppSnapshot(
            bundleIdentifier: newHelper,
            name: "New Helper",
            processIdentifier: 91
        )]

        let plan = try XCTUnwrap(fixture.plan(
            preparation,
            applicationsBeforeRead: fixture.applications(),
            applications: currentApplications
        ))

        XCTAssertTrue(plan.allowedBundleIdentifiers.contains(newHelper))
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains(targetBundle))
    }

    private struct Fixture {
        unowned let owner: MenuBarInstantStructureCollapsePreparationTests

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

        func applications(
            targetPID: Int32 = 42,
            providerPID: Int32 = 900
        ) -> [RunningAppSnapshot] {
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
                RunningAppSnapshot(
                    bundleIdentifier: owner.providerBundle,
                    name: "MenuBarAgent",
                    processIdentifier: providerPID
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

        func items(source: String) -> [MenuBarOrderItem] {
            [
                item(
                    id: "\(source)-target",
                    bundle: owner.targetBundle,
                    processIdentifier: 42,
                    x: 10,
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
            source: String,
            targetX: CGFloat? = nil
        ) -> [MenuBarOrderItem] {
            items.enumerated().map { index, item in
                self.item(
                    id: "\(source)-\(index)",
                    bundle: item.bundleIdentifier,
                    processIdentifier: item.processIdentifier,
                    x: item.bundleIdentifier == owner.targetBundle
                        ? targetX ?? item.frame.origin.x
                        : item.frame.origin.x,
                    accessibilityIdentifier: item.accessibilityIdentifier
                )
            }
        }

        func discovery(
            items: [MenuBarOrderItem]? = nil,
            complete: Bool = true,
            physicalTargetX: CGFloat? = nil
        ) -> AnchoredMenuBarDiscoveryResult {
            let inventoryItems = items ?? self.items(source: "discovery")
            return AnchoredMenuBarDiscoveryResult(
                inventory: AnchoredMenuBarInventory(
                    items: inventoryItems,
                    coverage: MenuBarInventoryCoverage(
                        expectedDisplayIDs: [1],
                        observedCandidateCount: inventoryItems.count,
                        resolvedItemCount: inventoryItems.count,
                        didTimeOut: !complete
                    ),
                    anchorIdentity: anchorIdentity
                ),
                physicalItems: reidentified(
                    inventoryItems,
                    source: "physical",
                    targetX: physicalTargetX
                ),
                messages: []
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

        func rawSnapshot(
            marker: String = "stable",
            incomplete: Bool = false
        ) -> MenuBarRawPhysicalStructureSnapshot {
            var diagnostics = MenuBarRawPhysicalStructureDiagnostics()
            if incomplete { diagnostics.record(.deadlineExceeded) }
            let root = MenuBarRawPhysicalNode(
                path: [],
                processIdentifier: .value(900),
                role: .value("AXApplication"),
                identifier: .value(marker),
                frame: .absent,
                position: .absent,
                size: .absent,
                children: .value([])
            )
            return MenuBarRawPhysicalStructureSnapshot(
                model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: .value(900),
                    displays: [MenuBarRawPhysicalDisplay(
                        id: 1,
                        bounds: .value(.init(x: 0, y: 0, width: 1_512, height: 982))
                    )],
                    nodes: [root]
                ),
                diagnostics: diagnostics
            )
        }

        func physicalSnapshot(items: [MenuBarOrderItem], invalid: String? = nil, marker: String = "stable",
                              opaque: Bool = false, emptyDisplay: Bool = false) -> MenuBarRawPhysicalStructureSnapshot {
            func node(_ path: [Int], pid: Int32 = 900, role: MenuBarRawPhysicalRead<String>,
                      identifier: MenuBarRawPhysicalRead<String> = .absent,
                      frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> = .absent,
                      children: [MenuBarRawPhysicalChild] = []) -> MenuBarRawPhysicalNode {
                MenuBarRawPhysicalNode(path: path, processIdentifier: .value(pid), role: role,
                    identifier: identifier, frame: frame, position: .absent, size: .absent,
                    children: .value(children))
            }
            let windowFrame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> = .value(.init(
                x: 0, y: invalid == "badWindow" ? 100 : 0, width: 1512, height: 24
            ))
            var rootEdges: [MenuBarRawPhysicalChild] = [.node(path: [0])]
            if invalid == "duplicateRoot" { rootEdges.append(.node(path: [1])) }
            if emptyDisplay { rootEdges.append(.node(path: [1])) }
            var nodes = [node([], role: .value("AXApplication"), identifier: .value(marker), children: rootEdges)]
            nodes.append(node([0], role: .value("AXWindow"), frame: windowFrame,
                children: items.indices.map { .node(path: [0, $0]) }))
            if invalid == "duplicateRoot" {
                nodes.append(node([1], role: .value("AXWindow"), frame: windowFrame,
                    children: [.reference(firstPath: [0, 0])]))
            }
            if emptyDisplay {
                nodes.append(node([1], role: .value("AXWindow"), frame: .value(.init(x: 1512, y: 0, width: 1000, height: 24))))
            }
            for (index, item) in items.enumerated() {
                // Roleless wrappers with geometry are retained, not treated as leaves.
                nodes.append(node([0, index], role: .absent,
                    frame: .value(.init(x: Double(item.frame.minX), y: 0, width: 20, height: 24)),
                    children: [.node(path: [0, index, 0])]))
                if opaque, item.processIdentifier != 900 {
                    nodes.append(.init(path: [0, index, 0], processIdentifier: .value(item.processIdentifier),
                        role: .absent, identifier: .absent, frame: .absent, position: .absent,
                        size: .absent, children: .absent, isOpaqueApplicationProxy: true))
                } else {
                nodes.append(node([0, index, 0],
                    pid: invalid == "wrongOwner" && index == 0 ? 999 : item.processIdentifier,
                    role: invalid == "failedRole" ? .failed : invalid == "unknownLeaf" ? .absent : .value("AXButton"),
                    identifier: .value(invalid == "wrongIdentifier" ? "wrong" : item.accessibilityIdentifier ?? ""),
                    frame: .value(.init(x: Double(item.frame.minX), y: invalid == "outsideDisplay" ? 200 : 0, width: 20, height: 24)),
                    children: invalid == "cycle" ? [.reference(firstPath: [0])] : []))
                }
            }
            var displays = [MenuBarRawPhysicalDisplay(id: 1, bounds: .value(.init(x: 0, y: 0, width: invalid == "changedDisplay" ? 1600 : 1512, height: 982)))]
            if emptyDisplay { displays.append(.init(id: 2, bounds: .value(.init(x: 1512, y: 0, width: 1000, height: 800)))) }
            return MenuBarRawPhysicalStructureSnapshot(model: .init(
                providerProcessIdentifier: .value(900),
                displays: displays,
                nodes: nodes
            ))
        }

        func preparation(
            discovery: AnchoredMenuBarDiscoveryResult? = nil,
            before: MenuBarRawPhysicalStructureSnapshot? = nil,
            after: MenuBarRawPhysicalStructureSnapshot? = nil,
            topology: MenuBarTopologySnapshot? = nil,
            applicationsBefore: [RunningAppSnapshot]? = nil,
            applicationsDuring: [RunningAppSnapshot]? = nil,
            applicationsAfter: [RunningAppSnapshot]? = nil,
            protectionPolicy: MenuBarTargetProtectionPolicy? = nil
        ) -> MenuBarInstantStructureCollapsePreparation? {
            MenuBarInstantStructureCollapsePreparation(
                discovery: discovery ?? self.discovery(),
                before: before ?? rawSnapshot(),
                after: after ?? rawSnapshot(),
                topology: topology ?? self.topology(),
                applicationsBefore: applicationsBefore ?? applications(),
                applicationsDuring: applicationsDuring ?? applications(),
                applicationsAfter: applicationsAfter ?? applications(),
                contextRevision: owner.contextRevision,
                protectionPolicy: protectionPolicy ?? policy()
            )
        }

        func plan(
            _ preparation: MenuBarInstantStructureCollapsePreparation,
            structure: MenuBarRawPhysicalStructureSnapshot? = nil,
            applicationsBeforeRead: [RunningAppSnapshot]? = nil,
            applications: [RunningAppSnapshot]? = nil,
            contextRevision: UInt64? = nil,
            protectionPolicy: MenuBarTargetProtectionPolicy? = nil
        ) -> MenuBarCollapsePlan? {
            preparation.planIfUnchanged(
                structure: structure ?? rawSnapshot(),
                applicationsBeforeRead: applicationsBeforeRead ?? self.applications(),
                applications: applications ?? self.applications(),
                contextRevision: contextRevision ?? owner.contextRevision,
                protectionPolicy: protectionPolicy ?? policy()
            )
        }
    }
}
