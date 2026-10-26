import DisplayMonitorCore
import Foundation
import ImageIO

/// One editor's ordered, canonical-first revision writer. A returned manifest
/// is the persistence receipt; exporting a copy is a separate operation.
@MainActor
final class ArtifactRevisionService {
    private let store: ArtifactStore
    private var source: ArtifactManifest
    private var isSaving = false

    init(store: ArtifactStore, source: ArtifactManifest) {
        self.store = store
        self.source = source
    }

    func save(_ data: Data) async throws -> ArtifactManifest {
        guard !isSaving else { throw RevisionSaveError.alreadySaving }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw RevisionSaveError.invalidImage }
        isSaving = true
        defer { isSaving = false }
        let session = try await store.beginArtifact(
            kind: .revision,
            fileExtension: "png",
            sourceArtifactID: source.id,
            dimensions: PixelSize(width: width, height: height),
            displayID: source.displayID,
            captureRegion: source.captureRegion
        )
        let revision = try await store.finalizeData(data, for: session)
        source = revision
        return revision
    }

    func export(_ revision: ArtifactManifest, to destination: URL) async throws {
        guard !(await store.isManagedLocation(destination)) else {
            throw RevisionSaveError.managedDestination
        }
        // NSSavePanel has already resolved overwrite intent. Atomic writing
        // preserves an existing destination if the replacement fails.
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: revision.canonicalURL, options: .alwaysMapped)
            try data.write(to: destination, options: .atomic)
        }.value
        // The external file is already delivered. A bookkeeping failure must
        // not turn it into a false "export failed" or recreate the revision.
        _ = try? await store.setDesktopExportURL(destination, for: revision.id)
    }
}

enum RevisionSaveError: LocalizedError {
    case alreadySaving
    case invalidImage
    case unavailable
    case managedDestination

    var errorDescription: String? {
        switch self {
        case .alreadySaving: return "正在保存上一版本，请稍候"
        case .invalidImage: return "无法读取编辑图片尺寸"
        case .unavailable: return "保存服务暂不可用，修改仍保留在编辑器中"
        case .managedDestination: return "请选择产物库之外的位置，原图和编辑版本不能被覆盖"
        }
    }
}
