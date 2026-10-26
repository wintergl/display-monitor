import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickAccessTests: XCTestCase {
    func testRouterUsesNativeRevealForPrimaryClick() {
        XCTAssertEqual(
            MenuBarStatusItemActionRouter.action(
                for: .primary,
                presentationMode: .nativeMenuBar,
                quickBarIsVisible: false
            ),
            .revealNativeMenuBar
        )
    }

    func testRouterTogglesQuickBarAndKeepsSecondaryClickForContextMenu() {
        XCTAssertEqual(
            MenuBarStatusItemActionRouter.action(
                for: .primary,
                presentationMode: .quickBar,
                quickBarIsVisible: false
            ),
            .presentQuickBar
        )
        XCTAssertEqual(
            MenuBarStatusItemActionRouter.action(
                for: .primary,
                presentationMode: .quickBar,
                quickBarIsVisible: true
            ),
            .dismissQuickBar
        )
        XCTAssertEqual(
            MenuBarStatusItemActionRouter.action(
                for: .secondary,
                presentationMode: .quickBar,
                quickBarIsVisible: true
            ),
            .presentContextMenu
        )
    }

    func testCatalogKeepsMenuBarOrderAndOnlyIncludesHiddenBundles() {
        let items = [
            makeItem(id: "first", bundle: "example.one", name: "One", x: 10),
            makeItem(id: "second", bundle: "example.two", name: "Two", x: 20),
            makeItem(id: "third", bundle: "example.one", name: "One", x: 30),
        ]

        let result = MenuBarQuickBarCatalog.makeItems(
            from: items,
            hiddenBundleIdentifiers: ["example.one"]
        )

        XCTAssertEqual(result.map(\.id), ["first", "third"])
        XCTAssertEqual(result.map(\.displayName), ["One", "One"])
    }

    func testCatalogAttachesMemorySnapshotByExactItemIdentity() {
        let first = makeItem(id: "first", bundle: "example.one", name: "One", x: 10)
        let second = makeItem(id: "second", bundle: "example.one", name: "One", x: 20)
        let snapshot = MenuBarQuickBarIconSnapshot(
            pngData: Data([1, 2, 3]),
            pointSize: CGSize(width: 31, height: 22)
        )

        let result = MenuBarQuickBarCatalog.makeItems(
            from: [first, second],
            hiddenBundleIdentifiers: ["example.one"],
            iconSnapshots: [first.id: snapshot]
        )

        XCTAssertEqual(result[0].iconSnapshot, snapshot)
        XCTAssertNil(result[1].iconSnapshot)
    }

    func testCaptureGeometryUsesOneStripAndPreservesItemAspectRatios() throws {
        let display = CGRect(x: 100, y: 0, width: 1_000, height: 700)
        let items = [
            makeItem(id: "narrow", bundle: "example.one", name: "One", x: 900),
            MenuBarOrderItem(
                id: "wide",
                bundleIdentifier: "example.two",
                applicationName: "Two",
                title: "Two",
                processIdentifier: 22,
                displayID: 1,
                frame: CGRect(x: 940, y: 0, width: 44, height: 22)
            ),
        ]

        let geometry = try XCTUnwrap(MenuBarQuickBarCaptureGeometry.make(
            displayID: 1,
            displayBounds: display,
            items: items
        ))

        XCTAssertEqual(geometry.globalStripRect, CGRect(x: 900, y: 0, width: 84, height: 22))
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 800, y: 0, width: 84, height: 22))
        let narrow = try XCTUnwrap(geometry.pixelCropRect(
            for: "narrow",
            imageSize: CGSize(width: 168, height: 44)
        ))
        let wide = try XCTUnwrap(geometry.pixelCropRect(
            for: "wide",
            imageSize: CGSize(width: 168, height: 44)
        ))
        XCTAssertEqual(narrow, CGRect(x: 0, y: 0, width: 32, height: 32))
        XCTAssertEqual(wide, CGRect(x: 80, y: 0, width: 88, height: 44))
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.001)
    }

    func testQuickBarItemUsesTitleAndBundleAsNameFallbacks() {
        let titled = MenuBarQuickBarItem(
            id: "titled",
            bundleIdentifier: "example.titled",
            applicationName: " ",
            itemTitle: "Upload",
            processIdentifier: 1
        )
        let unnamed = MenuBarQuickBarItem(
            id: "unnamed",
            bundleIdentifier: "example.unnamed",
            applicationName: "",
            itemTitle: "",
            processIdentifier: 2
        )

        XCTAssertEqual(titled.displayName, "Upload")
        XCTAssertEqual(unnamed.displayName, "example.unnamed")
    }

    func testChangeProxyFailsClosedWithoutAnExplicitReason() {
        let proxy = MenuBarQuickBarItem(
            id: "change",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            itemTitle: "Changed",
            processIdentifier: 42,
            isChangeProxy: true
        )
        let ordinary = MenuBarQuickBarItem(
            id: "ordinary",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            itemTitle: "Target",
            processIdentifier: 42
        )

        XCTAssertNotNil(proxy.selectionBlockReason)
        XCTAssertNil(ordinary.selectionBlockReason)
    }

    func testSystemHostedInputMethodUsesVisibleInputSourceTitle() {
        let item = MenuBarQuickBarItem(
            id: "input",
            bundleIdentifier: MenuBarTargetProtectionPolicy.textInputMenuAgentBundleIdentifier,
            applicationName: "TextInputMenuAgent",
            itemTitle: "微信输入法",
            processIdentifier: 42
        )

        XCTAssertEqual(item.displayName, "微信输入法")
        XCTAssertEqual(item.accessibilityLabel, "微信输入法")
    }

    func testTargetResolverRequiresExactIdentityAndUsesFreshFrame() {
        let proxy = MenuBarQuickBarItem(
            id: "stable-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            itemTitle: "Upload",
            processIdentifier: 42
        )
        let fresh = MenuBarOrderItem(
            id: "stable-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            title: "Upload",
            processIdentifier: 42,
            displayID: 1,
            frame: CGRect(x: 300, y: 0, width: 22, height: 22)
        )
        let staleLookalike = MenuBarOrderItem(
            id: "stable-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            title: "Upload",
            processIdentifier: 41,
            displayID: 1,
            frame: CGRect(x: 20, y: 0, width: 22, height: 22)
        )

        XCTAssertEqual(
            MenuBarQuickBarTargetResolver.resolve(proxy, in: [staleLookalike, fresh]),
            .target(fresh)
        )
    }

    func testTargetResolverRejectsChangedIdentity() {
        let proxy = MenuBarQuickBarItem(
            id: "old-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            itemTitle: "Upload",
            processIdentifier: 42
        )
        let restarted = MenuBarOrderItem(
            id: "new-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            title: "Upload",
            processIdentifier: 99,
            displayID: 1,
            frame: CGRect(x: 300, y: 0, width: 22, height: 22)
        )

        XCTAssertEqual(
            MenuBarQuickBarTargetResolver.resolve(proxy, in: [restarted]),
            .notFound
        )
    }

    func testTargetResolverRejectsAmbiguousExactMatches() {
        let item = makeItem(id: "same", bundle: "example.target", name: "Target", x: 42)
        let proxy = MenuBarQuickBarItem(
            id: item.id,
            bundleIdentifier: item.bundleIdentifier,
            applicationName: item.applicationName,
            itemTitle: item.title,
            processIdentifier: item.processIdentifier
        )

        XCTAssertEqual(
            MenuBarQuickBarTargetResolver.resolve(proxy, in: [item, item]),
            .ambiguous
        )
    }

    func testActivationResultReportsSuccessOnlyForActivatedCase() {
        XCTAssertTrue(MenuBarQuickBarActivationResult.activated(targetID: "item").succeeded)
        XCTAssertFalse(MenuBarQuickBarActivationResult.notFound(message: "missing").succeeded)
        XCTAssertFalse(MenuBarQuickBarActivationResult.failed(message: "failed").succeeded)
        XCTAssertFalse(MenuBarQuickBarActivationResult.cancelled.succeeded)
    }

    private func makeItem(
        id: String,
        bundle: String,
        name: String,
        x: CGFloat
    ) -> MenuBarOrderItem {
        MenuBarOrderItem(
            id: id,
            bundleIdentifier: bundle,
            applicationName: name,
            title: name,
            processIdentifier: Int32(x),
            displayID: 1,
            frame: CGRect(x: x, y: 0, width: 16, height: 16)
        )
    }
}
