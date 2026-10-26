import AppKit
import DisplayMonitorCore
import Foundation

/// A drag exports exactly one immutable artifact version. Never substitute a
/// temporary recording, preview, or a later revision after the gesture starts.
struct ArtifactFileDragSnapshot {
    let token = UUID()
    let artifactID: UUID
    let commitSequence: Int
    let canonicalURL: URL
    let byteCount: Int64
    private let fileIdentifier: NSObject?
    private let modifiedAt: Date?

    var pasteboardWriter: NSURL { canonicalURL as NSURL }

    init(artifact: ArtifactManifest) throws {
        guard artifact.status.isTerminal, artifact.status != .failed,
              artifact.status != .discarded, artifact.canonicalURL.isFileURL else {
            throw ArtifactFileDragError.unavailable
        }
        let url = artifact.canonicalURL.standardizedFileURL
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileResourceIdentifierKey, .contentModificationDateKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: url.path),
              let size = values.fileSize, size > 0 else {
            throw ArtifactFileDragError.unavailable
        }
        if let expectedSize = artifact.contentByteCount, expectedSize != Int64(size) {
            throw ArtifactFileDragError.changed
        }
        artifactID = artifact.id
        commitSequence = artifact.commitSequence
        canonicalURL = url
        byteCount = Int64(size)
        fileIdentifier = values.fileResourceIdentifier as? NSObject
        modifiedAt = values.contentModificationDate
    }

    func matches(_ artifact: ArtifactManifest) -> Bool {
        artifact.id == artifactID && artifact.commitSequence == commitSequence &&
            artifact.canonicalURL.standardizedFileURL == canonicalURL
    }

    func validateFileIdentity() throws {
        // Recreate the URL to avoid reusing Foundation's cached resource values
        // after another process has atomically replaced the path.
        let values = try URL(fileURLWithPath: canonicalURL.path).resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileResourceIdentifierKey, .contentModificationDateKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == byteCount,
              values.contentModificationDate == modifiedAt else {
            throw ArtifactFileDragError.changed
        }
        if let fileIdentifier,
           !fileIdentifier.isEqual(values.fileResourceIdentifier as? NSObject) {
            throw ArtifactFileDragError.changed
        }
    }
}

enum ArtifactFileDragError: LocalizedError {
    case unavailable
    case changed

    var errorDescription: String? {
        switch self {
        case .unavailable: "文件尚未完成或不可读取，浮窗已保留"
        case .changed: "文件版本已变化，浮窗已保留"
        }
    }
}

/// A narrow AppKit bridge. Preview decoration is hit-transparent for dragging;
/// existing buttons keep their normal click and hover behavior.
@MainActor
class ArtifactFileDragView: NSView, NSDraggingSource {
    var onBeginFileDrag: (() -> ArtifactFileDragSnapshot?)?
    var onEndFileDrag: ((ArtifactFileDragSnapshot, NSDragOperation) -> Void)?
    private(set) var activeDrag: ArtifactFileDragSnapshot?
    private var mouseDownLocation: NSPoint?

    var sourceOperations: NSDragOperation { .copy }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard onBeginFileDrag != nil else { return hit }
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is NSButton { return hit }
            candidate = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeDrag == nil, window != nil, let initial = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - initial.x, current.y - initial.y) >= 4,
              let snapshot = prepareFileDrag() else { return }
        let item = NSDraggingItem(pasteboardWriter: snapshot.pasteboardWriter)
        let icon = NSWorkspace.shared.icon(forFile: snapshot.canonicalURL.path)
        item.setDraggingFrame(
            CGRect(x: current.x - 24, y: current.y - 24, width: 48, height: 48),
            contents: icon
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        mouseDownLocation = nil
    }

    override func mouseUp(with event: NSEvent) { mouseDownLocation = nil }

    /// These methods own the same lifecycle used by AppKit's delegate receipt,
    /// allowing tests to verify cancellation and exact-card dismissal without
    /// delivering a synthetic drop into another real application.
    @discardableResult
    func prepareFileDrag() -> ArtifactFileDragSnapshot? {
        guard activeDrag == nil, let snapshot = onBeginFileDrag?() else { return nil }
        activeDrag = snapshot
        return snapshot
    }

    func finishFileDrag(operation: NSDragOperation) {
        guard let snapshot = activeDrag else { return }
        activeDrag = nil
        onEndFileDrag?(snapshot, operation)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        sourceOperations
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishFileDrag(operation: operation)
    }
}
