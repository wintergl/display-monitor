import AppKit
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

final class ScreenshotViewportTests: XCTestCase {
    func testRasterBudgetRejectsOverflowAndOversizedAllocation() {
        XCTAssertFalse(ScreenshotRasterBudget.permits(width: Int.max, height: 2))
        XCTAssertFalse(ScreenshotRasterBudget.permits(width: 2000, height: 120_000))
        XCTAssertTrue(ScreenshotRasterBudget.permits(width: 1440, height: 20_000))
        XCTAssertFalse(ScreenshotRasterBudget.permits(width: -1, height: 10))
    }
    func testLongImageStartsAtTopAndCanReachBottomWithoutLosingEdges() {
        var view = ScreenshotViewportTransform(cropRect: CGRect(x: 30, y: 70, width: 1200, height: 50_000),
                                               viewport: CGRect(x: 24, y: 24, width: 900, height: 600),
                                               backingScale: 2, mode: .fitWidth)
        XCTAssertEqual(view.drawingRect.minY, 24)
        XCTAssertEqual(view.drawingRect.width, 900)
        view.move(by: CGSize(width: -1_000_000, height: -1_000_000))
        XCTAssertEqual(view.drawingRect.maxY, 624)
        XCTAssertEqual(view.drawingRect.minX, 24)
        XCTAssertEqual(view.imagePoint(at: CGPoint(x: 924, y: 624), clamped: true), CGPoint(x: 1230, y: 50_070))
        view.move(by: CGSize(width: 1_000_000, height: 1_000_000))
        XCTAssertEqual(view.drawingRect.minY, 24)
    }

    func testActualPixelsAndCroppedImageRoundTripOnOneAndTwoX() throws {
        for density: CGFloat in [1, 2] {
            let view = ScreenshotViewportTransform(cropRect: CGRect(x: 100, y: 300, width: 2000, height: 4000),
                                                   viewport: CGRect(x: -900, y: -300, width: 800, height: 600),
                                                   backingScale: density, mode: .actualPixels)
            XCTAssertEqual(view.scale * density, 1)
            let imagePoint = CGPoint(x: 300, y: 600)
            let result = try XCTUnwrap(view.imagePoint(at: view.viewPoint(for: imagePoint)))
            XCTAssertEqual(result.x, imagePoint.x, accuracy: 0.0001)
            XCTAssertEqual(result.y, imagePoint.y, accuracy: 0.0001)
        }
    }

