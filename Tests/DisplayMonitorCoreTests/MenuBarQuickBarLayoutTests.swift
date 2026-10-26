import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarLayoutTests: XCTestCase {
    func testSnapshotKeepsOriginalPointSizeWithoutUpscaling() {
        let compact = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: CGSize(width: 16, height: 16)
        )
        let standard = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: CGSize(width: 31, height: 22)
        )

        XCTAssertEqual(compact.iconSize, CGSize(width: 16, height: 16))
        XCTAssertEqual(standard.iconSize, CGSize(width: 31, height: 22))
        XCTAssertEqual(compact.itemWidth, MenuBarQuickBarLayoutPolicy.minimumItemWidth)
        XCTAssertEqual(compact.itemWidth, 24)
        XCTAssertEqual(standard.itemWidth, 39)
        XCTAssertEqual(MenuBarQuickBarLayoutPolicy.panelHeight, 40)
        XCTAssertEqual(MenuBarQuickBarLayoutPolicy.itemHeight, 32)
    }

    func testOversizedSnapshotScalesDownProportionally() {
        let metrics = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: CGSize(width: 240, height: 40)
        )

        XCTAssertEqual(metrics.iconSize, CGSize(width: 168, height: 28))
        XCTAssertEqual(metrics.iconSize.width / metrics.iconSize.height, 6, accuracy: 0.001)
        XCTAssertEqual(metrics.itemWidth, 176)
    }

    func testWideStatusItemGetsAnAdaptiveCell() {
        let metrics = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: CGSize(width: 120, height: 22)
        )

        XCTAssertEqual(metrics.iconSize, CGSize(width: 120, height: 22))
        XCTAssertEqual(metrics.itemWidth, 128)
        XCTAssertGreaterThan(metrics.itemWidth, MenuBarQuickBarLayoutPolicy.minimumItemWidth)
    }

    func testPanelUsesAtMostEightAdaptiveItemsAndStaysWithinScreen() {
        let sizes = Array<CGSize?>(
            repeating: CGSize(width: 120, height: 22),
            count: 10
        )
        let naturalWidth = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 2_000
        )
        let cappedWidth = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 700
        )

        let expectedNatural = CGFloat(
            8 * 128 + 7 * 2 + 2 * 6
                + Int(MenuBarQuickBarLayoutPolicy.searchButtonWidth)
                + Int(MenuBarQuickBarLayoutPolicy.itemSpacing)
        )
        XCTAssertEqual(naturalWidth, expectedNatural)
        XCTAssertEqual(cappedWidth, 700)
    }

    func testSearchAndDraftControlsGrowPanelButRemainScreenBounded() {
        let sizes = [CGSize(width: 22, height: 22)]
        let regular = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 1_000
        )
        let search = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 1_000,
            isSearchVisible: true
        )
        let draft = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 1_000,
            hasReorderDraft: true
        )
        let capped = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: sizes,
            maximumWidth: 180,
            isSearchVisible: true,
            hasReorderDraft: true
        )

        XCTAssertEqual(
            search - regular,
            MenuBarQuickBarLayoutPolicy.searchControlsWidth
                - MenuBarQuickBarLayoutPolicy.searchButtonWidth
        )
        XCTAssertEqual(
            draft - regular,
            MenuBarQuickBarLayoutPolicy.reorderDraftControlsWidth
                + MenuBarQuickBarLayoutPolicy.itemSpacing
        )
        XCTAssertEqual(capped, 180)
    }

    func testItemsAfterTheEighthDoNotChangePreferredPanelWidth() {
        let firstEight = Array<CGSize?>(
            repeating: CGSize(width: 31, height: 22),
            count: 8
        )
        let withOversizedNinth = firstEight + [CGSize(width: 1_000, height: 22)]

        XCTAssertEqual(
            MenuBarQuickBarLayoutPolicy.panelWidth(
                snapshotPointSizes: firstEight,
                maximumWidth: 2_000
            ),
            MenuBarQuickBarLayoutPolicy.panelWidth(
                snapshotPointSizes: withOversizedNinth,
                maximumWidth: 2_000
            )
        )
    }

    func testFallbackAndEmptyPanelRemainBounded() {
        let fallback = MenuBarQuickBarLayoutPolicy.itemMetrics(snapshotPointSize: nil)
        XCTAssertEqual(fallback.iconSize, CGSize(width: 22, height: 22))
        XCTAssertEqual(fallback.itemWidth, 30)
        XCTAssertEqual(
            MenuBarQuickBarLayoutPolicy.panelWidth(
                snapshotPointSizes: [],
                maximumWidth: 180
            ),
            180
        )
    }
}
