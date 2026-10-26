import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DisplayMonitor

@MainActor
final class SettingsNavigationRegressionTests: XCTestCase {
    func testSystemSettingsSelectionSurvivesRootReconstruction() async throws {
        _ = NSApplication.shared
        let shell = ToolSuiteShell()
        let host = NSHostingView(rootView: DisplayMonitorSettingsView(shell: shell, initialTab: .menuBar))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 540)
        let window = makeWindow(host)
        defer { window.close() }
        await settle(host)
        let menuBar = try pixels(host)

        // Model a Settings-scene reconstruction with the default initialTab.
        // The live StateObject must retain the menu-bar selection.
        host.rootView = DisplayMonitorSettingsView(shell: shell)
        await settle(host)
        XCTAssertTrue(try pixels(host) == menuBar, "Root reconstruction reset the selected settings pane")

        // A separately created window still uses its own initial selection.
        let other = NSHostingView(rootView: DisplayMonitorSettingsView(shell: shell))
        other.frame = host.frame
        let otherWindow = makeWindow(other)
        defer { otherWindow.close() }
        await settle(other)
        XCTAssertTrue(try pixels(other) != menuBar, "The regression check must distinguish the two panes")
    }

    func testAppKitSettingsStillRespondsToExternalNavigation() async throws {
        _ = NSApplication.shared
        let shell = ToolSuiteShell()
        let navigation = DisplayMonitorSettingsNavigation()
        let host = NSHostingView(rootView: DisplayMonitorSettingsView(shell: shell, navigation: navigation))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 540)
        let window = makeWindow(host)
        defer { window.close() }
        await settle(host)
        let shortcuts = try pixels(host)
        navigation.selectedTab = .menuBar
        await settle(host)
        let menuBar = try pixels(host)
        XCTAssertTrue(menuBar != shortcuts)
        shell.menuBarManagement.refreshPermissions()
        await settle(host)
        XCTAssertTrue(try pixels(host) == menuBar)
        navigation.selectedTab = .shortcuts
        await settle(host)
        XCTAssertTrue(try pixels(host) == shortcuts, "External navigation must remain functional")
    }

    func testPermissionRefreshOnlyPublishesRealChanges() {
        var accessibility = false
        var posting = false
        let model = MenuBarManagementCoordinator(
            permissionClient: MenuBarControlPermissionClient(
                checkAccessibility: { accessibility }, requestAccessibility: { false },
                checkEventPosting: { posting }, requestEventPosting: { false }
            ),
            storageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            osMajorVersion: { 26 }, nativeVisibilitySupported: { false },
            acquireInputLease: { _ in nil }, releaseInputLease: { _, _ in false }
        )
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        model.refreshPermissions()
        model.refreshPermissions()
        XCTAssertEqual(publications, 0)
        posting = true
        model.refreshPermissions()
        XCTAssertTrue(model.permissionStatus.eventPostingGranted)
        let afterPosting = publications
        XCTAssertGreaterThan(afterPosting, 0)
        model.refreshPermissions()
        XCTAssertEqual(publications, afterPosting)
        accessibility = true
        model.refreshPermissions()
        XCTAssertTrue(model.permissionStatus.accessibilityGranted)
        XCTAssertGreaterThan(publications, afterPosting)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        return window
    }

    private func pixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
