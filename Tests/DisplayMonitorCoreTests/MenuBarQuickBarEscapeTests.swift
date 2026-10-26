import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarEscapeTests: XCTestCase {
    func testLocalEscapeCanCloseTheBarWithoutReachingUnderlyingAppControls() {
        XCTAssertEqual(
            MenuBarQuickBarEscapePolicy.decision(keyCode: 53, source: .local),
            .dismissAndConsume
        )
    }

    func testGlobalEscapeKeepsTheFrontmostAppInControlOfItsKeyboard() {
        XCTAssertEqual(
            MenuBarQuickBarEscapePolicy.decision(keyCode: 53, source: .global),
            .dismissAndPassThrough
        )
    }

    func testOtherKeysNeverDismissOrConsume() {
        for keyCode: UInt16 in [0, 36, 48, 49, 123, 124] {
            XCTAssertEqual(MenuBarQuickBarEscapePolicy.decision(keyCode: keyCode, source: .local), .ignore)
            XCTAssertEqual(MenuBarQuickBarEscapePolicy.decision(keyCode: keyCode, source: .global), .ignore)
        }
    }
}
