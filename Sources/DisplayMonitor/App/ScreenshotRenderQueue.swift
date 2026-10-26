import Foundation

/// One document raster export at a time across independent editor windows.
/// Waiting never occupies the main actor; snapshots remain immutable.
actor ScreenshotRenderQueue {
    static let shared = ScreenshotRenderQueue()
    private var tail: Task<Void, Never>?
    private var tailID: UUID?

    func render(_ snapshot: ScreenshotRenderSnapshot,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Data {
        let predecessor = tail
        let id = UUID()
        let worker = Task.detached(priority: .userInitiated) {
            await predecessor?.value
            return try ScreenshotDocumentRenderer(snapshot: snapshot).pngData(progress: progress)
        }
        tailID = id
        tail = Task { _ = try? await worker.value }
        defer {
            if tailID == id { tail = nil; tailID = nil }
        }
        return try await worker.value
    }
}
