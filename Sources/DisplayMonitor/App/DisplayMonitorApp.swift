import AppKit
import SwiftUI

@main
struct DisplayMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var shell: ToolSuiteShell

    init() {
        let shell = ToolSuiteShell()
        _shell = StateObject(wrappedValue: shell)
        appDelegate.shell = shell
    }

    var body: some Scene {
        Settings {
            // macOS can open this scene through restoration or system actions.
            // It must contain the real settings even though normal menu actions
            // use the existing reusable AppKit settings window.
            DisplayMonitorSettingsView(shell: shell)
                .onDisappear(perform: cancelSettingsInputInteractions)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                    cancelSettingsInputInteractions()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
                    cancelSettingsInputInteractions()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    shell.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func cancelSettingsInputInteractions() {
        shell.cancelShortcutRecording()
        shell.cancelMenuBarOrdering(reason: "设置窗口已离开前台，正在停止排序并释放输入。")
    }
}
