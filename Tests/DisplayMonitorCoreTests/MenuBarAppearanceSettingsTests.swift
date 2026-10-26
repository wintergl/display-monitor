import AppKit
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarAppearanceSettingsTests: XCTestCase {
    func testOldSettingsKeepExistingBehaviorAndNewPreferencesSurviveReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"schemaVersion":1,"isEnabled":true,"wantsPersistentCollapse":true,
         "primaryPresentationMode":"nativeMenuBar","showQuickBarOnHover":true}
        """.utf8).write(to: root.appendingPathComponent("settings-v1.json"))
        let coordinator = makeCoordinator(root)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(coordinator.wantsPersistentCollapse)
        XCTAssertEqual(coordinator.iconStyle, .display)
        XCTAssertEqual(coordinator.autoHideDelaySeconds, 4)
        coordinator.setIconStyle(.dots)
        coordinator.setAutoHideDelaySeconds(17)
        // Saving a different preference must retain both new settings.
        coordinator.setShowQuickBarOnHover(false)
        let reloaded = makeCoordinator(root)
        XCTAssertEqual(reloaded.iconStyle, .dots)
        XCTAssertEqual(reloaded.autoHideDelaySeconds, 17)
        XCTAssertFalse(reloaded.showQuickBarOnHover)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertTrue(reloaded.wantsPersistentCollapse)
        await coordinator.shutdown()
        await reloaded.shutdown()
    }

    func testUnknownStyleAndOutOfRangeDelayDoNotDiscardOtherPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"schemaVersion":1,"isEnabled":true,"wantsPersistentCollapse":true,
         "iconStyle":"future-style","autoHideDelaySeconds":99999}
        """.utf8).write(to: root.appendingPathComponent("settings-v1.json"))
        let coordinator = makeCoordinator(root)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.iconStyle, .display)
        XCTAssertEqual(coordinator.autoHideDelaySeconds, 300)
        coordinator.setAutoHideDelaySeconds(-10)
        XCTAssertEqual(coordinator.autoHideDelaySeconds, 1)
        let reloaded = makeCoordinator(root)
        XCTAssertEqual(reloaded.autoHideDelaySeconds, 1)
        await coordinator.shutdown()
        await reloaded.shutdown()
    }

    func testFailedSaveLeavesActivePreferencesUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // A regular file cannot hold the settings directory.
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(root)
        coordinator.setIconStyle(.grid)
        coordinator.setAutoHideDelaySeconds(20)
        XCTAssertEqual(coordinator.iconStyle, .display)
        XCTAssertEqual(coordinator.autoHideDelaySeconds, 4)
        XCTAssertTrue(coordinator.message.contains("未能保存"))
        await coordinator.shutdown()
    }

    func testEveryStyleHasAnImageAndKeepsMonitorStateFeedback() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: style.symbolName, accessibilityDescription: style.title))
            XCTAssertEqual(style.symbolName(monitorSymbol: "display"), style.symbolName)
            for feedback in ["display.and.arrow.down", "pause.rectangle", "exclamationmark.triangle"] {
                XCTAssertEqual(style.symbolName(monitorSymbol: feedback), feedback)
            }
        }
    }

    private func makeCoordinator(_ root: URL) -> MenuBarManagementCoordinator {
        MenuBarManagementCoordinator(
            permissionClient: MenuBarControlPermissionClient(
                checkAccessibility: { false }, requestAccessibility: { false },
                checkEventPosting: { false }, requestEventPosting: { false }
            ),
            storageRootURL: root, osMajorVersion: { 27 },
            nativeVisibilitySupported: { false },
            acquireInputLease: { _ in nil }, releaseInputLease: { _, _ in false }
        )
    }
}
