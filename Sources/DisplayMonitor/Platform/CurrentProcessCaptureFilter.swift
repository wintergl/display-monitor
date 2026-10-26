import Foundation
import ScreenCaptureKit

/// Builds a ScreenCaptureKit filter which keeps this app's utility panels out
/// of a capture. The explicit-window fallback is important for borderless
/// panels, where a shareable-content snapshot may not resolve our process.
enum CurrentProcessCaptureFilter {
    static func make(
        content: SCShareableContent,
        display: SCDisplay
    ) -> SCContentFilter {
        makeWithStrategy(content: content, display: display).filter
    }

    static func makeWithStrategy(
        content: SCShareableContent,
        display: SCDisplay
    ) -> (filter: SCContentFilter, strategy: String) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applications = content.applications.filter { $0.processID == currentPID }
        if applications.count == 1 {
            return (
                SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: []),
                "process"
            )
        }

        let bundleApplications = content.applications.filter {
            $0.bundleIdentifier == AppConstants.bundleIdentifier
        }
        if bundleApplications.count == 1 {
            return (
                SCContentFilter(display: display, excludingApplications: bundleApplications, exceptingWindows: []),
                "bundle"
            )
        }

        let windows = content.windows.filter { window in
            window.owningApplication?.processID == currentPID ||
                window.owningApplication?.bundleIdentifier == AppConstants.bundleIdentifier
        }
        return (
            SCContentFilter(display: display, excludingWindows: windows),
            "windows:\(windows.count)"
        )
    }
}
