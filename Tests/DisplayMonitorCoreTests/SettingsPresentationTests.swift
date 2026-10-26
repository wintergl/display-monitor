import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import XCTest

@testable import DisplayMonitor
@testable import DisplayMonitorCore

final class SettingsPresentationTests: XCTestCase {
    @MainActor
    func testSettingsWindowOpensAsSingleReusableWindow() throws {
        _ = NSApplication.shared
        let shell = ToolSuiteShell()
        defer {
            NSApp.windows
                .filter { $0.title == "Display Monitor 设置" }
                .forEach { $0.close() }
        }

        shell.openSettingsWindow()
        let firstWindow = try XCTUnwrap(NSApp.windows.first {
            $0.title == "Display Monitor 设置"
        })
        XCTAssertTrue(firstWindow.isVisible)
        XCTAssertTrue(firstWindow.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(
            firstWindow.contentView?.bounds.width ?? 0,
            DisplayMonitorSettingsLayout.minimumContentSize.width
        )
        XCTAssertGreaterThanOrEqual(
            firstWindow.contentView?.bounds.height ?? 0,
            DisplayMonitorSettingsLayout.minimumContentSize.height
        )

        shell.openSettingsWindow()
        let settingsWindows = NSApp.windows.filter {
            $0.title == "Display Monitor 设置"
        }
        XCTAssertEqual(settingsWindows.count, 1)
        XCTAssertTrue(settingsWindows.first === firstWindow)
    }

    @MainActor
    func testSettingsTabsRenderVisualFixtures() throws {
        _ = NSApplication.shared
        let shell = ToolSuiteShell()
        let menuBarStorage = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitor-SettingsFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: menuBarStorage) }
        shell.menuBarManagement = MenuBarManagementCoordinator(
            permissionClient: MenuBarControlPermissionClient(
                checkAccessibility: { true },
                requestAccessibility: { true },
                checkEventPosting: { true },
                requestEventPosting: { true }
            ),
            storageRootURL: menuBarStorage,
            osMajorVersion: { 27 },
            nativeVisibilitySupported: { true },
            acquireInputLease: { _ in nil },
            releaseInputLease: { _, _ in false }
        )
        shell.monitor.updateShortcutRegistrations(shell.monitor.shortcutBindings.map {
            GlobalShortcutRegistration(binding: $0, isRegistered: true, statusCode: noErr)
        })

