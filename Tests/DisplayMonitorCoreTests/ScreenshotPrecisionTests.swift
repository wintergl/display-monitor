import AppKit
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

final class ScreenshotPrecisionTests: XCTestCase {
    func testRetinaArrowMovementUsesImagePixelsAndAppKitYAxis() {
        let original = SelectionGeometry(
            displayBounds: CGRect(x: -1_920, y: -900, width: 1_920, height: 1_080),
            rect: CGRect(x: -1_600, y: -500, width: 400, height: 200)
        )
        let up = adjusted(original, .up)
        XCTAssertEqual(up.rect.minY, -499.5)
        XCTAssertEqual(adjusted(up, .down).rect, original.rect)
        XCTAssertEqual(adjusted(original, .left, accelerated: true).rect.minX, -1_605)
        XCTAssertEqual(adjusted(original, .right, scale: 1).rect.minX, -1_599)
        XCTAssertEqual(original.rect, CGRect(x: -1_600, y: -500, width: 400, height: 200))
    }

    func testOptionArrowResizesRightAndBottomWithTopLeftFixed() {
        let original = SelectionGeometry(
            displayBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            rect: CGRect(x: 100, y: 200, width: 400, height: 300)
        )
        let smaller = adjusted(original, .up, resize: true)
        XCTAssertEqual(smaller.rect.height, 299.5)
        XCTAssertEqual(smaller.rect.minY, 200.5)
        XCTAssertEqual(smaller.rect.maxY, original.rect.maxY)
        XCTAssertEqual(smaller.rect.minX, original.rect.minX)
        XCTAssertEqual(adjusted(smaller, .down, resize: true).rect, original.rect)
        let wider = adjusted(original, .right, accelerated: true, resize: true)
        XCTAssertEqual(wider.rect.width, 405)
        XCTAssertEqual(wider.rect.minX, original.rect.minX)
        XCTAssertEqual(adjusted(original, .left, resize: true).rect.width, 399.5)
    }

    func testNudgingClampsAtBoundsAndNeverCrossesMinimumSize() {
        let atBounds = SelectionGeometry(
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 84, y: 0, width: 16, height: 16)
        )
        XCTAssertEqual(adjusted(atBounds, .right).rect, atBounds.rect)
        XCTAssertEqual(adjusted(atBounds, .down).rect, atBounds.rect)
        XCTAssertEqual(adjusted(atBounds, .left, accelerated: true, resize: true).rect, atBounds.rect)
        XCTAssertEqual(adjusted(atBounds, .up, accelerated: true, resize: true).rect, atBounds.rect)
        XCTAssertEqual(adjusted(atBounds, .right, accelerated: true, resize: true).rect, atBounds.rect)
        XCTAssertEqual(adjusted(atBounds, .up, scale: .nan).rect, atBounds.rect)
    }

    func testMagnifierMapsFrozenPixelsToTopLeftAndClampsEdges() throws {
        let display = CGRect(x: -400, y: 100, width: 400, height: 300)
        let image = CGSize(width: 800, height: 600)
        XCTAssertEqual(
            ScreenshotPrecisionGeometry.imagePixel(at: CGPoint(x: -350, y: 350), in: display, imageSize: image),
            CGPoint(x: 100, y: 100)
        )
        XCTAssertEqual(
            ScreenshotPrecisionGeometry.imagePixel(at: CGPoint(x: 0, y: 100), in: display, imageSize: image),
            CGPoint(x: 799, y: 599)
        )
        let top = try XCTUnwrap(ScreenshotPrecisionGeometry.magnifierSampleRect(
            at: CGPoint(x: -400, y: 400), in: display, imageSize: image
        ))
        XCTAssertEqual(top, CGRect(x: 0, y: 0, width: 29, height: 29))
        let bottom = try XCTUnwrap(ScreenshotPrecisionGeometry.magnifierSampleRect(
            at: CGPoint(x: 0, y: 100), in: display, imageSize: image
        ))
        XCTAssertEqual(bottom, CGRect(x: 771, y: 571, width: 29, height: 29))
        let tiny = try XCTUnwrap(ScreenshotPrecisionGeometry.magnifierSampleRect(
            at: .zero, in: CGRect(x: 0, y: 0, width: 4, height: 3), imageSize: CGSize(width: 8, height: 6)
        ))
        XCTAssertEqual(tiny, CGRect(x: 0, y: 0, width: 8, height: 6))
    }

    @MainActor
    func testSelectionViewUsesActualFrozenScaleForKeyboardAdjustment() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2_200, height: 1_400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        // Nominal 1x deliberately differs from the actual 2x frozen bitmap.
        let root = ScreenshotSelectionVisualFixture.makeView(frozenImage: image, pixelScale: 1)
        let selection = try XCTUnwrap(root.subviews.first)
        selection.keyDown(with: try key(126))
        XCTAssertEqual(try XCTUnwrap(ScreenshotSelectionVisualFixture.selection(in: root)).minY, 170.5)
        selection.keyDown(with: try key(123, modifiers: .shift))
        XCTAssertEqual(try XCTUnwrap(ScreenshotSelectionVisualFixture.selection(in: root)).minX, 175)
        let before = try XCTUnwrap(ScreenshotSelectionVisualFixture.selection(in: root))
        selection.keyDown(with: try key(126, modifiers: .option))
        let resized = try XCTUnwrap(ScreenshotSelectionVisualFixture.selection(in: root))
        XCTAssertEqual(resized.height, before.height - 0.5)
        XCTAssertEqual(resized.maxY, before.maxY)
        // Rendering also traverses the bounded magnifier path after a nudge.
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).count, 0)
    }

    private func adjusted(
        _ geometry: SelectionGeometry,
        _ direction: ScreenshotNudgeDirection,
        scale: CGFloat = 2,
        accelerated: Bool = false,
        resize: Bool = false
    ) -> SelectionGeometry {
        ScreenshotPrecisionGeometry.adjusted(
            geometry, direction: direction, pixelScale: CGSize(width: scale, height: scale),
            accelerated: accelerated, resize: resize
        )
    }

    @MainActor
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        ))
    }
}
