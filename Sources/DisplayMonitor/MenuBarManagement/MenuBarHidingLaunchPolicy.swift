import Foundation

/// The system may fail to associate development-path status items with the
/// retained bundle ID. Only the system Applications location has passed the
/// bounded entry-retention control; this is a prerequisite, not visual proof.
enum MenuBarHidingLaunchPolicy {
    static func unavailableReason(applicationURL: URL) -> String? {
        let resolved = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "app",
              resolved.deletingLastPathComponent().path == "/Applications" else {
            return "请退出当前副本，改从“应用程序”文件夹打开 Display Monitor 后再收起图标。"
        }
        return nil
    }
}
