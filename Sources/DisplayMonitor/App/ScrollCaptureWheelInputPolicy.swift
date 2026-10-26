import CoreGraphics

/// Keeps this app's late injected wheel events out of natural mouse-follow.
/// Controller state, region and focus checks remain with the controller.
enum ScrollCaptureWheelInputPolicy {
    static let injectedEventTag: Int64 = 0x564D_5343_524F_4C4C

    enum Decision: Equatable {
        case ignore
        case followMouse
        case stopAutomaticAndFollowMouse
    }

    /// A mouse burst belongs to the user until both its debounce and analysis
    /// have finished. Starting the driver sooner can move the page underneath
    /// that still-pending capture.
    static func canStartAutomatic(captureInFlight: Bool, hasPendingScrollBurst: Bool) -> Bool {
        !captureInFlight && !hasPendingScrollBurst
    }

    static func decision(
        deltaY: CGFloat,
        gestureEnded: Bool,
        hasPendingScrollBurst: Bool,
        eventSourceUserData: Int64?,
        automaticScrollRunning: Bool
    ) -> Decision {
        guard eventSourceUserData != injectedEventTag, deltaY.isFinite else { return .ignore }
        if deltaY != 0 {
            return automaticScrollRunning ? .stopAutomaticAndFollowMouse : .followMouse
        }
        return gestureEnded && hasPendingScrollBurst && !automaticScrollRunning ? .followMouse : .ignore
    }
}
