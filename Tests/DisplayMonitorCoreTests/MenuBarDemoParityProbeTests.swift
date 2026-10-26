import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarDemoParityProbeTests: XCTestCase {
    func testProbeOnlyExcludesItsExplicitHelperAndRetainsHostAndOtherApps() throws {
        let plan = try MenuBarDemoParityProbe.plan(runningIDs: [
            MenuBarDemoParityProbe.helperID, AppConstants.bundleIdentifier, "example.other"
        ])
        XCTAssertEqual(plan.targetBundleIdentifiers, [MenuBarDemoParityProbe.helperID])
        XCTAssertTrue(plan.allowedBundleIdentifiers.contains(AppConstants.bundleIdentifier))
        XCTAssertTrue(plan.allowedBundleIdentifiers.contains("example.other"))
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains(MenuBarDemoParityProbe.helperID))
        XCTAssertEqual(plan.allowedSystemItems, Array(0...8))
    }
    func testProbeCannotHideWithoutItsRunningHelper() {
        XCTAssertThrowsError(try MenuBarDemoParityProbe.plan(runningIDs: [AppConstants.bundleIdentifier]))
    }
    func testExplicitEntryModeDoesNotDependOnDesktopPopupSelection() {
        XCTAssertEqual(MenuBarDemoParityProbe.requestedEntryMode(arguments: []), .demo)
        XCTAssertEqual(MenuBarDemoParityProbe.requestedEntryMode(arguments: ["--menu-bar-demo-entry-mode=1"]), .demoHiddenActivity)
        XCTAssertEqual(MenuBarDemoParityProbe.requestedEntryMode(arguments: ["--menu-bar-demo-entry-mode=2"]), .product)
        XCTAssertEqual(MenuBarDemoParityProbe.requestedEntryMode(arguments: ["--menu-bar-demo-entry-mode=3"]), .demo)
        XCTAssertEqual(MenuBarDemoParityProbe.requestedEntryMode(arguments: ["--menu-bar-demo-entry-mode=bad"]), .demo)
    }
    func testStandaloneProbeIsOutsideControllerApplicationContainer() {
        let app = URL(fileURLWithPath: "/tmp/candidate/Display Monitor.app", isDirectory: true)
        let standalone = MenuBarDemoParityProbe.helperURL(applicationURL: app, standalone: true)
        XCTAssertEqual(standalone.path, "/tmp/candidate/MenuBarHideProbe.app")
        XCTAssertFalse(standalone.path.hasPrefix(app.path + "/"))
        XCTAssertEqual(MenuBarDemoParityProbe.helperURL(applicationURL: app, standalone: false).path,
                       "/tmp/candidate/Display Monitor.app/Contents/Helpers/MenuBarHideProbe.app")
    }
    func testDiagnosticPlanUsesItsActualIdentityWithoutChangingProductionIdentity() throws {
        let unique = "com.hanshuai.DisplayMonitor.BoundaryCheck20261022"
        let plan = try MenuBarDemoParityProbe.plan(runningIDs: [unique, MenuBarDemoParityProbe.helperID], controllerID: unique)
        XCTAssertTrue(plan.allowedBundleIdentifiers.contains(unique))
        XCTAssertFalse(plan.allowedBundleIdentifiers.contains(MenuBarDemoParityProbe.helperID))
        XCTAssertEqual(plan.targetBundleIdentifiers, [MenuBarDemoParityProbe.helperID])
        XCTAssertEqual(AppConstants.bundleIdentifier, "com.hanshuai.DisplayMonitor")
    }
}
