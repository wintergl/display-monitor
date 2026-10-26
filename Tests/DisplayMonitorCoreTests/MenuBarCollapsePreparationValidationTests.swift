import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarCollapsePreparationValidationTests: XCTestCase {
    func testIdenticalCompleteLayoutsRemainValidAfterCapture() {
        let inventory = makeInventory()
        XCTAssertTrue(validate(inventory, inventory))
    }

    func testChangedFrameInvalidatesSnapshotAndOldCollapsePlan() {
        XCTAssertFalse(validate(makeInventory(), makeInventory(targetX: 12)))
    }

    func testRestartedProviderCannotReuseOldSnapshot() {
        XCTAssertFalse(validate(makeInventory(), makeInventory(targetPID: 43)))
    }

    func testIncompleteFinalScanCannotAuthorizeCollapse() {
        XCTAssertFalse(validate(makeInventory(), makeInventory(complete: false)))
    }

    func testProviderTopologyChangeInvalidatesEvenIdenticalVisibleItems() {
        let inventory = makeInventory()
        XCTAssertFalse(MenuBarCollapsePreparationValidation.isUnchanged(
            before: inventory,
            after: inventory,
            initialTopology: makeTopology(identity: "before"),
            finalTopology: makeTopology(identity: "after")
        ))
    }

    func testEmptyRevisionIsNeverAccepted() {
        let inventory = makeInventory()
        XCTAssertFalse(MenuBarCollapsePreparationValidation.isUnchanged(
            before: inventory,
            after: inventory,
            initialTopology: MenuBarTopologySnapshot(items: []),
            finalTopology: MenuBarTopologySnapshot(items: [])
        ))
    }

    func testStableIdentityAllowsOrdinaryTitleRefreshDuringCapture() {
        let before = makeInventory(targetTitle: "同步 20%")
        let after = makeInventory(targetTitle: "同步 21%")
        XCTAssertTrue(MenuBarCollapsePreparationValidation.isUnchanged(
            before: before,
            after: after,
            initialTopology: makeTopology(identity: "target", title: "同步 20%"),
            finalTopology: makeTopology(identity: "target", title: "同步 21%")
        ))
    }

    func testKnownAmbiguousProviderCannotAuthorizeCollapse() {
        let inventory = makeInventory()
        let topology = makeTopology()
        let ambiguous = MenuBarTopologySnapshot(
            items: topology.items,
            ambiguousProviders: [topology.items[0].provider]
        )

        XCTAssertFalse(MenuBarCollapsePreparationValidation.isUnchanged(
            before: inventory,
            after: inventory,
            initialTopology: ambiguous,
            finalTopology: ambiguous
        ))
    }

    func testUnreadableHelperWithoutKnownItemDoesNotBlockPreparation() {
        let inventory = makeInventory()
        let topology = makeTopology()
        let helper = MenuBarTopologyProvider(
            bundleIdentifier: "example.helper",
            applicationName: "Helper",
            processIdentifier: 99
        )
        let withUnreadableHelper = MenuBarTopologySnapshot(
            items: topology.items,
            unreadableProviders: [helper]
        )

        XCTAssertTrue(MenuBarCollapsePreparationValidation.isUnchanged(
            before: inventory,
            after: inventory,
            initialTopology: withUnreadableHelper,
            finalTopology: withUnreadableHelper
        ))
    }

    private func validate(_ before: AnchoredMenuBarInventory, _ after: AnchoredMenuBarInventory) -> Bool {
        MenuBarCollapsePreparationValidation.isUnchanged(
            before: before,
            after: after,
            initialTopology: makeTopology(),
            finalTopology: makeTopology()
        )
    }

    private func makeInventory(
        targetX: CGFloat = 10,
        targetPID: Int32 = 42,
        complete: Bool = true,
        targetTitle: String = "Upload"
    ) -> AnchoredMenuBarInventory {
        let identity = MenuBarAnchorIdentity(bundleIdentifier: "example.controller", title: "Controller")
        let items = [
            MenuBarOrderItem(
                id: "target", bundleIdentifier: "example.target", applicationName: "Target",
                title: targetTitle, accessibilityIdentifier: "target.item",
                processIdentifier: targetPID, displayID: 1,
                frame: CGRect(x: targetX, y: 0, width: 22, height: 22)
            ),
            MenuBarOrderItem(
                id: "anchor", bundleIdentifier: identity.bundleIdentifier, applicationName: "Controller",
                title: identity.title, processIdentifier: 7, displayID: 1,
                frame: CGRect(x: 40, y: 0, width: 22, height: 22)
            ),
        ]
        return AnchoredMenuBarInventory(
            items: items,
            coverage: MenuBarInventoryCoverage(
                expectedDisplayIDs: [1], observedCandidateCount: items.count,
                resolvedItemCount: items.count, didTimeOut: !complete
            ),
            anchorIdentity: identity
        )
    }

    private func makeTopology(
        identity: String = "target",
        title: String = "Upload"
    ) -> MenuBarTopologySnapshot {
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
}
