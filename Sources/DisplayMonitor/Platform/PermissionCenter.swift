import AppKit
import ApplicationServices
import Combine
import DisplayMonitorCore

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var screenRecordingState: ScreenRecordingPermissionState = .unknown
    @Published private(set) var accessibilityState: InputControlPermissionState = .unknown
    @Published private(set) var lastActionMessage: String?

    private let screenRecordingManager = ScreenRecordingPermissionManager()
    private let directControlManager = DirectControlPermissionManager()

    func sync(
        screenRecording: ScreenRecordingPermissionState,
        accessibility: InputControlPermissionState
    ) {
        screenRecordingState = screenRecording
        accessibilityState = accessibility
    }

    func refresh() {
        let screenRecordingGranted = screenRecordingManager.preflight()
        if screenRecordingGranted {
            screenRecordingState = .granted
        } else if screenRecordingState == .granted || screenRecordingState == .revoked {
            screenRecordingState = .revoked
        } else {
            screenRecordingState = .notGranted
        }
        accessibilityState = directControlManager.permissionState()
    }

    func openScreenRecordingSettings() {
        screenRecordingManager.openSettings()
        lastActionMessage = "已打开屏幕录制设置；返回后请重新检测"
    }

    func openAccessibilitySettings() {
        directControlManager.openSettings()
        lastActionMessage = "已打开辅助功能设置；返回后请重新检测"
    }

    var screenRecordingLabel: String {
        switch screenRecordingState {
        case .unknown:
            return "未检测"
        case .checking:
            return "检测中"
        case .notGranted:
            return "未授权"
        case .granted:
            return "已授权"
        case .revoked:
            return "已撤销"
        }
    }

    var accessibilityLabel: String {
        accessibilityState.label
    }
}
