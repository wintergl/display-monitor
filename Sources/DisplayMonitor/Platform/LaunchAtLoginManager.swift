import ServiceManagement

final class LaunchAtLoginManager {
    func statusText() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "未注册"
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要批准"
        case .notFound:
            return "服务不可用"
        @unknown default:
            return "未知"
        }
    }

    func toggle() throws {
        switch SMAppService.mainApp.status {
        case .enabled:
            try SMAppService.mainApp.unregister()
        default:
            try SMAppService.mainApp.register()
        }
    }
}
