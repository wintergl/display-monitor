import AppKit
import DisplayMonitorCore
import ImageIO
import XCTest
@testable import DisplayMonitor

@MainActor
final class ScreenshotAnnotationScaleRenderingTests: XCTestCase {
    func testQuarterSizeTextPreviewUsesSourceGlyphSize() throws {
        let canvas = try makeCanvas()
        canvas.addText("MMMMMMMM", at: CGPoint(x: 500, y: 400))
        try assertQuarterScale(canvas, fixtureName: "text")
    }

    func testQuarterSizeArrowPreviewScalesItsHeadWithTheSource() throws {
        let canvas = try makeCanvas()
        canvas.tool = .arrow
        let transform = canvas.viewportTransform
        let start = transform.viewPoint(for: CGPoint(x: 400, y: 500))
        let end = transform.viewPoint(for: CGPoint(x: 1_400, y: 500))
        canvas.mouseDown(with: try event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, in: canvas))
        try assertQuarterScale(canvas, fixtureName: "arrow")
    }

    private func assertQuarterScale(_ canvas: ScreenshotAnnotationCanvasView, fixtureName: String) throws {
        // Remove point-sized selection handles from the measurement: the test
        // measures document marks, whose dimensions must follow source pixels.
        canvas.tool = .select
        let emptyPoint = canvas.viewportTransform.viewPoint(for: CGPoint(x: 100, y: 100))
        canvas.mouseDown(with: try event(.leftMouseDown, at: emptyPoint, in: canvas))
        let sourcePNG = try canvas.renderPNGData()
        let source = try decode(sourcePNG)
        let sourceBounds = try redBounds(in: source)
        XCTAssertGreaterThan(sourceBounds.width, 40)
        let stateID = canvas.documentStateID

        canvas.setViewportMode(.manual(0.25))
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let preview = try XCTUnwrap(bitmap.cgImage)
        let previewBounds = try redBounds(in: preview)
        let backingX = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        let backingY = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        let scale = canvas.viewportTransform.scale
        // Small-font hinting and edge antialiasing may differ by a few output
        // pixels. Fixed 9pt text or a 12pt arrow head exceeds these tolerances.
        XCTAssertEqual(previewBounds.width / backingX, sourceBounds.width * scale, accuracy: 3)
        XCTAssertEqual(previewBounds.height / backingY, sourceBounds.height * scale, accuracy: 2.5)
        XCTAssertEqual(canvas.documentStateID, stateID)
        XCTAssertEqual(try canvas.renderPNGData(), sourcePNG)

        if let directory = ProcessInfo.processInfo.environment["DISPLAY_MONITOR_EDITOR_FIXTURE_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try sourcePNG.write(to: root.appendingPathComponent("synthetic-\(fixtureName)-source.png"))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("synthetic-\(fixtureName)-quarter-preview.png"))
        }
    }

    private func makeCanvas() throws -> ScreenshotAnnotationCanvasView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2_000, height: 1_000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
        let canvas = ScreenshotAnnotationCanvasView(image: try XCTUnwrap(context.makeImage()))
        canvas.annotationColor = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        canvas.setViewportMode(.fit)
        return canvas
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func redBounds(in image: CGImage) throws -> CGRect {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                // A subpixel shaft blends with white and can be pale red.
                // Measure red dominance rather than requiring dark pixels.
                let red = Int(data[index])
                if red > Int(data[index + 1]) + 40, red > Int(data[index + 2]) + 40 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            XCTFail("合成截图中没有找到红色标注")
            throw RevisionSaveError.invalidImage
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
