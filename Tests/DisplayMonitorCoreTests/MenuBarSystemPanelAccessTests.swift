import AppKit
import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarSystemPanelAccessTests: XCTestCase {
    func testOnlyLeftMouseDownReleasesHiding() {
        XCTAssertEqual(MenuBarSystemPanelAccessPolicy.eventMask, [.leftMouseDown])
        XCTAssertTrue(MenuBarSystemPanelAccessPolicy.shouldRelease(for: .leftMouseDown))
        for type: NSEvent.EventType in [.mouseMoved, .mouseEntered, .mouseExited,
                                        .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel] {
            XCTAssertFalse(MenuBarSystemPanelAccessPolicy.shouldRelease(for: type))
        }
    }

    func testClockClickUsesExactFrameAndLeavesOtherItemsAlone() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let clock = CGRect(x: 1300, y: 0, width: 140, height: 24)
        XCTAssertTrue(MenuBarSystemPanelAccessPolicy.contains(
            pointer: CGPoint(x: 1301, y: 10), displays: [display], clockFrames: [clock]))
        for point in [CGPoint(x: 1290, y: 10), CGPoint(x: 1200, y: 10), CGPoint(x: 1400, y: 100)] {
            XCTAssertFalse(MenuBarSystemPanelAccessPolicy.contains(
                pointer: point, displays: [display], clockFrames: [clock]))
        }
    }

    func testFallbackAndClockFramesWorkOnOffsetSecondaryDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                        CGRect(x: -1920, y: -1080, width: 1920, height: 1080)]
        let clock = CGRect(x: 1300, y: 0, width: 140, height: 24)
        XCTAssertTrue(MenuBarSystemPanelAccessPolicy.contains(
            pointer: CGPoint(x: -30, y: -1070), displays: displays, clockFrames: [clock]))
        XCTAssertFalse(MenuBarSystemPanelAccessPolicy.contains(
            pointer: CGPoint(x: -30, y: -500), displays: displays, clockFrames: [clock]))
    }
}
