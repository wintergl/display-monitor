import AppKit

@MainActor
final class AboutPanelPresenter {
    func show() {
        let alert = NSAlert()
        alert.messageText = "Display Monitor"
        alert.informativeText = """
        扩展屏实时监看工具

        已知限制：
        • DRM 或系统受保护内容可能显示为黑屏。
        • 镜像显示器不能作为独立画面监看。
        • AirPlay、Sidecar、DisplayLink 和虚拟显示器仅在系统暴露为可分享显示器时尽力支持。
        • 本应用窗口会被排除在采集内容之外，以避免递归画面。
        • 首次授权屏幕录制后，某些系统版本可能需要重启应用。

        当前包身份：
        Bundle ID: \(AppConstants.bundleIdentifier)
        Source: https://github.com/wintergl/display-monitor
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
