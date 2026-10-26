import AppKit
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

@MainActor
final class ScreenshotEditorSaveTests: XCTestCase {
    func testFailedSaveKeepsDirtyDocumentAndDoesNotClose() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let state = canvas.documentStateID
        var closed = false
        editor.onClose = { _ in closed = true }
        editor.onSaveRevision = { _ in throw RevisionSaveError.unavailable }
        let result = await editor.saveRevision(closeAfterSaving: true)
        XCTAssertFalse(result)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(canvas.documentStateID, state)
        XCTAssertFalse(closed)
        XCTAssertFalse(editor.isSaving)
    }

    func testLateSaveDoesNotClearNewChangesOrClose() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let started = expectation(description: "save began")
        var continuation: CheckedContinuation<ArtifactManifest, Error>?
        var calls = 0
        editor.onSaveRevision = { _ in
            calls += 1
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        var closed = false
        editor.onClose = { _ in closed = true }
        let first = Task { await editor.saveRevision(closeAfterSaving: true) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(editor.isSaving)
        let duplicate = Task { await editor.saveRevision() }
        await Task.yield()
        addCounter(to: canvas, xOffset: 20)
        continuation?.resume(returning: receipt())
        let firstResult = await first.value
        let duplicateResult = await duplicate.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(duplicateResult)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertFalse(closed)
    }

    func testConfirmedSaveClosesWithCanonicalReceipt() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let revision = receipt()
        editor.onSaveRevision = { _ in revision }
        var closeURL: URL?
        editor.onClose = { closeURL = $0?.fileURL }
        let result = await editor.saveRevision(closeAfterSaving: true)
        XCTAssertTrue(result)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(closeURL, revision.canonicalURL)
    }

    func testExplicitSaveOfNewerStateWaitsForItsOwnReceipt() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let started = expectation(description: "first save started")
        var continuation: CheckedContinuation<ArtifactManifest, Error>?
        var calls = 0
        editor.onSaveRevision = { _ in
            calls += 1
            if calls == 1 {
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return self.receipt()
        }
        let first = Task { await editor.saveRevision() }
        await fulfillment(of: [started], timeout: 2)
        addCounter(to: canvas, xOffset: 20)
        let second = Task { await editor.saveRevision() }
        await Task.yield()
        continuation?.resume(returning: receipt())
        _ = await first.value
        let saved = await second.value
        XCTAssertTrue(saved)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testExportFailureKeepsCommittedRevisionAndRetryDoesNotResave() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let revision = receipt()
        var saves = 0
        editor.onSaveRevision = { _ in saves += 1; return revision }
        editor.onExportRevision = { _, _ in throw RevisionSaveError.unavailable }
        let url = URL(fileURLWithPath: "/tmp/export-fixture.png")
        let failed = await editor.saveRevision(exportURL: url)
        XCTAssertFalse(failed)
        XCTAssertFalse(editor.hasUnsavedChanges)
        editor.onExportRevision = { artifact, _ in XCTAssertEqual(artifact.id, revision.id) }
        let retried = await editor.saveRevision(exportURL: url)
        XCTAssertTrue(retried)
        XCTAssertEqual(saves, 1)
    }

    func testRevisionServicePreservesSourceAndChainsSuccessfulRevisions() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        let data = try canvas.renderPNGData()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let session = try await store.beginArtifact(kind: .still, fileExtension: "png")
        let original = try await store.finalizeData(data, for: session)
        let service = ArtifactRevisionService(store: store, source: original)
        let first = try await service.save(data)
        let second = try await service.save(data)
        XCTAssertEqual(first.sourceArtifactID, original.id)
        XCTAssertEqual(second.sourceArtifactID, first.id)
        XCTAssertEqual(second.revisionNumber, first.revisionNumber + 1)
        XCTAssertEqual(try Data(contentsOf: original.canonicalURL), data)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("old external copy".utf8).write(to: destination)
        try await service.export(second, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try Data(contentsOf: original.canonicalURL), data)
    }

    func testSaveAndCloseRetainsTextTypedDuringPersistence() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let started = expectation(description: "save started")
        var continuation: CheckedContinuation<ArtifactManifest, Error>?
        editor.onSaveRevision = { _ in
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        var closed = false
        editor.onClose = { _ in closed = true }
        let saving = Task { await editor.saveRevision(closeAfterSaving: true) }
        await fulfillment(of: [started], timeout: 2)
        canvas.tool = .text
        let point = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        canvas.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!)
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ScreenshotInlineTextView }.first)
        text.string = "保存期间新输入"
        continuation?.resume(returning: receipt())
        _ = await saving.value
        XCTAssertFalse(closed)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    func testExportRequestedDuringSaveIsNotLost() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        addCounter(to: canvas)
        let started = expectation(description: "save started")
        var continuation: CheckedContinuation<ArtifactManifest, Error>?
        editor.onSaveRevision = { _ in
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        var exports = 0
        editor.onExportRevision = { _, _ in exports += 1 }
        let saving = Task { await editor.saveRevision() }
        await fulfillment(of: [started], timeout: 2)
        let exporting = Task { await editor.saveRevision(exportURL: URL(fileURLWithPath: "/tmp/out.png")) }
        await Task.yield()
        continuation?.resume(returning: receipt())
        _ = await saving.value
        let exported = await exporting.value
        XCTAssertTrue(exported)
        XCTAssertEqual(exports, 1)
    }

    func testExportCannotOverwriteManagedOriginalOrSymlink() async throws {
        let (editor, canvas) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        let data = try canvas.renderPNGData()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: link) }
        let store = ArtifactStore(rootURL: root)
        let session = try await store.beginArtifact(kind: .still, fileExtension: "png")
        let original = try await store.finalizeData(data, for: session)
        let service = ArtifactRevisionService(store: store, source: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linked = link.appendingPathComponent(original.canonicalURL.path.replacingOccurrences(of: root.path + "/", with: ""))
        for destination in [original.canonicalURL, linked] {
            do {
                try await service.export(original, to: destination)
                XCTFail("managed destination accepted")
            } catch RevisionSaveError.managedDestination {} catch { XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: original.canonicalURL), data)
    }

    private func makeEditor() throws -> (ScreenshotEditorWindowController, ScreenshotAnnotationCanvasView) {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let editor = ScreenshotEditorWindowController(
            image: image, fileURL: URL(fileURLWithPath: "/tmp/source-fixture.png"), preferredScreen: nil
        )
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(editor.window?.contentView?.subviews.compactMap { $0 as? ScreenshotAnnotationCanvasView }.first)
        return (editor, canvas)
    }

    private func addCounter(to canvas: ScreenshotAnnotationCanvasView, xOffset: CGFloat = 0) {
        canvas.tool = .counter
        let point = canvas.convert(CGPoint(x: canvas.bounds.midX + xOffset, y: canvas.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        canvas.mouseDown(with: event)
    }

    private func receipt() -> ArtifactManifest {
        let url = URL(fileURLWithPath: "/tmp/confirmed-\(UUID().uuidString).png")
        return ArtifactManifest(
            id: UUID(), kind: .revision, status: .completed, canonicalURL: url, temporaryURL: url,
            originOperationID: UUID(), activeOperationID: UUID()
        )
    }
}
