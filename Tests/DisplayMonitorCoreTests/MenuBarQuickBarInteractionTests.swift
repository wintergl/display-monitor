import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarInteractionPolicyTests: XCTestCase {
    func testSearchMatchesApplicationTitleAndBundleWithoutChangingOrder() {
        let items = [
            item(id: "first", app: "微信", title: "拼音", bundle: "com.tencent.input"),
            item(id: "second", app: "VPN Tool", title: "流量 42%", bundle: "example.vpn"),
            item(id: "third", app: "Notes", title: "同步", bundle: "example.notes"),
        ]

        XCTAssertEqual(
            MenuBarQuickBarSearchPolicy.filteredItems(items, query: "微信").map(\.id),
            ["first"]
        )
        XCTAssertEqual(
            MenuBarQuickBarSearchPolicy.filteredItems(items, query: "42%").map(\.id),
            ["second"]
        )
        XCTAssertEqual(
            MenuBarQuickBarSearchPolicy.filteredItems(items, query: "EXAMPLE").map(\.id),
            ["second", "third"]
        )
        XCTAssertEqual(
            MenuBarQuickBarSearchPolicy.filteredItems(items, query: "  ").map(\.id),
            ["first", "second", "third"]
        )
    }

    func testProtectedSlotsCannotMoveOrBeCrossed() {
        let ids = ["a", "protected", "b", "c"]
        let movable: Set<String> = ["a", "b", "c"]

        XCTAssertNil(MenuBarQuickBarReorderPolicy.moving(
            itemID: "protected",
            relativeTo: "b",
            placement: .after,
            in: ids,
            reorderableItemIDs: movable
        ))
        XCTAssertNil(MenuBarQuickBarReorderPolicy.moving(
            itemID: "a",
            relativeTo: "b",
            placement: .after,
            in: ids,
            reorderableItemIDs: movable
        ))
        XCTAssertEqual(
            MenuBarQuickBarReorderPolicy.moving(
                itemID: "c",
                relativeTo: "b",
                placement: .before,
                in: ids,
                reorderableItemIDs: movable
            ),
            ["a", "protected", "c", "b"]
        )
    }

    func testDragTokenIsProcessLocalAndPreservesOpaqueItemID() {
        let token = MenuBarQuickBarDragToken.make(itemID: "bundle:item/with spaces")

        XCTAssertEqual(
            MenuBarQuickBarDragToken.itemID(from: token),
            "bundle:item/with spaces"
        )
        XCTAssertNil(MenuBarQuickBarDragToken.itemID(from: "foreign:Zm9v"))
        XCTAssertNil(MenuBarQuickBarDragToken.itemID(from: "malformed"))
    }

    private func item(
        id: String,
        app: String,
        title: String,
        bundle: String
    ) -> MenuBarQuickBarItem {
        MenuBarQuickBarItem(
            id: id,
            bundleIdentifier: bundle,
            applicationName: app,
            itemTitle: title,
            processIdentifier: 1
        )
    }
}

@MainActor
final class MenuBarQuickBarModelInteractionTests: XCTestCase {
    func testSearchKeyboardSelectsAndEscapeClosesSearchBeforeBar() {
        let model = MenuBarQuickBarModel()
        let items = [item("a"), item("b"), item("c")]
        var activated: [String] = []
        var dismissCount = 0
        var presentationChangeCount = 0
        model.onDismissRequested = { dismissCount += 1 }
        model.onPresentationChanged = { presentationChangeCount += 1 }
        model.update(items: items) { activated.append($0.id) }

        model.openSearch()
        XCTAssertTrue(model.isSearchVisible)
        XCTAssertEqual(model.selectedItemID, "a")
        XCTAssertTrue(model.handleKeyDown(keyCode: 125))
        XCTAssertEqual(model.selectedItemID, "b")
        XCTAssertTrue(model.handleKeyDown(keyCode: 126))
        XCTAssertEqual(model.selectedItemID, "a")
        XCTAssertTrue(model.handleKeyDown(keyCode: 126))
        XCTAssertEqual(model.selectedItemID, "c")
        XCTAssertTrue(model.handleKeyDown(keyCode: 36))
        XCTAssertEqual(activated, ["c"])
        XCTAssertFalse(model.handleKeyDown(keyCode: 123))

        XCTAssertTrue(model.handleKeyDown(keyCode: 53))
        XCTAssertFalse(model.isSearchVisible)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertTrue(model.handleKeyDown(keyCode: 53))
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(presentationChangeCount, 2)
    }

    func testSearchFiltersAndDisablesDrag() {
        let model = MenuBarQuickBarModel()
        model.update(items: [
            item("first", app: "WeChat", title: "拼音"),
            item("second", app: "VPN", title: "42%"),
        ]) { _ in }

        XCTAssertNotNil(model.beginDragging(itemID: "first"))
        model.openSearch()
        model.setSearchQuery("42")
        XCTAssertEqual(model.visibleItems.map(\.id), ["second"])
        XCTAssertEqual(model.selectedItemID, "second")
        XCTAssertNil(model.beginDragging(itemID: "second"))
    }

