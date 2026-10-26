import AppKit
import DisplayMonitorCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DisplayMonitor

@MainActor
final class ArtifactFileDragTests: XCTestCase {
    func testSnapshotPasteboardWriterProvidesCanonicalURLAndRejectsTemporaryOrSymlinkFallback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("canonical.png")
        let temporary = root.appendingPathComponent("unfinished.png")
        try png().write(to: canonical)
        try Data("temporary sentinel".utf8).write(to: temporary)
        var artifact = manifest(canonical: canonical, temporary: temporary)
        let snapshot = try ArtifactFileDragSnapshot(artifact: artifact)
        XCTAssertEqual(snapshot.canonicalURL, canonical)
        // Validate the exact NSPasteboardWriting object passed to NSDraggingItem.
        // Do not depend on a logged-in pasteboard server or mutate the user's
        // general clipboard in these isolated tests.
        let pasteboard = NSPasteboard(name: .init("artifact-file-drag-\(UUID())"))
        let writer = snapshot.pasteboardWriter
        XCTAssertTrue(writer.writableTypes(for: pasteboard).contains(.fileURL))
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .fileURL) as? String, canonical.absoluteString)
        artifact.canonicalURL = root.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try ArtifactFileDragSnapshot(artifact: artifact), "Never drag temporaryURL instead")
        let symbolic = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: canonical)
        artifact.canonicalURL = symbolic
        XCTAssertThrowsError(try ArtifactFileDragSnapshot(artifact: artifact))
        artifact.canonicalURL = canonical
        for status: ArtifactStatus in [.preparing, .capturing, .finalizing, .failed, .discarded] {
            artifact.status = status
            XCTAssertThrowsError(try ArtifactFileDragSnapshot(artifact: artifact))
        }
    }

    func testSnapshotPinsVersionAndDetectsReplacedFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        let data = try png()
        try data.write(to: url)
        let artifact = manifest(canonical: url, temporary: url)
        let snapshot = try ArtifactFileDragSnapshot(artifact: artifact)
        XCTAssertTrue(snapshot.matches(artifact))
        try snapshot.validateFileIdentity()
        var newer = artifact
        newer.commitSequence += 1
        XCTAssertFalse(snapshot.matches(newer))
        newer = manifest(canonical: url, temporary: url)
        XCTAssertFalse(snapshot.matches(newer))
        // Atomic replacement can retain exactly the same bytes and length but
        // has a different file identity. Never treat its receipt as the old drag.
        try data.write(to: url, options: .atomic)
        XCTAssertThrowsError(try snapshot.validateFileIdentity())
    }

    func testDragViewIsCopyOnlyAndPreservesButtonHitTesting() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        try png().write(to: url)
        let artifact = manifest(canonical: url, temporary: url)
        let source = ArtifactFileDragView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        source.onBeginFileDrag = { try? ArtifactFileDragSnapshot(artifact: artifact) }
        let image = NSImageView(frame: source.bounds)
        source.addSubview(image)
        let button = NSButton(frame: CGRect(x: 10, y: 10, width: 50, height: 30))
        source.addSubview(button)
        XCTAssertTrue(source.hitTest(NSPoint(x: 150, y: 90)) === source)
        XCTAssertTrue(source.hitTest(NSPoint(x: 20, y: 20)) === button)
        XCTAssertEqual(source.sourceOperations, .copy)
        XCTAssertFalse(source.sourceOperations.contains(.move))
        XCTAssertFalse(source.sourceOperations.contains(.delete))
        var receipts = 0
        source.onEndFileDrag = { _, _ in receipts += 1 }
        XCTAssertNotNil(source.prepareFileDrag())
        XCTAssertNil(source.prepareFileDrag(), "One source can own only one drag")
        source.finishFileDrag(operation: [])
        source.finishFileDrag(operation: .copy)
        XCTAssertEqual(receipts, 1)
    }

    func testCancelledRejectedAndMoveReceiptsKeepCardAndOriginalThenCopyClosesOnlyThatCard() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let first = try await artifact(in: context.store, kind: .still)
        let second = try await artifact(in: context.store, kind: .still)
        let original = try Data(contentsOf: first.canonicalURL)
        await context.shelf.present(first)
        let panel = try XCTUnwrap(newPanels(context).first)
        let drag = try dragView(in: panel)
        let originalFrame = panel.frame
        for operation: NSDragOperation in [[], .move, .delete, .link] {
            let snapshot = try XCTUnwrap(drag.prepareFileDrag())
            XCTAssertEqual(snapshot.artifactID, first.id)
            drag.finishFileDrag(operation: operation)
            XCTAssertNotNil(panel.contentView)
            XCTAssertEqual(try Data(contentsOf: first.canonicalURL), original)
        }
        XCTAssertNotNil(drag.prepareFileDrag())
        await context.shelf.present(second)
        context.shelf.refreshFollowActiveDisplayPolicy()
        XCTAssertEqual(panel.frame, originalFrame, "Following and layout must freeze throughout the drag")
        let close = descendants(panel.contentView).compactMap { $0 as? NSButton }
            .first { $0.toolTip == "关闭截图浮窗" }
        try XCTUnwrap(close).performClick(nil)
        XCTAssertNotNil(panel.contentView, "Close must not remove the active drag source")
        drag.finishFileDrag(operation: .copy)
        XCTAssertNil(panel.contentView)
        XCTAssertEqual(newPanels(context).filter { $0.contentView != nil }.count, 1)
        XCTAssertEqual(try Data(contentsOf: first.canonicalURL), original)
        let stored = try await context.store.artifact(id: first.id)
        XCTAssertEqual(stored.status, .completed, "Closing a drag card never discards its original")
    }

    func testLateCopyReceiptDoesNotDismissUpdatedRevisionOrReplaceSourceViewDuringDrag() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let source = try await artifact(in: context.store, kind: .still)
        let revision = try await artifact(in: context.store, kind: .revision, sourceID: source.id)
        await context.shelf.present(source)
        let panel = try XCTUnwrap(newPanels(context).first)
        let before = panel.contentView
        let drag = try dragView(in: panel)
        let snapshot = try XCTUnwrap(drag.prepareFileDrag())
        context.shelf.replaceVisibleArtifact(in: source.id, with: revision)
        XCTAssertTrue(panel.contentView === before)
        XCTAssertEqual(snapshot.canonicalURL, source.canonicalURL)
        drag.finishFileDrag(operation: .copy)
        XCTAssertNotNil(panel.contentView)
        XCTAssertFalse(panel.contentView === before)
        let nextDrag = try dragView(in: panel)
        let next = try XCTUnwrap(nextDrag.prepareFileDrag())
        XCTAssertEqual(next.artifactID, revision.id)
        XCTAssertEqual(next.canonicalURL, revision.canonicalURL)
        nextDrag.finishFileDrag(operation: [])
    }

    func testDraggingRecordingBlocksDeletionAndItsDragAreaIsDiscoverable() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let recording = try await artifact(in: context.store, kind: .recording)
        await context.shelf.present(recording)
        let panel = try XCTUnwrap(newPanels(context).first)
        let drag = try dragView(in: panel)
        XCTAssertEqual(drag.toolTip, "拖出录屏文件到 Finder 或其他应用")
        XCTAssertTrue(descendants(panel.contentView).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("可拖出文件") })
        XCTAssertNotNil(drag.prepareFileDrag())
        let delete = try XCTUnwrap(descendants(panel.contentView).compactMap { $0 as? NSButton }.first { $0.title == "删除" })
        delete.performClick(nil)
        let stored = try await context.store.artifact(id: recording.id)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.canonicalURL.path))
        drag.finishFileDrag(operation: [])
        XCTAssertNotNil(panel.contentView)
    }

    func testGIFAndScreenshotDragAreasKeepHoverControlsAndTrimmingCannotRemoveActiveSource() async throws {
        let context = try makeContext(recentLimit: 1)
        defer { context.cleanup() }
        let first = try await artifact(in: context.store, kind: .still)
        let gif = try await artifact(in: context.store, kind: .gif)
        await context.shelf.present(first)
        let panel = try XCTUnwrap(newPanels(context).first)
        let content = try XCTUnwrap(panel.contentView as? QuickAccessContentView)
        content.setHoverActionsVisible(true, animated: false)
        let hoverButtons = descendants(content).compactMap { $0 as? NSButton }
            .filter { $0.toolTip == "复制" || $0.toolTip == "编辑" || $0.toolTip == "保存" }
        XCTAssertEqual(hoverButtons.count, 3)
        let drag = try dragView(in: panel)
        XCTAssertNotNil(drag.prepareFileDrag())
        await context.shelf.present(gif)
        XCTAssertNotNil(panel.contentView)
        XCTAssertEqual(newPanels(context).filter { $0.contentView != nil }.count, 2,
                       "A limit of one must defer trimming a new capture during the old drag")
        drag.finishFileDrag(operation: [])
        XCTAssertNotNil(panel.contentView)
        XCTAssertEqual(newPanels(context).filter { $0.contentView != nil }.count, 2,
                       "Cancellation preserves both the original card and the new capture")
        // The next ordinary presentation may apply the limit again. The GIF
        // retains its explicit canonical drag area after the old card is trimmed.
        await context.shelf.present(gif)
        let gifPanel = try XCTUnwrap(newPanels(context).first { $0.contentView != nil })
        let gifDrag = try dragView(in: gifPanel)
        let payload = try XCTUnwrap(gifDrag.prepareFileDrag())
        XCTAssertEqual(payload.artifactID, gif.id)
        XCTAssertEqual(payload.canonicalURL, gif.canonicalURL)
        gifDrag.finishFileDrag(operation: [])
    }

    private struct Context {
        let root: URL
        let store: ArtifactStore
        let shelf: ArtifactShelfController
        let baselineWindows: Set<ObjectIdentifier>
        @MainActor func cleanup() {
            shelf.hide()
            NSApp.windows.filter { !baselineWindows.contains(ObjectIdentifier($0)) && $0.title == "截图浮窗" }
                .forEach {
                    // Utility panels are not released on close and AppKit may
                    // retain them until a later autorelease turn. Retire the
                    // test-owned content just as dismissOverlay does, so a
                    // subsequent test cannot mistake a closed panel for its
                    // own live Quick Access card.
                    $0.orderOut(nil)
                    $0.contentView = nil
                    $0.close()
                }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeContext(recentLimit: Int = 20) throws -> Context {
        _ = NSApplication.shared
        let root = try temporaryRoot()
        let store = ArtifactStore(rootURL: root)
        let baseline = Set(NSApp.windows.map(ObjectIdentifier.init))
        let shelf = ArtifactShelfController(
            artifactStore: store,
            recentLimit: { recentLimit }
        )
        return Context(root: root, store: store, shelf: shelf, baselineWindows: baseline)
    }

    private func newPanels(_ context: Context) -> [NSWindow] {
        NSApp.windows.filter {
            !context.baselineWindows.contains(ObjectIdentifier($0)) && $0.title == "截图浮窗"
        }
    }

    private func dragView(in panel: NSWindow) throws -> ArtifactFileDragView {
        try XCTUnwrap(descendants(panel.contentView).compactMap { $0 as? ArtifactFileDragView }.first)
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants($0) }
    }

    private func artifact(in store: ArtifactStore, kind: ArtifactKind, sourceID: UUID? = nil) async throws -> ArtifactManifest {
        let session = try await store.beginArtifact(
            kind: kind, fileExtension: kind == .recording ? "mp4" : kind == .gif ? "gif" : "png",
            sourceArtifactID: sourceID, dimensions: PixelSize(width: 8, height: 8)
        )
        return try await store.finalizeData(png(), for: session)
    }

    private func manifest(canonical: URL, temporary: URL) -> ArtifactManifest {
        ArtifactManifest(
            id: UUID(), kind: .still, status: .completed,
            canonicalURL: canonical, temporaryURL: temporary,
            originOperationID: UUID(), activeOperationID: UUID()
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-file-drag-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func png() throws -> Data {
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
