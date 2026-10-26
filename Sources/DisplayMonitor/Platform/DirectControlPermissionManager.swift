import ApplicationServices
import AppKit
import OSLog

enum InputControlPermissionState: Equatable {
    case unknown
    case denied
    case granted

    var label: String {
        switch self {
        case .unknown:
            return "未检测"
        case .denied:
            return "未授权"
        case .granted:
            return "已授权"
        }
    }
}

final class DirectControlPermissionManager {
    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "DirectControlPermission"
    )

    func permissionState() -> InputControlPermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    func openSettings() {
        logger.info("directControl.permission.openSettings")
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            logger.error("directControl.permission.settingsURLInvalid")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
