import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarOrderPlannerTests: XCTestCase {
    func testSameSegmentReorderPreservesAnchorAndRightSide() throws {
        let layout = layout(left: ["a", "b", "fixed", "c", "d"])
        XCTAssertEqual(try MenuBarQuickBarOrderPlanner.desiredFullOrder(
            layout: layout,
            originalQuickBarIDs: ["a", "b", "fixed", "c", "d"],
            proposedQuickBarIDs: ["b", "a", "fixed", "d", "c"],
            movableItemIDs: ["a", "b", "c", "d"]
        ), ["b", "a", "fixed", "d", "c", "anchor", "right"])
    }

    func testProtectedSlotCannotMoveOrBeCrossed() {
        let layout = layout(left: ["a", "fixed", "b"])
        for proposed in [["fixed", "a", "b"], ["b", "fixed", "a"]] {
            XCTAssertThrowsError(try MenuBarQuickBarOrderPlanner.desiredFullOrder(
                layout: layout,
                originalQuickBarIDs: ["a", "fixed", "b"],
                proposedQuickBarIDs: proposed,
                movableItemIDs: ["a", "b"]
            ))
        }
    }

    func testOmittedSystemAndVisibleItemsAreAlsoBoundaries() {
        for movable: Set<String> in [["a", "b"], ["a", "b", "omitted"]] {
            XCTAssertThrowsError(try MenuBarQuickBarOrderPlanner.desiredFullOrder(
                layout: layout(left: ["a", "omitted", "b"]),
                originalQuickBarIDs: ["a", "b"],
                proposedQuickBarIDs: ["b", "a"],
                movableItemIDs: movable
            ))
        }
    }

    func testStaleMissingDuplicateAndChangedCatalogsAreRejected() {
        let layout = layout(left: ["a", "b"])
        let cases: [([String], [String])] = [
            (["a", "b"], ["b"]),
            (["a", "b"], ["b", "b"]),
            (["a", "b"], ["b", "new"]),
            (["b", "a"], ["a", "b"]),
            (["a", "missing"], ["missing", "a"]),
            (["a", "a"], ["a", "a"]),
            (["a", "anchor"], ["anchor", "a"]),
        ]
        for (original, proposed) in cases {
            XCTAssertThrowsError(try MenuBarQuickBarOrderPlanner.desiredFullOrder(
                layout: layout,
                originalQuickBarIDs: original,
                proposedQuickBarIDs: proposed,
                movableItemIDs: ["a", "b"]
            ))
        }
    }

    func testUnchangedOrderIsRejected() {
        XCTAssertThrowsError(try MenuBarQuickBarOrderPlanner.desiredFullOrder(
            layout: layout(left: ["a", "b"]),
            originalQuickBarIDs: ["a", "b"],
            proposedQuickBarIDs: ["a", "b"],
            movableItemIDs: ["a", "b"]
        ))
    }

    private func layout(left: [String]) -> AnchoredMenuBarLayout {
        func item(_ id: String) -> MenuBarOrderItem {
            MenuBarOrderItem(
                id: id, bundleIdentifier: "example.\(id)", applicationName: id,
                title: id, processIdentifier: 1, displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 16, height: 22)
            )
        }
        return AnchoredMenuBarLayout(
            displayID: 1, leftItems: left.map(item),
            anchor: item("anchor"), rightItems: [item("right")]
        )
    }
}
