import AppKit

enum MenuBarOrderExecutor {
    /// Capture AppKit process state on the main actor, then pass the value-only
    /// snapshots into detached AX reads or order execution.
    @MainActor
    static func applicationSnapshot() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                processIdentifier: application.processIdentifier
            )
        }
    }
}
