import AppKit
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarStatusItemIdempotenceTests: XCTestCase {
    func testUnchangedPrimarySymbolDoesNotRepublishStatusItem() {
        _ = NSApplication.shared
        let controller = MainMenuBarStatusItemController()
        defer { controller.stop() }
        controller.start(symbolName: "display", title: "Test", accessibilityIdentifier: "test.idempotence")
        let initial = controller.symbolWriteCount
        XCTAssertEqual(initial, 1)
        for _ in 0..<5 {
            controller.updateSymbol(name: "display", accessibilityDescription: "Test")
        }
        XCTAssertEqual(controller.symbolWriteCount, initial)
        controller.updateSymbol(name: "display", accessibilityDescription: "Changed")
        XCTAssertEqual(controller.symbolWriteCount, initial + 1)
        controller.updateSymbol(name: "display", accessibilityDescription: "Changed")
        XCTAssertEqual(controller.symbolWriteCount, initial + 1)
    }

    func testNativeEntryHasNoHoverTrackingEvenWithSavedHoverPreference() {
        _ = NSApplication.shared
        let controller = MainMenuBarStatusItemController()
        defer { controller.stop() }
        controller.start(symbolName: "display", title: "Test", accessibilityIdentifier: "test.native-tracking")
        XCTAssertFalse(controller.hasHoverTrackingArea)
        controller.updateHoverEnabled(true)
        XCTAssertFalse(controller.hasHoverTrackingArea, "Native entry must keep the working pre-hover construction path")
        controller.updatePresentationMode(.quickBar)
        XCTAssertTrue(controller.hasHoverTrackingArea)
        controller.updateHoverEnabled(false)
        XCTAssertFalse(controller.hasHoverTrackingArea)
        controller.updateHoverEnabled(true)
        XCTAssertTrue(controller.hasHoverTrackingArea)
        controller.updatePresentationMode(.nativeMenuBar)
        XCTAssertFalse(controller.hasHoverTrackingArea)
    }
}
