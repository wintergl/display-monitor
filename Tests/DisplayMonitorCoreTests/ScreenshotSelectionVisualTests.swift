import AppKit
import DisplayMonitorCore
import XCTest

@testable import DisplayMonitor

final class ScreenshotSelectionVisualTests: XCTestCase {
    func testFrozenCropGeometryUsesActualPixelSizeAndTopLeftOrigin() throws {
        let cropRect = try XCTUnwrap(
            FrozenScreenshotGeometry.cropRect(
                imageSize: CGSize(width: 2_880, height: 1_800),
                displayFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
                selectionRect: CGRect(x: -1_200, y: 140, width: 640, height: 360)
            )
        )

        XCTAssertEqual(cropRect, CGRect(x: 480, y: 800, width: 1_280, height: 720))
    }

    func testFrozenFrameCropsTheSelectedRegionWithoutRecapturing() throws {
        let image = try makeSolidImage(width: 800, height: 600)
        let frame = FrozenScreenshotFrame(
            displayID: 7,
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            image: image
        )
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: frame.displayFrame,
            selectionRect: CGRect(x: 50, y: 100, width: 200, height: 120),
            pixelScale: 2
        )

        let cropped = try XCTUnwrap(frame.croppedImage(for: region))
        XCTAssertEqual(cropped.width, 400)
        XCTAssertEqual(cropped.height, 240)
    }

    func testFrozenFrameMapsAppKitTopHalfToTheFirstImageRows() throws {
        let image = try makeTopBottomImage(width: 8, height: 6)
        let displayFrame = CGRect(x: 0, y: 0, width: 4, height: 3)
        let frame = FrozenScreenshotFrame(displayID: 9, displayFrame: displayFrame, image: image)
        let topHalf = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: displayFrame,
            selectionRect: CGRect(x: 0, y: 1.5, width: 4, height: 1.5),
            pixelScale: 2
        )

        let cropped = try XCTUnwrap(frame.croppedImage(for: topHalf))
        let average = averageColor(of: cropped)
        XCTAssertGreaterThan(average.red, 0.90)
        XCTAssertLessThan(average.blue, 0.10)
    }

    @MainActor
    func testCompletedSelectionRendersUnifiedActionBarAndSelectionChrome() throws {
        let view = ScreenshotSelectionVisualFixture.makeView()
        let buttons = descendants(of: view).compactMap { $0 as? NSButton }
        let orderedButtons = buttons.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(
            orderedButtons.compactMap(\.toolTip),
            ["截图", "滚动截图", "区域录屏", "截图并固定到桌面"]
        )
        XCTAssertTrue(buttons.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertTrue(buttons.allSatisfy { $0.image != nil })
        XCTAssertTrue(buttons.allSatisfy { !$0.allowsVibrancy })
        XCTAssertTrue(buttons.allSatisfy { $0.title.isEmpty })
        XCTAssertTrue(buttons.allSatisfy { $0.imagePosition == .imageOnly })
        XCTAssertTrue(buttons.allSatisfy { $0.alignment == .center })
        XCTAssertTrue(buttons.allSatisfy { $0.frame.size == CGSize(width: 36, height: 36) })
        let scrollButton = try XCTUnwrap(buttons.first { $0.toolTip == "滚动截图" })
        XCTAssertEqual(scrollButton.image?.size, CGSize(width: 18, height: 18))
        XCTAssertTrue(scrollButton.image?.isTemplate == true)

        let actionBar = try XCTUnwrap(buttons.first?.superview)
        XCTAssertEqual(actionBar.frame.width, 158, accuracy: 0.01)
        XCTAssertEqual(actionBar.frame.height, 44, accuracy: 0.01)
        XCTAssertGreaterThan(actionBar.frame.minY, 8)
        XCTAssertEqual(
            actionBar.frame.midX,
            ScreenshotSelectionVisualFixture.selectionRect.midX,
            accuracy: 0.01
        )

        for button in buttons {
            button.updateLayer()
            let color = try XCTUnwrap(
                button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
            )
            XCTAssertLessThanOrEqual(color.alphaComponent, 0.01)
        }

        let png = try renderPNG(of: view)
        XCTAssertFalse(png.isEmpty)
        if let outputPath = ProcessInfo.processInfo.environment[
            "DISPLAY_MONITOR_SELECTION_FIXTURE_DIR"
        ] {
            let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try png.write(to: outputDirectory.appendingPathComponent("selection-toolbar.png"))
        }
    }

    @MainActor
    func testFrozenSelectionRendersCapturedFrameBehindSelectionChrome() throws {
        let frozenImage = try makeSolidImage(width: 1_100, height: 700)
        let liveView = ScreenshotSelectionVisualFixture.makeView()
        let frozenView = ScreenshotSelectionVisualFixture.makeView(frozenImage: frozenImage)

        let livePNG = try renderPNG(of: liveView)
        let frozenPNG = try renderPNG(of: frozenView)
        XCTAssertNotEqual(livePNG, frozenPNG)
        if let outputPath = ProcessInfo.processInfo.environment[
            "DISPLAY_MONITOR_SELECTION_FIXTURE_DIR"
        ] {
            let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try frozenPNG.write(to: outputDirectory.appendingPathComponent("selection-frozen.png"))
        }
    }

    @MainActor
    private func renderPNG(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.10, green: 0.48, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTopBottomImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                pixels[index] = row < height / 2 ? 255 : 0
                pixels[index + 1] = 0
                pixels[index + 2] = row < height / 2 ? 0 : 255
                pixels[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func averageColor(of image: CGImage) -> (red: Double, blue: Double) {
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let pixelCount = image.width * image.height
        var red = 0
        var blue = 0
        for pixel in 0..<pixelCount {
            red += Int(bytes[pixel * 4])
            blue += Int(bytes[pixel * 4 + 2])
        }
        return (
            red: Double(red) / Double(pixelCount * 255),
            blue: Double(blue) / Double(pixelCount * 255)
        )
    }
}
