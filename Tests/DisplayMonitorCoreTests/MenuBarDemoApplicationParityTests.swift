import AppKit
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarDemoApplicationParityTests: XCTestCase {
    func testDiagnosticParityUsesDemoRegularApplicationWithoutChangingDefault() {
        XCTAssertEqual(AppDelegate.activationPolicy(demoParity: true), .regular)
        XCTAssertEqual(AppDelegate.activationPolicy(demoParity: false), .accessory)
    }

    func testNativeEntryKeepsThePreviouslyWorkingProductLength() {
        XCTAssertEqual(MainMenuBarStatusItemController.entryLength, NSStatusItem.variableLength)
    }
}
