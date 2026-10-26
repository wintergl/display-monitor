import AppKit
import DisplayMonitorCore
import Foundation
import ImageIO
import XCTest
@testable import DisplayMonitor

@MainActor
final class QuickAccessPresentationTests: XCTestCase {
    func testPrimaryActionsAreVisibleReadableAndDisabledActionsCannotInvokeCallbacks() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.png")
        try writeFixture(width: 320, height: 180, to: url)
        var calls = 0
        let enabled = card(url: url, width: 320, height: 180, enabled: true, action: { calls += 1 })
        enabled.frame = CGRect(origin: .zero, size: QuickAccessContentView.preferredSize)
        await enabled.waitUntilPreviewIsReady()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            enabled.appearance = NSAppearance(named: appearanceName)
            enabled.layoutSubtreeIfNeeded()
            enabled.setHoverActionsVisible(false, animated: false)
            for button in actions(enabled) {
                button.updateLayer()
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertFalse(button.allowsVibrancy)
                XCTAssertEqual(button.accessibilityLabel(), button.title)
                XCTAssertEqual(button.toolTip, button.title)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 27)
                let background = try XCTUnwrap(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
                let label = try XCTUnwrap(descendants(button).compactMap { $0 as? NSTextField }.first)
                XCTAssertGreaterThanOrEqual(try contrast(label.textColor!, background), 4.5,
                    "Primary text must remain readable without active-window vibrancy")
            }
            try writeVisualFixture(enabled, name: appearanceName == .aqua ? "quick-access-actions-light.png" : "quick-access-actions-dark.png")
        }
        for button in actions(enabled) { button.performClick(nil) }
        XCTAssertEqual(calls, 3)
        let disabled = card(url: url, width: 320, height: 180, enabled: false, action: { calls += 1 })
        await disabled.waitUntilPreviewIsReady()
        for button in actions(disabled) {
            XCTAssertFalse(button.isEnabled)
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            button.performClick(nil)
        }
        XCTAssertEqual(calls, 3)
    }

    func testLongPreviewUsesOriginalTopPixelsRatherThanMagnifyingTinyOverview() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("original.png")
        let tiny = directory.appendingPathComponent("old-overview.png")
        try writeFixture(width: 512, height: 4096, to: canonical)
        try writeFixture(width: 4, height: 32, to: tiny, solidPurple: true)
        let originalBytes = try Data(contentsOf: canonical)
        let overviewBytes = try Data(contentsOf: tiny)
        let artifact = manifest(url: canonical, width: 512, height: 4096, preview: tiny)
        let content = QuickAccessContentView(artifact: artifact, allowsFileActions: true, allowsEditing: true,
            onCopy: {}, onEdit: {}, onSave: {}, onClose: {})
        content.frame = CGRect(origin: .zero, size: QuickAccessContentView.preferredSize)
        await content.waitUntilPreviewIsReady()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.previewDidLoad)
        XCTAssertNil(content.previewFailure)
        XCTAssertEqual(content.bounds.size, CGSize(width: 260, height: 228))
        let views = descendants(content).compactMap { $0 as? NSImageView }
        let head = try XCTUnwrap(views.first { $0.identifier?.rawValue == "QuickAccessMainPreview" })
        let strip = try XCTUnwrap(views.first { $0.identifier?.rawValue == "QuickAccessLongOverview" })
        XCTAssertGreaterThan(head.frame.width, 200)
        XCTAssertEqual(strip.frame.width, 24, accuracy: 0.01)
        XCTAssertLessThanOrEqual(try XCTUnwrap(head.image).size.width, 432)
        XCTAssertLessThanOrEqual(try XCTUnwrap(head.image).size.height, 280)
        let cgHead = try XCTUnwrap(head.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sample = try topLeftPixel(cgHead)
        XCTAssertGreaterThan(Int(sample[0]) - Int(sample[2]), 100,
            "The original starts with red detail. The tiny preview is purple and must not be used as the head's source.")
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("4096") && $0.stringValue.contains("长图")
        })
        XCTAssertEqual(try Data(contentsOf: canonical), originalBytes)
        XCTAssertEqual(try Data(contentsOf: tiny), overviewBytes)
        try writeVisualFixture(content, name: "quick-access-long-head.png")
    }

    func testThumbnailWorkerReturnsBoundedHeadAndOverviewWithoutChangingSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("source.png")
        try writeFixture(width: 512, height: 4096, to: canonical)
        let before = try Data(contentsOf: canonical)
        let result = try await Task.detached {
            try QuickAccessThumbnailRenderer.render(canonicalURL: canonical, boundedPreviewURL: nil, isLong: true)
        }.value
        XCTAssertEqual(result.sourceHeadRect.minY, 0)
        XCTAssertEqual(result.sourceHeadRect.width, 512)
        XCTAssertLessThan(result.sourceHeadRect.height, 4096)
        XCTAssertLessThanOrEqual(result.main.width * result.main.height, 432 * 280)
        let overview = try XCTUnwrap(result.overview)
        XCTAssertLessThanOrEqual(overview.width * overview.height, 48 * 280)
        XCTAssertEqual(try Data(contentsOf: canonical), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.png"])
    }

    private func card(url: URL, width: Int, height: Int, enabled: Bool, action: @escaping () -> Void) -> QuickAccessContentView {
        QuickAccessContentView(artifact: manifest(url: url, width: width, height: height),
            allowsFileActions: enabled, allowsEditing: enabled, onCopy: action, onEdit: action, onSave: action, onClose: {})
    }
    private func manifest(url: URL, width: Int, height: Int, preview: URL? = nil) -> ArtifactManifest {
        ArtifactManifest(id: UUID(), kind: height > width * 2 ? .scrollStill : .still,
            status: .completed, canonicalURL: url, temporaryURL: url, previewURL: preview,
            dimensions: PixelSize(width: width, height: height), originOperationID: UUID(), activeOperationID: UUID())
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func actions(_ view: NSView) -> [NSButton] {
        descendants(view).compactMap { $0 as? NSButton }.filter { ["复制", "编辑", "保存"].contains($0.title) }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAccessPresentation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func writeVisualFixture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DISPLAY_MONITOR_VISUAL_FIXTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
    }
    private func writeFixture(width: Int, height: Int, to url: URL, solidPurple: Bool = false) throws {
        var data = Data(repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let pixels = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    pixels[p] = solidPurple ? 180 : (y < 512 ? UInt8(180 + (x / 8 % 2) * 60) : 20)
                    pixels[p + 1] = solidPurple ? 20 : 25
                    pixels[p + 2] = solidPurple ? 180 : (y < 512 ? 20 : 230)
                    pixels[p + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func topLeftPixel(_ image: CGImage) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
    }
    private func contrast(_ foreground: NSColor, _ background: NSColor) throws -> Double {
        func luminance(_ color: NSColor) throws -> Double {
            let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let components: [Double] = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
            let channels: [Double] = components.map { value in
                if value <= 0.04045 { return value / 12.92 }
                return pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = try luminance(foreground), b = try luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