    func testPointerAnchoredZoomDoesNotDriftAfterPanning() throws {
        var view = ScreenshotViewportTransform(cropRect: CGRect(x: 100, y: 300, width: 3000, height: 6000),
                                               viewport: CGRect(x: 24, y: 24, width: 900, height: 600),
                                               backingScale: 2, mode: .actualPixels)
        view.move(by: CGSize(width: -300, height: -500))
        let anchor = CGPoint(x: 450, y: 350)
        let original = try XCTUnwrap(view.imagePoint(at: anchor))
        view.zoom(by: 1.6, around: anchor)
        let actual = try XCTUnwrap(view.imagePoint(at: anchor))
        XCTAssertEqual(actual.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(actual.y, original.y, accuracy: 0.0001)
        view.zoom(by: 1 / 1.6, around: anchor)
        XCTAssertEqual(view.viewPoint(for: original).x, anchor.x, accuracy: 0.0001)
        XCTAssertEqual(view.viewPoint(for: original).y, anchor.y, accuracy: 0.0001)
    }

    @MainActor
    func testViewportChangesPreserveExportBytesAndDocumentState() throws {
        let canvas = try makeCanvas(width: 320, height: 1600)
        canvas.tool = .arrow
        gesture(canvas, from: CGPoint(x: 130, y: 100), to: CGPoint(x: 300, y: 200))
        canvas.tool = .rectangle
        gesture(canvas, from: CGPoint(x: 140, y: 280), to: CGPoint(x: 330, y: 350))
        let id = canvas.documentStateID
        let original = try canvas.renderPNGData()
        for mode: ScreenshotViewportMode in [.fit, .actualPixels, .manual(3), .fitWidth] {
            canvas.setViewportMode(mode)
            canvas.zoomViewport(by: 1.5)
            canvas.layoutSubtreeIfNeeded()
            XCTAssertEqual(canvas.documentStateID, id)
            XCTAssertEqual(try canvas.renderPNGData(), original)
        }
    }

    @MainActor
    func testDrawingAfterZoomUsesSourcePixelCoordinates() throws {
        let canvas = try makeCanvas(width: 320, height: 1600)
        var expected: Data?
        for mode: ScreenshotViewportMode in [.fit, .actualPixels, .fitWidth, .manual(2)] {
            canvas.setViewportMode(mode)
            canvas.tool = .line
            let transform = canvas.viewportTransform
            gesture(canvas, from: transform.viewPoint(for: CGPoint(x: 40, y: 60)),
                    to: transform.viewPoint(for: CGPoint(x: 180, y: 170)))
            let png = try canvas.renderPNGData()
            if let expected { XCTAssertEqual(png, expected) } else { expected = png }
            canvas.undo()
        }
    }

    @MainActor
    func testEditorViewportControlsRemainVisibleAtMinimumWindowWidth() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 4000, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<40 {
            context.setFillColor(NSColor(calibratedRed: row.isMultiple(of: 2) ? 0.12 : 0.2,
                                         green: 0.4, blue: 0.55, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: row * 100, width: 800, height: 98))
        }
        let editor = ScreenshotEditorWindowController(image: try XCTUnwrap(context.makeImage()),
                                                       fileURL: URL(fileURLWithPath: "/tmp/长图示例.png"), preferredScreen: nil)
        defer { editor.closeWithoutConfirmation() }
        let window = try XCTUnwrap(editor.window)
        window.setContentSize(CGSize(width: 820, height: 600))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.bounds.width, 820, accuracy: 1, "Controls must not force a wider window")
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        for title in ["适应窗口", "适应宽度", "100%", "−", "+"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            let rect = root.convert(button.bounds, from: button)
            XCTAssertTrue(root.bounds.contains(rect), "\(title) must remain reachable at 820pt")
        }
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? ScreenshotAnnotationCanvasView }.first)
        XCTAssertEqual(canvas.viewportTransform.mode, .fitWidth)
        XCTAssertGreaterThan(canvas.viewportTransform.drawingRect.height, canvas.bounds.height)
        if let output = ProcessInfo.processInfo.environment["DISPLAY_MONITOR_EDITOR_FIXTURE_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, mode): (String, ScreenshotViewportMode) in [("editor-long-width", .fitWidth), ("editor-long-fit", .fit)] {
                canvas.setViewportMode(mode)
                root.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor
    func testMarkedChineseTextSurvivesZoomResizeToolSwitchAndSaveAttempt() throws {
        let canvas = try makeCanvas(width: 320, height: 600)
        canvas.tool = .text
        gesture(canvas, from: CGPoint(x: 200, y: 200), to: nil)
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ScreenshotInlineTextView }.first)
        text.setMarkedText("han", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        let state = canvas.documentStateID
        canvas.zoomViewport(by: 2)
        canvas.frame.size = CGSize(width: 700, height: 500)
        canvas.layoutSubtreeIfNeeded()
        canvas.tool = .arrow
        canvas.undo()
        text.insertNewline(nil)
        XCTAssertFalse(canvas.commitInlineTextIfNeeded())
        XCTAssertThrowsError(try canvas.renderPNGData())
        XCTAssertEqual(canvas.tool, .text)
        XCTAssertEqual(canvas.documentStateID, state)
        XCTAssertTrue(text.superview === canvas)
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertEqual(text.string, "han")
        text.insertText("汉", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(canvas.commitInlineTextIfNeeded())
        XCTAssertNotEqual(canvas.documentStateID, state)
    }

    @MainActor
    func testBlockedToolClickKeepsToolbarAndMarkedTextConsistent() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 600, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let editor = ScreenshotEditorWindowController(image: try XCTUnwrap(context.makeImage()),
                                                       fileURL: URL(fileURLWithPath: "/tmp/ime-toolbar.png"),
                                                       preferredScreen: nil, initialTool: .text)
        defer { editor.closeWithoutConfirmation() }
        let root = try XCTUnwrap(editor.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(root.subviews.compactMap { $0 as? ScreenshotAnnotationCanvasView }.first)
        gesture(canvas, from: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ScreenshotInlineTextView }.first)
        text.setMarkedText("han", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        let arrow = try XCTUnwrap(buttons.first { $0.toolTip == "箭头" })
        let textButton = try XCTUnwrap(buttons.first { $0.toolTip == "文字" })
        arrow.performClick(nil)
        XCTAssertEqual(editor.currentAnnotationTool, .text)
        XCTAssertEqual(arrow.state, .off)
        XCTAssertEqual(textButton.state, .on)
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertTrue(text.superview === canvas)
    }

    @MainActor
    private func makeCanvas(width: Int, height: Int) throws -> ScreenshotAnnotationCanvasView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let canvas = ScreenshotAnnotationCanvasView(image: try XCTUnwrap(context.makeImage()))
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        return canvas
    }

    @MainActor
    private func gesture(_ canvas: ScreenshotAnnotationCanvasView, from: CGPoint, to: CGPoint?) {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, from))
        if let to {
            canvas.mouseDragged(with: event(.leftMouseDragged, to))
            canvas.mouseUp(with: event(.leftMouseUp, to))
        }
    }
}