        for (name, tab) in [
            ("settings-shortcuts.png", DisplayMonitorSettingsTab.shortcuts),
            ("settings-screenshots.png", DisplayMonitorSettingsTab.screenshots),
            ("settings-menubar.png", DisplayMonitorSettingsTab.menuBar),
            ("settings-advanced.png", DisplayMonitorSettingsTab.advanced)
        ] {
            let hostingView = NSHostingView(
                rootView: DisplayMonitorSettingsView(shell: shell, initialTab: tab)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            hostingView.appearance = NSAppearance(named: .aqua)
            hostingView.frame = CGRect(
                origin: .zero,
                size: DisplayMonitorSettingsLayout.preferredContentSize
            )
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            let bitmap = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            )
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertFalse(png.isEmpty)

            if let outputPath = ProcessInfo.processInfo.environment[
                "DISPLAY_MONITOR_SETTINGS_FIXTURE_DIR"
            ] {
                let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                try png.write(to: outputDirectory.appendingPathComponent(name))
            }
        }
    }

    func testCustomShortcutBindingRoundTripsThroughPersistedSettingsValue() throws {
        let binding = ShortcutBinding(
            command: .captureRegion,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(optionKey | shiftKey),
            keyEquivalent: "⌥⇧S"
        )

        let decoded = try XCTUnwrap(
            ShortcutRegistry.bindings(from: [
                binding.command.settingsKey: ShortcutRegistry.persistedValue(for: binding)
            ]).first { $0.command == binding.command }
        )

        XCTAssertEqual(decoded, binding)
    }

    func testInvalidCustomShortcutFallsBackToCommandDefault() throws {
        let decoded = try XCTUnwrap(
            ShortcutRegistry.bindings(from: ["captureRegion": "v1:999:0:bad"])
                .first { $0.command == .captureRegion }
        )
        let defaultBinding = try XCTUnwrap(
            ShortcutRegistry.defaultBindings.first { $0.command == .captureRegion }
        )

        XCTAssertEqual(decoded, defaultBinding)
    }

    func testShortcutConflictDetectionRejectsDuplicateChordAcrossCommands() throws {
        let captureBinding = try XCTUnwrap(
            ShortcutRegistry.defaultBindings.first { $0.command == .captureRegion }
        )
        let duplicate = ShortcutBinding(
            command: .toggleMonitor,
            keyCode: captureBinding.keyCode,
            modifiers: captureBinding.modifiers,
            keyEquivalent: captureBinding.keyEquivalent
        )

        XCTAssertEqual(
            ShortcutRegistry.conflictingCommand(
                for: duplicate,
                in: ShortcutRegistry.defaultBindings
            ),
            .captureRegion
        )
    }

    @MainActor
    func testShortcutRecordingKeepsExistingBindingsUnregisteredUntilItFinishes() throws {
        let suiteName = "DisplayMonitor.ShortcutRecordingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            dependencies: .standard(settingsStore: SettingsStore(defaults: defaults))
        )
        let router = ShortcutRouterSpy()
        router.seed(bindings: model.shortcutBindings)
        model.updateShortcutRegistrations(router.registrations)
        let shell = ToolSuiteShell(monitor: model, shortcutRouter: router)
        let originalBinding = try XCTUnwrap(
            model.shortcutBindings.first { $0.command == .captureRegion }
        )

        XCTAssertTrue(shell.beginShortcutRecording())
        XCTAssertTrue(shell.isShortcutRecording)
        XCTAssertEqual(shell.inputModeCoordinator.lease?.owner, .shortcutSafety)
        XCTAssertEqual(router.stopCallCount, 1)
        XCTAssertTrue(router.registrations.isEmpty)
        XCTAssertTrue(model.shortcutRegistrations.isEmpty)

        XCTAssertFalse(shell.updateShortcutBinding(originalBinding))
        XCTAssertEqual(router.startCallCount, 0)

        shell.finishShortcutRecording(.captured)

        XCTAssertFalse(shell.isShortcutRecording)
        XCTAssertNil(shell.inputModeCoordinator.lease)
        XCTAssertEqual(router.startCallCount, 1)
        XCTAssertTrue(router.registrations.allSatisfy(\.isRegistered))
        XCTAssertEqual(shell.lastCommandMessage, "“框选截图”快捷键未更改")
        XCTAssertEqual(shell.shortcutSettingsMessage, "“框选截图”快捷键未更改")
    }

    @MainActor
    func testShortcutRecordingDefersRegistrationAndRollsBackUnavailableBinding() throws {
        let suiteName = "DisplayMonitor.ShortcutRecordingRollbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            dependencies: .standard(settingsStore: SettingsStore(defaults: defaults))
        )
        let router = ShortcutRouterSpy(failingKeyCodes: [UInt32(kVK_ANSI_S)])
        router.seed(bindings: model.shortcutBindings)
        model.updateShortcutRegistrations(router.registrations)
        let shell = ToolSuiteShell(monitor: model, shortcutRouter: router)
        let originalBinding = try XCTUnwrap(
            model.shortcutBindings.first { $0.command == .captureRegion }
        )
        let unavailableBinding = ShortcutBinding(
            command: .captureRegion,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(optionKey | shiftKey),
            keyEquivalent: "⌥⇧S"
        )

        XCTAssertTrue(shell.beginShortcutRecording())
        XCTAssertTrue(shell.updateShortcutBinding(unavailableBinding))
        XCTAssertEqual(router.startCallCount, 0)
        XCTAssertEqual(
            model.shortcutBindings.first { $0.command == .captureRegion },
            originalBinding
        )

        shell.finishShortcutRecording(.captured)

        XCTAssertEqual(router.startCallCount, 2)
        XCTAssertEqual(
            router.startedBindings.first?.first { $0.command == .captureRegion },
            unavailableBinding
        )
        XCTAssertEqual(
            router.startedBindings.last?.first { $0.command == .captureRegion },
            originalBinding
        )
        XCTAssertEqual(
            model.shortcutBindings.first { $0.command == .captureRegion },
            originalBinding
        )
        XCTAssertTrue(router.registrations.allSatisfy(\.isRegistered))
        XCTAssertNil(shell.inputModeCoordinator.lease)
        XCTAssertEqual(
            shell.lastCommandMessage,
            "⌥⇧S 无法注册，已恢复 \(originalBinding.keyEquivalent)"
        )
        XCTAssertEqual(shell.shortcutSettingsMessage, shell.lastCommandMessage)
    }

    @MainActor
    func testCancellingShortcutRecordingDiscardsThePendingBinding() throws {
        let suiteName = "DisplayMonitor.ShortcutRecordingCancelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            dependencies: .standard(settingsStore: SettingsStore(defaults: defaults))
        )
        let router = ShortcutRouterSpy()
        router.seed(bindings: model.shortcutBindings)
        model.updateShortcutRegistrations(router.registrations)
        let shell = ToolSuiteShell(monitor: model, shortcutRouter: router)
        let originalBinding = try XCTUnwrap(
            model.shortcutBindings.first { $0.command == .captureRegion }
        )
        let proposedBinding = ShortcutBinding(
            command: .captureRegion,
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(optionKey | shiftKey),
            keyEquivalent: "⌥⇧S"
        )

        XCTAssertTrue(shell.beginShortcutRecording())
        XCTAssertTrue(shell.updateShortcutBinding(proposedBinding))
        shell.finishShortcutRecording(.cancelled)

        XCTAssertEqual(
            model.shortcutBindings.first { $0.command == .captureRegion },
            originalBinding
        )
        XCTAssertEqual(router.startCallCount, 1)
        XCTAssertEqual(
            router.startedBindings.last?.first { $0.command == .captureRegion },
            originalBinding
        )
        XCTAssertTrue(router.registrations.allSatisfy(\.isRegistered))
        XCTAssertNil(shell.inputModeCoordinator.lease)
        XCTAssertEqual(shell.lastCommandMessage, "已取消，快捷键未更改")
        XCTAssertEqual(shell.shortcutSettingsMessage, "已取消，快捷键未更改")
    }

    func testShortcutRecorderStateWaitsForMatchingKeyUpAndFinishesOnce() {
        var state = ShortcutRecorderState()

        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.acceptsKeyDown)
        XCTAssertTrue(state.capture(keyCode: UInt16(kVK_ANSI_S)))
        XCTAssertFalse(state.acceptsKeyDown)
        XCTAssertFalse(state.capture(keyCode: UInt16(kVK_ANSI_S)))
        XCTAssertFalse(state.shouldFinish(onKeyUp: UInt16(kVK_ANSI_A)))
        XCTAssertTrue(state.shouldFinish(onKeyUp: UInt16(kVK_ANSI_S)))
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.finish())
        XCTAssertFalse(state.isRecording)
        XCTAssertNil(state.capturedKeyCode)
    }

    func testSettingsStorePersistsSelectedScreenshotDirectory() throws {
        let suiteName = "DisplayMonitor.SettingsPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = AppSettings.safeDefault
        settings.screenshotSaveDirectoryPath = "/tmp/display-monitor-selected-folder"
        store.save(settings)

        XCTAssertEqual(
            store.load().screenshotSaveDirectoryPath,
            "/tmp/display-monitor-selected-folder"
        )
    }
}

