import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarHoverTests: XCTestCase {
    func testHoverRequiresEveryPresentationGate() {
        func allowed(
            enabled: Bool = true, quickBar: Bool = true, inside: Bool = true,
            visible: Bool = false, context: Bool = false,
            pressed: Bool = false, suppressed: Bool = false
        ) -> Bool {
            MenuBarQuickBarHoverPolicy.shouldPresent(
                enabled: enabled, quickBarMode: quickBar, pointerInside: inside,
                alreadyVisible: visible, contextMenuOpen: context,
                mouseButtonPressed: pressed, suppressedUntilExit: suppressed
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(enabled: false))
        XCTAssertFalse(allowed(quickBar: false))
        XCTAssertFalse(allowed(inside: false))
        XCTAssertFalse(allowed(visible: true))
        XCTAssertFalse(allowed(context: true))
        XCTAssertFalse(allowed(pressed: true))
        XCTAssertFalse(allowed(suppressed: true))
    }
}
