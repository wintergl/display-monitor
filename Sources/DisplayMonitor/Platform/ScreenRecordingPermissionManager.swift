import AppKit
import CoreGraphics

final class ScreenRecordingPermissionManager {
    func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
