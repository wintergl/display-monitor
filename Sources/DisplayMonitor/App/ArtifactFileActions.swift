import AppKit
import DisplayMonitorCore
import Foundation

/// File and pasteboard operations shared by result cards and pinned images.
/// Presentation owners decide whether a successful action should dismiss their
/// own window; this helper only performs the non-destructive data operation.
enum ArtifactFileActions {
    static func usableURL(for artifact: ArtifactManifest, fileManager: FileManager = .default) -> URL? {
        if fileManager.fileExists(atPath: artifact.canonicalURL.path) {
            return artifact.canonicalURL
        }
        if fileManager.fileExists(atPath: artifact.temporaryURL.path) {
            return artifact.temporaryURL
        }
        return nil
    }

    @MainActor
    static func writeToPasteboard(_ artifact: ArtifactManifest, sourceURL: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied: Bool
        switch artifact.kind {
        case .still, .scrollStill, .revision:
            copied = pasteboard.setData(try Data(contentsOf: sourceURL), forType: .png)
        case .recording, .gif:
            copied = pasteboard.writeObjects([sourceURL as NSURL])
        }
        guard copied else {
            throw ArtifactFileActionError.clipboardWriteFailed
        }
    }

    static func saveCopy(
        _ artifact: ArtifactManifest,
        sourceURL: URL,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = try ScreenshotOutputLocation.nextAvailableURL(
            in: directory,
            baseName: saveBaseName(for: artifact.kind),
            pathExtension: artifact.canonicalURL.pathExtension,
            fileManager: fileManager
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private static func saveBaseName(for kind: ArtifactKind) -> String {
        switch kind {
        case .still, .scrollStill, .revision:
            return "Display Monitor Screenshot"
        case .recording:
            return "Display Monitor Recording"
        case .gif:
            return "Display Monitor GIF"
        }
    }
}

enum ArtifactFileActionError: LocalizedError {
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            return "无法写入剪贴板"
        }
    }
}
