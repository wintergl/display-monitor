import Foundation

/// Resolves the user-facing output location used by the Quick Access save
/// action. Canonical capture artifacts remain under ArtifactStore ownership;
/// this utility only allocates a non-destructive user copy destination.
public enum ScreenshotOutputLocation {
    public static let defaultFolderName = "Display Monitor Screenshots"

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return desktop
            .appendingPathComponent(defaultFolderName, isDirectory: true)
            .standardizedFileURL
    }

    public static func resolvedDirectory(
        path: String?,
        fileManager: FileManager = .default
    ) -> URL {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else {
            return defaultDirectory(fileManager: fileManager)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Uses a fixed product name and adds a numeric suffix only when a file
    /// with that exact name already exists. This keeps filenames predictable
    /// without risking an overwrite of a previous user save.
    public static func nextAvailableURL(
        in directory: URL,
        baseName: String,
        pathExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let normalizedExtension = pathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let normalizedBaseName = baseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBaseName = normalizedBaseName.isEmpty ? "Display Monitor Screenshot" : normalizedBaseName

        for index in 1...10_000 {
            let fileName = index == 1 ? safeBaseName : "\(safeBaseName) \(index)"
            let candidate = normalizedExtension.isEmpty
                ? directory.appendingPathComponent(fileName, isDirectory: false)
                : directory.appendingPathComponent(fileName, isDirectory: false)
                    .appendingPathExtension(normalizedExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw ScreenshotOutputLocationError.nameSpaceExhausted(directory)
    }
}

public enum ScreenshotOutputLocationError: LocalizedError, Sendable {
    case nameSpaceExhausted(URL)

    public var errorDescription: String? {
        switch self {
        case .nameSpaceExhausted(let directory):
            return "保存目录中的同名文件过多：\(directory.path)"
        }
    }
}
