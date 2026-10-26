import AppKit

/// Selection panels borrow keyboard focus without bringing the app's other
/// windows forward. Release that focus before taking any live capture frame.
@MainActor
final class ScreenshotFocusSession {
    private let captureRestoration: () -> (() -> Void)
    private var restoration: (() -> Void)?

    init(captureRestoration: (() -> (() -> Void))? = nil) {
        self.captureRestoration = captureRestoration ?? { Self.captureRestoration() }
    }

    func begin() {
        guard restoration == nil else { return }
        restoration = captureRestoration()
    }

    func restore() {
        let action = restoration
        restoration = nil
        action?()
    }

    private static func captureRestoration() -> () -> Void {
        let application = NSWorkspace.shared.frontmostApplication
        let window = NSApp.keyWindow
        return { [weak window] in
            guard let application, !application.isTerminated else { return }
            let currentPID = NSRunningApplication.current.processIdentifier
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // Respect an app switch made by the user during selection.
            guard frontmostPID == currentPID || frontmostPID == application.processIdentifier else { return }
            if application.processIdentifier == currentPID {
                if let window, window.isVisible, !window.isMiniaturized {
                    window.makeKey()
                }
            } else if frontmostPID == currentPID {
                application.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}
