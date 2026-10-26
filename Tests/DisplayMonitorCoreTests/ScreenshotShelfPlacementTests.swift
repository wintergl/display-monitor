import CoreGraphics
@testable import DisplayMonitorCore
import XCTest

final class ScreenshotShelfPlacementTests: XCTestCase {
    func testCompactShelfKeepsComfortableInsetAtBottomRight() {
        let frame = ScreenshotShelfPlacement.frame(
            in: CGRect(x: 0, y: 40, width: 1440, height: 860),
            preferredSize: CGSize(width: 340, height: 292),
            margin: 20
        )

        XCTAssertEqual(frame, CGRect(x: 1080, y: 60, width: 340, height: 292))
    }

    func testPlacesShelfAtBottomRightOfVisibleFrame() {
        let frame = ScreenshotShelfPlacement.frame(
            in: CGRect(x: 0, y: 40, width: 1440, height: 860),
            preferredSize: CGSize(width: 320, height: 250)
        )

        XCTAssertEqual(frame, CGRect(x: 1104, y: 56, width: 320, height: 250))
    }

    func testPreservesNegativeOriginDisplayCoordinates() {
        let frame = ScreenshotShelfPlacement.frame(
            in: CGRect(x: -1920, y: 23, width: 1920, height: 1057),
            preferredSize: CGSize(width: 320, height: 250),
            margin: 20
        )

        XCTAssertEqual(frame, CGRect(x: -340, y: 43, width: 320, height: 250))
    }

    func testClampsShelfToSmallVisibleFrame() {
        let frame = ScreenshotShelfPlacement.frame(
            in: CGRect(x: 100, y: 200, width: 240, height: 180),
            preferredSize: CGSize(width: 320, height: 250),
            margin: 16
        )

        XCTAssertEqual(frame, CGRect(x: 116, y: 216, width: 208, height: 148))
    }

    func testPinnedScreenshotStartsAtTheSelectedNegativeOriginRegion() {
        let frame = PinnedScreenshotPlacement.initialFrame(
            selectionFrame: CGRect(x: -1_600, y: 300, width: 400, height: 200),
            imagePixelSize: PixelSize(width: 800, height: 400),
            pixelScale: 2,
            visibleFrame: CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        )

        XCTAssertEqual(frame, CGRect(x: -1_600, y: 300, width: 400, height: 200))
    }

    func testPinnedScreenshotScalesDownButDoesNotUpscaleForVisibleFrame() {
        let frame = PinnedScreenshotPlacement.initialFrame(
            selectionFrame: CGRect(x: 0, y: 0, width: 1_600, height: 900),
            imagePixelSize: PixelSize(width: 1_600, height: 900),
            pixelScale: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
            margin: 10
        )

        XCTAssertEqual(frame.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(frame.width, 280, accuracy: 0.001)
        XCTAssertEqual(frame.height, 157.5, accuracy: 0.001)
    }

    func testPinnedScreenshotDragKeepsRecoverableHandleOnScreen() {
        let frame = PinnedScreenshotPlacement.clampedDraggedFrame(
            CGRect(x: 500, y: -100, width: 100, height: 80),
            in: CGRect(x: 0, y: 0, width: 300, height: 200)
        )

        XCTAssertEqual(frame, CGRect(x: 276, y: -56, width: 100, height: 80))
        let visiblePart = frame.intersection(CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(visiblePart.size, PinnedScreenshotPlacement.minimumVisibleSize)
    }

    func testQuickAccessCardsStackUpwardBeforeMovingLeft() {
        let frames = ScreenshotQuickAccessPlacement.frames(
            in: CGRect(x: 0, y: 40, width: 1440, height: 860),
            preferredSize: CGSize(width: 240, height: 210),
            count: 4,
            margin: 20,
            spacing: 12
        )

        XCTAssertEqual(frames, [
            CGRect(x: 1180, y: 60, width: 240, height: 210),
            CGRect(x: 1180, y: 282, width: 240, height: 210),
            CGRect(x: 1180, y: 504, width: 240, height: 210),
            CGRect(x: 928, y: 60, width: 240, height: 210)
        ])
    }

    func testQuickAccessCardsKeepNegativeOriginAnchor() {
        let frames = ScreenshotQuickAccessPlacement.frames(
            in: CGRect(x: -1920, y: 23, width: 1920, height: 1057),
            preferredSize: CGSize(width: 240, height: 210),
            count: 2,
            margin: 20,
            spacing: 12
        )

        XCTAssertEqual(frames[0], CGRect(x: -260, y: 43, width: 240, height: 210))
        XCTAssertEqual(frames[1], CGRect(x: -260, y: 265, width: 240, height: 210))
    }

    func testFollowPolicyDoesNotReanchorWithinUnchangedDisplay() {
        let anchor = ScreenshotShelfAnchor(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1016)
        )

        XCTAssertFalse(
            ScreenshotShelfFollowPolicy.needsReanchor(
                previous: anchor,
                current: anchor
            )
        )
    }

    func testFollowPolicyReanchorsWhenPointerEntersAnotherDisplay() {
        let previous = ScreenshotShelfAnchor(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1016)
        )
        let current = ScreenshotShelfAnchor(
            displayID: 2,
            frame: CGRect(x: 1920, y: 90, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 90, width: 1920, height: 1049)
        )

        XCTAssertTrue(
            ScreenshotShelfFollowPolicy.needsReanchor(
                previous: previous,
                current: current
            )
        )
        XCTAssertEqual(
            ScreenshotShelfPlacement.frame(
                in: current.visibleFrame,
                preferredSize: CGSize(width: 340, height: 292),
                margin: 20
            ),
            CGRect(x: 3480, y: 110, width: 340, height: 292)
        )
    }

    func testFollowPolicyReanchorsWhenUsableFrameChangesOnSameDisplay() {
        let previous = ScreenshotShelfAnchor(
            displayID: 2,
            frame: CGRect(x: 1920, y: 90, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 90, width: 1920, height: 1049)
        )
        let current = ScreenshotShelfAnchor(
            displayID: 2,
            frame: CGRect(x: 1920, y: 90, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 90, width: 1920, height: 1016)
        )

        XCTAssertTrue(
            ScreenshotShelfFollowPolicy.needsReanchor(
                previous: previous,
                current: current
            )
        )
    }
}