@MainActor
private final class ShortcutRouterSpy: ShortcutRouting {
    private(set) var registrations: [GlobalShortcutRegistration] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var startedBindings: [[ShortcutBinding]] = []
    private let failingKeyCodes: Set<UInt32>

    init(failingKeyCodes: Set<UInt32> = []) {
        self.failingKeyCodes = failingKeyCodes
    }

    func seed(bindings: [ShortcutBinding]) {
        registrations = bindings.map {
            GlobalShortcutRegistration(binding: $0, isRegistered: true, statusCode: noErr)
        }
    }

    func start(
        bindings: [ShortcutBinding],
        onCommand: @escaping (ToolSuiteCommand) -> Void
    ) {
        startCallCount += 1
        startedBindings.append(bindings)
        registrations = bindings.map { binding in
            let isRegistered = !failingKeyCodes.contains(binding.keyCode)
            return GlobalShortcutRegistration(
                binding: binding,
                isRegistered: isRegistered,
                statusCode: isRegistered ? noErr : OSStatus(eventHotKeyExistsErr)
            )
        }
    }

    func stop() {
        stopCallCount += 1
        registrations = []
    }

    var hasSafeOptionChordRegistration: Bool {
        let optionCommands: Set<ToolSuiteCommand> = [.toggleMonitor, .captureRegion]
        return registrations
            .filter { optionCommands.contains($0.shortcut) }
            .allSatisfy(\.isRegistered)
    }
}
