import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarAutomaticRecollapseActivityTests: XCTestCase {
    private let appKitDisplay = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    private let cgDisplay = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testPointerUsesConservativeFortyPointTopBandAndMouseButtons() {
        let inside = classify(pointer: CGPoint(x: 700, y: 875), pressedMouseButtons: 1)
        let outside = classify(pointer: CGPoint(x: 700, y: 859), pressedMouseButtons: 0)

        XCTAssertTrue(inside.isReadable)
        XCTAssertTrue(inside.pointerInsideMenuBar)
        XCTAssertTrue(inside.hasPressedMouseButtons)
        XCTAssertFalse(outside.pointerInsideMenuBar)
        XCTAssertFalse(outside.hasPressedMouseButtons)
    }

    func testPointerBandSupportsNegativeOriginDisplay() {
        let upperDisplay = CGRect(x: -1_920, y: 900, width: 1_920, height: 1_080)
        let snapshot = MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: CGPoint(x: -500, y: 1_970),
            pressedMouseButtons: 0,
            appKitDisplayFrames: [appKitDisplay, upperDisplay],
            cgDisplayBounds: [cgDisplay],
            windows: [normalWindow()]
        )

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertTrue(snapshot.pointerInsideMenuBar)
    }

    func testPopupMenuLayerBlocksRegardlessOfVerticalPosition() {
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let snapshot = classify(
            windows: [window(layer: popupLayer, bounds: CGRect(x: 500, y: 300, width: 240, height: 320))]
        )

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.blockingWindowCount, 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.popupMenuLayer], 1)
    }

    func testTopAdjacentNonNormalWindowThatExtendsBelowBarBlocks() {
        let snapshot = classify(
            windows: [window(layer: 3, bounds: CGRect(x: 900, y: 24, width: 280, height: 260))]
        )

        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topOtherElevatedLayer], 1)
    }

    func testNormalWindowsAndMenuBarBandItselfDoNotLookLikePopovers() {
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let snapshot = classify(windows: [
            window(layer: normalLayer, bounds: CGRect(x: 900, y: 20, width: 280, height: 260)),
            window(layer: 24, bounds: CGRect(x: 0, y: 0, width: 1_440, height: 24)),
            window(layer: 3, bounds: CGRect(x: 900, y: 180, width: 280, height: 260)),
        ])

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertFalse(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.normalOrBelowExcluded], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.menuBarBackgroundExcluded], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.nonTopElevatedExcluded], 1)
    }

    func testSixtyPointWideMenuBarBackgroundDoesNotBlock() {
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let snapshot = classify(windows: [
            window(
                layer: mainMenuLayer,
                bounds: CGRect(x: 0, y: 0, width: 1_440, height: 60)
            ),
        ])

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertFalse(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.menuBarBackgroundExcluded], 1)
    }

    func testNegativeLayerBackgroundDoesNotBlock() {
        let snapshot = classify(windows: [
            window(layer: -1, bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)),
        ])

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertFalse(snapshot.hasOpenMenuOrPopover)
    }

    func testLargeTopWindowOnMenuLayerStillBlocksAsPopover() {
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let snapshot = classify(windows: [
            window(
                layer: statusLayer,
                bounds: CGRect(x: 300, y: 0, width: 900, height: 300)
            ),
        ])

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topStatusWindowLayer], 1)
    }

    func testExactNotificationCenterPIDExcludesOnlyTopOtherElevatedWindow() {
        let snapshot = classify(
            windows: [
                window(
                    ownerPID: 42,
                    layer: 21,
                    bounds: cgDisplay
                ),
            ],
            notificationCenterProcessIdentifiers: [42]
        )

        XCTAssertTrue(snapshot.isReadable)
        XCTAssertFalse(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.notificationCenterExcluded], 1)
        XCTAssertEqual(snapshot.diagnostics.blockingWindowCount, 0)
        XCTAssertEqual(snapshot.diagnostics.blockingSummary, "blockers=0,classes=none")
    }

    func testOpenNotificationCenterPanelBlocksEvenWithExcludedBackdrop() {
        let snapshot = MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: CGPoint(x: 700, y: 500), pressedMouseButtons: 0,
            appKitDisplayFrames: [appKitDisplay], cgDisplayBounds: [cgDisplay],
            windows: [window(ownerPID: 42, layer: 21, bounds: cgDisplay)],
            notificationCenterProcessIdentifiers: [42], notificationCenterHasOpenPanel: true
        )
        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.notificationCenterExcluded], 1)
        XCTAssertEqual(snapshot.diagnostics.blockingClassifications[.notificationCenterPanel], 1)
    }

    func testNotificationCenterPIDDoesNotExemptOtherOwnersOrUnknownPIDSet() {
        let otherOwner = classify(
            windows: [window(ownerPID: 43, layer: 21, bounds: cgDisplay)],
            notificationCenterProcessIdentifiers: [42]
        )
        let unresolvedNotificationCenter = classify(
            windows: [window(ownerPID: 42, layer: 21, bounds: cgDisplay)],
            notificationCenterProcessIdentifiers: []
        )

        XCTAssertTrue(otherOwner.hasOpenMenuOrPopover)
        XCTAssertEqual(otherOwner.diagnostics.classifications[.topOtherElevatedLayer], 1)
        XCTAssertTrue(unresolvedNotificationCenter.hasOpenMenuOrPopover)
        XCTAssertEqual(
            unresolvedNotificationCenter.diagnostics.classifications[.topOtherElevatedLayer],
            1
        )
    }

    func testNotificationCenterPopupAndMenuLayersRemainBlocking() {
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let snapshot = classify(
            windows: [
                window(ownerPID: 42, layer: 21, bounds: cgDisplay),
                window(
                    ownerPID: 42,
                    layer: popupLayer,
                    bounds: CGRect(x: 500, y: 300, width: 240, height: 320)
                ),
                window(
                    ownerPID: 42,
                    layer: mainMenuLayer,
                    bounds: CGRect(x: 500, y: 10, width: 240, height: 320)
                ),
                window(
                    ownerPID: 42,
                    layer: statusLayer,
                    bounds: CGRect(x: 800, y: 10, width: 240, height: 320)
                ),
            ],
            notificationCenterProcessIdentifiers: [42]
        )

        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.classifications[.notificationCenterExcluded], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.popupMenuLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topMainMenuLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topStatusWindowLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.blockingWindowCount, 3)
    }

    func testUnknownNotificationCenterWindowMetadataStillFailsClosed() {
        let snapshot = classify(
            windows: [MenuBarAutomaticRecollapseWindowMetadata(
                ownerPID: nil,
                layer: 21,
                bounds: cgDisplay
            )],
            notificationCenterProcessIdentifiers: [42]
        )

        XCTAssertFalse(snapshot.isReadable)
        XCTAssertEqual(snapshot.diagnostics.classifications[.incompleteMetadata], 1)
        XCTAssertNil(snapshot.diagnostics.classifications[.notificationCenterExcluded])
    }

    func testDeferralSignatureIgnoresNonblockingWindowCountChanges() {
        let first = classify(windows: [
            window(ownerPID: 43, layer: 3, bounds: CGRect(x: 900, y: 24, width: 280, height: 260)),
            normalWindow(),
        ])
        let second = classify(windows: [
            window(ownerPID: 43, layer: 3, bounds: CGRect(x: 900, y: 24, width: 280, height: 260)),
            normalWindow(),
            window(
                ownerPID: 44,
                layer: Int(CGWindowLevelForKey(.normalWindow)),
                bounds: CGRect(x: 20, y: 200, width: 300, height: 300)
            ),
        ])

        XCTAssertNotEqual(first.diagnostics.windowCount, second.diagnostics.windowCount)
        XCTAssertNotEqual(first.diagnostics.summary, second.diagnostics.summary)
        XCTAssertEqual(first.diagnostics.blockingSummary, second.diagnostics.blockingSummary)
        XCTAssertEqual(first.deferralSignature, second.deferralSignature)
    }

    func testMissingOrEmptyCGStateIsUnreadable() {
        let missingWindows = MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: .zero,
            pressedMouseButtons: 0,
            appKitDisplayFrames: [appKitDisplay],
            cgDisplayBounds: [cgDisplay],
            windows: nil
        )
        let emptyWindows = classify(windows: [])
        let missingDisplays = MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: .zero,
            pressedMouseButtons: 0,
            appKitDisplayFrames: [appKitDisplay],
            cgDisplayBounds: nil,
            windows: [normalWindow()]
        )
        let emptyDisplays = classify(cgDisplayBounds: [])
        let noAppKitDisplays = MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: .zero,
            pressedMouseButtons: 0,
            appKitDisplayFrames: [],
            cgDisplayBounds: [cgDisplay],
            windows: [normalWindow()]
        )

        XCTAssertFalse(missingWindows.isReadable)
        XCTAssertFalse(emptyWindows.isReadable)
        XCTAssertFalse(missingDisplays.isReadable)
        XCTAssertFalse(emptyDisplays.isReadable)
        XCTAssertFalse(noAppKitDisplays.isReadable)
    }

    func testUnknownWindowMetadataFailsClosed() {
        let unknownWindows = [
            MenuBarAutomaticRecollapseWindowMetadata(
                ownerPID: nil,
                layer: 3,
                bounds: CGRect(x: 900, y: 24, width: 280, height: 260)
            ),
            MenuBarAutomaticRecollapseWindowMetadata(
                ownerPID: 42,
                layer: nil,
                bounds: CGRect(x: 900, y: 24, width: 280, height: 260)
            ),
            MenuBarAutomaticRecollapseWindowMetadata(ownerPID: 42, layer: 3, bounds: nil),
        ]

        for unknownWindow in unknownWindows {
            let snapshot = classify(windows: [unknownWindow])
            XCTAssertFalse(snapshot.isReadable)
            XCTAssertEqual(snapshot.diagnostics.windowCount, 1)
            XCTAssertEqual(snapshot.diagnostics.completeWindowCount, 0)
            XCTAssertEqual(snapshot.diagnostics.classifications[.incompleteMetadata], 1)
        }
    }

    func testBlockingClassificationsAggregateWithoutWindowIdentityOrGeometry() {
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let snapshot = classify(windows: [
            window(layer: popupLayer, bounds: CGRect(x: 500, y: 300, width: 240, height: 320)),
            window(layer: mainMenuLayer, bounds: CGRect(x: 500, y: 10, width: 240, height: 320)),
            window(layer: statusLayer, bounds: CGRect(x: 800, y: 10, width: 240, height: 320)),
            window(layer: 3, bounds: CGRect(x: 1_050, y: 10, width: 200, height: 240)),
            normalWindow(),
        ])

        XCTAssertTrue(snapshot.hasOpenMenuOrPopover)
        XCTAssertEqual(snapshot.diagnostics.windowCount, 5)
        XCTAssertEqual(snapshot.diagnostics.completeWindowCount, 5)
        XCTAssertEqual(snapshot.diagnostics.blockingWindowCount, 4)
        XCTAssertEqual(snapshot.diagnostics.classifications[.popupMenuLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topMainMenuLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topStatusWindowLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.topOtherElevatedLayer], 1)
        XCTAssertEqual(snapshot.diagnostics.classifications[.normalOrBelowExcluded], 1)
        XCTAssertEqual(
            snapshot.diagnostics.summary,
            "windows=5,complete=5,blockers=4,classes=normalOrBelowExcluded=1,popupMenuLayer=1,topMainMenuLayer=1,topOtherElevatedLayer=1,topStatusWindowLayer=1"
        )
        XCTAssertFalse(snapshot.diagnostics.summary.contains("42"))
        XCTAssertFalse(snapshot.diagnostics.summary.contains("500"))
    }

    func testSnapshotDiagnosticsDefaultKeepsExistingFixturesCompatible() {
        let snapshot = MenuBarAutomaticRecollapseActivitySnapshot(
            isReadable: true,
            pointerInsideMenuBar: false,
            hasPressedMouseButtons: false,
            hasOpenMenuOrPopover: false
        )

        XCTAssertEqual(snapshot.diagnostics, MenuBarAutomaticRecollapseActivityDiagnostics())
        XCTAssertEqual(
            snapshot.diagnostics.summary,
            "windows=0,complete=0,blockers=0,classes=none"
        )
    }

    func testInvalidPointerOrMouseStateIsUnreadable() {
        let invalidPointer = classify(pointer: CGPoint(x: CGFloat.nan, y: 875))
        let invalidMouse = classify(pressedMouseButtons: -1)

        XCTAssertFalse(invalidPointer.isReadable)
        XCTAssertFalse(invalidMouse.isReadable)
    }

    private func classify(
        pointer: CGPoint = CGPoint(x: 700, y: 500),
        pressedMouseButtons: Int = 0,
        cgDisplayBounds: [CGRect]? = nil,
        windows: [MenuBarAutomaticRecollapseWindowMetadata]? = nil,
        notificationCenterProcessIdentifiers: Set<Int32> = []
    ) -> MenuBarAutomaticRecollapseActivitySnapshot {
        MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: pointer,
            pressedMouseButtons: pressedMouseButtons,
            appKitDisplayFrames: [appKitDisplay],
            cgDisplayBounds: cgDisplayBounds ?? [cgDisplay],
            windows: windows ?? [normalWindow()],
            notificationCenterProcessIdentifiers: notificationCenterProcessIdentifiers
        )
    }

    private func normalWindow() -> MenuBarAutomaticRecollapseWindowMetadata {
        window(
            layer: Int(CGWindowLevelForKey(.normalWindow)),
            bounds: CGRect(x: 100, y: 200, width: 800, height: 600)
        )
    }

    private func window(
        ownerPID: Int32 = 42,
        layer: Int,
        bounds: CGRect
    ) -> MenuBarAutomaticRecollapseWindowMetadata {
        MenuBarAutomaticRecollapseWindowMetadata(
            ownerPID: ownerPID,
            layer: layer,
            bounds: bounds
        )
    }
}
