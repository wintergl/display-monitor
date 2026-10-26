import AppKit
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

@MainActor
final class ScreenshotEditorPresentationTests: XCTestCase {
    func testToolbarKeepsAllToolsAndEnablesOnlyApplicableStyles() throws {
        let (editor, _, root) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        let more = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first)
        var tools = Set(buttons.compactMap { button -> String? in
            guard let tip = button.toolTip,
                  let tool = ScreenshotAnnotationTool.allCases.first(where: { $0.rawValue == toolRawValue(for: tip) }) else { return nil }
            return tool.rawValue
        })
        tools.formUnion(more.itemArray.compactMap { $0.representedObject as? String })
        XCTAssertEqual(tools, Set(ScreenshotAnnotationTool.allCases.map(\.rawValue)))
        let color = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == "标注颜色" })
        let width = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first { $0.toolTip == "线条粗细" })
        for (title, expectedColor, expectedWidth) in [("模糊", false, false), ("打码", false, false), ("裁剪", false, false), ("文字", true, false), ("箭头", true, true)] {
            try XCTUnwrap(buttons.first { $0.toolTip == title }).performClick(nil)
            XCTAssertEqual(color.isEnabled, expectedColor, title)
            XCTAssertEqual(width.isEnabled, expectedWidth, title)
        }
        more.selectItem(withTitle: "椭圆")
        _ = NSApp.sendAction(try XCTUnwrap(more.action), to: more.target, from: more)
        XCTAssertEqual(editor.currentAnnotationTool, .ellipse)
        XCTAssertTrue(color.isEnabled)
        XCTAssertTrue(width.isEnabled)
    }

    func testMinimumWidthKeepsPrimarySaveNavigationAndOutputActionsReachable() throws {
        let (editor, _, root) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        XCTAssertEqual(root.bounds.width, 820, accuracy: 1)
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        for title in ["保存", "复制", "另存为…", "分享", "适应窗口", "适应宽度", "100%"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            XCTAssertTrue(root.bounds.contains(root.convert(button.bounds, from: button)), title)
        }
        for tip in ["回到顶部", "回到底部"] {
            let button = try XCTUnwrap(buttons.first { $0.toolTip == tip })
            XCTAssertTrue(root.bounds.contains(root.convert(button.bounds, from: button)), tip)
        }
        let save = try XCTUnwrap(buttons.first { $0.title == "保存" })
        let copy = try XCTUnwrap(buttons.first { $0.title == "复制" })
        XCTAssertGreaterThan(root.convert(save.bounds, from: save).midY, root.convert(copy.bounds, from: copy).midY)
    }

    func testLongImageNavigatorChangesOnlyTheViewportAndTracksModeSelection() throws {
        let (editor, canvas, root) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        let stateID = canvas.documentStateID
        let png = try canvas.renderPNGData()
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        let width = try XCTUnwrap(buttons.first { $0.title == "适应宽度" })
        let fit = try XCTUnwrap(buttons.first { $0.title == "适应窗口" })
        let top = try XCTUnwrap(buttons.first { $0.toolTip == "回到顶部" })
        let bottom = try XCTUnwrap(buttons.first { $0.toolTip == "回到底部" })
        let scroller = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScroller }.first)
        XCTAssertEqual(width.state, .on)
        XCTAssertTrue(scroller.isEnabled)
        let knob = scroller.rect(for: .knob)
        XCTAssertGreaterThan(knob.height, knob.width, "The native scroller must have a usable vertical thumb")
        XCTAssertGreaterThan(knob.height, 0)
        XCTAssertFalse(top.isEnabled)
        bottom.performClick(nil)
        XCTAssertEqual(scroller.doubleValue, 1, accuracy: 0.0001)
        XCTAssertFalse(bottom.isEnabled)
        XCTAssertTrue(top.isEnabled)
        scroller.doubleValue = 0.45
        _ = NSApp.sendAction(try XCTUnwrap(scroller.action), to: scroller.target, from: scroller)
        XCTAssertEqual(ScreenshotEditorNavigationState(transform: canvas.viewportTransform).position, 0.45, accuracy: 0.0001)
        top.performClick(nil)
        XCTAssertEqual(scroller.doubleValue, 0, accuracy: 0.0001)
        fit.performClick(nil)
        XCTAssertEqual(fit.state, .on)
        XCTAssertEqual(width.state, .off)
        XCTAssertTrue(scroller.isHidden)
        canvas.zoomViewport(by: 2)
        XCTAssertEqual(fit.state, .off)
        XCTAssertEqual(canvas.documentStateID, stateID)
        XCTAssertEqual(try canvas.renderPNGData(), png)
    }

    func testNavigationRetainsTheSameMarkedChineseTextView() throws {
        let (editor, canvas, root) = try makeEditor(initialTool: .text)
        defer { editor.closeWithoutConfirmation() }
        canvas.mouseDown(with: try event(at: CGPoint(x: canvas.bounds.midX, y: 100), in: canvas))
        let text = try XCTUnwrap(canvas.subviews.compactMap { $0 as? ScreenshotInlineTextView }.first)
        text.setMarkedText("han", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let stateID = canvas.documentStateID
        let bottom = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.toolTip == "回到底部" })
        bottom.performClick(nil)
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(text.superview === canvas)
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertEqual(text.string, "han")
        XCTAssertEqual(canvas.documentStateID, stateID)
    }

    func testSaveReceiptPresentationSurvivesToolChangesAndModifiedFlagIsAccurate() async throws {
        let (editor, canvas, root) = try makeEditor()
        defer { editor.closeWithoutConfirmation() }
        canvas.tool = .counter
        canvas.mouseDown(with: try event(at: CGPoint(x: 100, y: 100), in: canvas))
        XCTAssertTrue(editor.window?.isDocumentEdited == true)
        XCTAssertTrue(editor.window?.title.contains("320 × 1600") == true)
        let label = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "editor.save-status" })
        editor.onSaveRevision = { _ in throw RevisionSaveError.unavailable }
        let failed = await editor.saveRevision()
        XCTAssertFalse(failed)
        XCTAssertTrue(label.stringValue.contains("保存失败"))
        let failureText = label.stringValue
        try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.toolTip == "选择" }).performClick(nil)
        XCTAssertEqual(label.stringValue, failureText)
        let url = URL(fileURLWithPath: "/tmp/presentation-confirmed.png")
        editor.onSaveRevision = { _ in ArtifactManifest(id: UUID(), kind: .revision, status: .completed,
            canonicalURL: url, temporaryURL: url, originOperationID: UUID(), activeOperationID: UUID()) }
        editor.onExportRevision = { _, _ in }
        let destination = URL(fileURLWithPath: "/tmp/演示副本.png")
        let succeeded = await editor.saveRevision(exportURL: destination)
        XCTAssertTrue(succeeded)
        XCTAssertFalse(editor.window?.isDocumentEdited ?? true)
        XCTAssertTrue(label.stringValue.contains("演示副本.png"))
        XCTAssertEqual(label.toolTip, destination.path)
        try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.toolTip == "箭头" }).performClick(nil)
        XCTAssertTrue(label.stringValue.contains("演示副本.png"))
    }

    func testWindowPlacementCascadesAndStaysOnNegativeOriginAndSmallScreens() {
        for visible in [CGRect(x: -1600, y: 80, width: 1600, height: 900), CGRect(x: 400, y: -300, width: 760, height: 460)] {
            let first = ScreenshotEditorWindowPlacement.frame(size: CGSize(width: 1280, height: 848), visibleFrame: visible, previousFrame: nil)
            XCTAssertTrue(visible.contains(first))
            let next = ScreenshotEditorWindowPlacement.frame(size: CGSize(width: 820, height: 500), visibleFrame: visible, previousFrame: first)
            XCTAssertTrue(visible.contains(next))
            if visible.width > next.width && visible.height > next.height { XCTAssertNotEqual(first.origin, next.origin) }
        }
    }

    func testNavigationGeometryPreservesHorizontalPanAndCropCoordinates() {
        var transform = ScreenshotViewportTransform(cropRect: CGRect(x: 300, y: 700, width: 2000, height: 50_000),
            viewport: CGRect(x: 24, y: 24, width: 800, height: 600), backingScale: 2, mode: .actualPixels)
        transform.move(by: CGSize(width: -120, height: -80))
        let bottom = ScreenshotEditorNavigationState.scrolled(transform, to: 1)
        XCTAssertEqual(bottom.pan.width, transform.pan.width)
        XCTAssertEqual(bottom.cropRect, transform.cropRect)
        XCTAssertEqual(bottom.drawingRect.maxY, bottom.viewport.maxY)
        XCTAssertEqual(ScreenshotEditorNavigationState(transform: bottom).visibleEndPercent, 100)
        XCTAssertEqual(ScreenshotEditorNavigationState.scrolled(transform, to: .nan), transform)
    }

    private func makeEditor(initialTool: ScreenshotAnnotationTool = .arrow) throws -> (ScreenshotEditorWindowController, ScreenshotAnnotationCanvasView, NSView) {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 1600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let editor = ScreenshotEditorWindowController(image: try XCTUnwrap(context.makeImage()),
            fileURL: URL(fileURLWithPath: "/tmp/presentation-fixture.png"), preferredScreen: nil, initialTool: initialTool)
        editor.window?.setContentSize(CGSize(width: 820, height: 600))
        let root = try XCTUnwrap(editor.window?.contentView)
        root.layoutSubtreeIfNeeded()
        return (editor, try XCTUnwrap(root.subviews.compactMap { $0 as? ScreenshotAnnotationCanvasView }.first), root)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func event(at point: CGPoint, in canvas: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func toolRawValue(for title: String) -> String? {
        ["选择": "select", "箭头": "arrow", "矩形": "rectangle", "文字": "text", "模糊": "blur", "打码": "pixelate", "裁剪": "crop"][title]
    }
}