    func testReorderStaysDraftUntilApplyAndExposesOriginalFullCatalog() throws {
        let model = MenuBarQuickBarModel()
        let items = [
            item("a"),
            item("fixed", isReorderable: false),
            item("b"),
            item("c"),
        ]
        var draftOrders: [[String]] = []
        var appliedOrders: [[String]] = []
        model.onReorder = { draftOrders.append($0) }
        model.onApplyReorder = { appliedOrders.append($0) }
        model.update(items: items) { _ in }

        XCTAssertNil(model.beginDragging(itemID: "fixed"))
        let invalidToken = try XCTUnwrap(model.beginDragging(itemID: "a"))
        XCTAssertFalse(model.acceptDrop(
            token: invalidToken,
            relativeTo: "b",
            placement: .after
        ))
        XCTAssertEqual(model.items.map(\.id), ["a", "fixed", "b", "c"])

        let token = try XCTUnwrap(model.beginDragging(itemID: "c"))
        XCTAssertTrue(model.acceptDrop(
            token: token,
            relativeTo: "b",
            placement: .before
        ))
        XCTAssertTrue(model.hasReorderDraft)
        XCTAssertEqual(model.originalItemIDs, ["a", "fixed", "b", "c"])
        XCTAssertEqual(model.items.map(\.id), ["a", "fixed", "c", "b"])
        XCTAssertEqual(draftOrders, [["a", "fixed", "c", "b"]])
        XCTAssertTrue(appliedOrders.isEmpty)

        model.applyReorderDraft()
        XCTAssertFalse(model.hasReorderDraft)
        XCTAssertEqual(appliedOrders, [["a", "fixed", "c", "b"]])
        XCTAssertEqual(model.originalItemIDs, ["a", "fixed", "b", "c"])
    }

    func testCancelRestoresBaselineAndCatalogChangeInvalidatesDraft() throws {
        let model = MenuBarQuickBarModel()
        var cancelCount = 0
        model.onCancelReorder = { cancelCount += 1 }
        model.update(items: [item("a"), item("b"), item("c")]) { _ in }

        var token = try XCTUnwrap(model.beginDragging(itemID: "c"))
        XCTAssertTrue(model.acceptDrop(token: token, relativeTo: "a", placement: .before))
        model.cancelReorderDraft()
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(model.hasReorderDraft)
        XCTAssertEqual(cancelCount, 1)

        token = try XCTUnwrap(model.beginDragging(itemID: "c"))
        XCTAssertTrue(model.acceptDrop(token: token, relativeTo: "a", placement: .before))
        model.update(items: [item("a"), item("b"), item("new")]) { _ in }
        XCTAssertFalse(model.hasReorderDraft)
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "new"])
        XCTAssertEqual(model.originalItemIDs, ["a", "b", "new"])
    }

    func testResetInvalidatesDragTokenBeforeAsyncDropCanArrive() throws {
        let model = MenuBarQuickBarModel()
        model.update(items: [item("a"), item("b")]) { _ in }
        let token = try XCTUnwrap(model.beginDragging(itemID: "b"))

        model.resetPresentation()

        XCTAssertFalse(model.acceptDrop(
            token: token,
            relativeTo: "a",
            placement: .before
        ))
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertFalse(model.hasReorderDraft)
    }

    func testResetCancelsDraftAndReopenStartsFromCatalogOrder() throws {
        let model = MenuBarQuickBarModel()
        let catalog = [item("a"), item("b"), item("c")]
        var cancelCount = 0
        model.onCancelReorder = { cancelCount += 1 }
        model.update(items: catalog) { _ in }
        let token = try XCTUnwrap(model.beginDragging(itemID: "c"))
        XCTAssertTrue(model.acceptDrop(
            token: token,
            relativeTo: "a",
            placement: .before
        ))
        model.openSearch()
        model.setSearchQuery("App")

        model.resetPresentation()

        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(model.hasReorderDraft)
        XCTAssertFalse(model.isSearchVisible)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertNil(model.selectedItemID)
        XCTAssertEqual(cancelCount, 1)

        // A subsequent panel show updates the same catalog and must not revive
        // the draft from the previous presentation.
        model.update(items: catalog) { _ in }
        XCTAssertEqual(model.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(model.hasReorderDraft)
        model.openSearch()
        XCTAssertEqual(model.visibleItems.map(\.id), ["a", "b", "c"])
    }

    func testCatalogMarksOnlyCoordinatorApprovedItemsMovable() {
        let source = [
            orderItem("a", x: 10),
            orderItem("protected", x: 20),
        ]
        let result = MenuBarQuickBarCatalog.makeItems(
            from: source,
            hiddenBundleIdentifiers: ["example"],
            movableItemIDs: ["a"]
        )

        XCTAssertEqual(result.map(\.isReorderable), [true, false])
        XCTAssertTrue(MenuBarQuickBarCatalog.makeItems(
            from: source,
            hiddenBundleIdentifiers: ["example"]
        ).allSatisfy(\.isReorderable))
    }

    private func item(
        _ id: String,
        app: String = "App",
        title: String = "Item",
        isReorderable: Bool = true
    ) -> MenuBarQuickBarItem {
        MenuBarQuickBarItem(
            id: id,
            bundleIdentifier: "example.\(id)",
            applicationName: app,
            itemTitle: title,
            processIdentifier: 1,
            isReorderable: isReorderable
        )
    }

    private func orderItem(_ id: String, x: CGFloat) -> MenuBarOrderItem {
        MenuBarOrderItem(
            id: id,
            bundleIdentifier: "example",
            applicationName: "App",
            title: id,
            processIdentifier: Int32(x),
            displayID: 1,
            frame: CGRect(x: x, y: 0, width: 16, height: 16)
        )
    }
}
