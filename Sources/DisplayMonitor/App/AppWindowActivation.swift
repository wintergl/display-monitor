import AppKit

@MainActor
enum AppWindowActivation {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(
            options: [.activateIgnoringOtherApps, .activateAllWindows]
        )
    }
}
