import AppKit
import Darwin
import DisplayMonitorCore
import Foundation
import ImageIO
import XCTest

@testable import DisplayMonitor

@MainActor
final class ScreenshotDocumentRendererTests: XCTestCase {
    func testBackgroundRenderingPreservesNonzeroCropOrientationAndTransparency() async throws {
        _ = NSApplication.shared
        let source = try makeSource()
        let crop = CGRect(x: 17, y: 29, width: 160, height: 240)
        let snapshot = ScreenshotRenderSnapshot(source: source, stateID: UUID(), cropRect: crop, annotations: [])
        let originalBytes = try providerBytes(source)
        let full = try await backgroundFullBitmap(snapshot)
        let expected = try normalizedPixels(XCTUnwrap(source.cropping(to: crop)))
        XCTAssertEqual(full.width, 160)
        XCTAssertEqual(full.height, 240)
        assertPixels(full.pixels, equalTo: expected, width: 160, tolerance: 1, label: "original cropped pixels")
        for halo in [0, 2, 11] {
            let tiled = try await backgroundTiled(snapshot, bandHeight: 7, halo: halo)
            XCTAssertEqual(tiled.width, full.width)
            XCTAssertEqual(tiled.height, full.height)
            assertPixels(tiled.pixels, equalTo: full.pixels, width: 160, tolerance: 1, label: "base image halo=\(halo)")
        }
        // The pattern deliberately distinguishes top/bottom, left/right and
        // partial alpha. A flipped/scaled raster cannot accidentally pass.
        XCTAssertNotEqual(Array(full.pixels[0..<4]), Array(full.pixels[(239 * 160 * 4)..<(239 * 160 * 4 + 4)]))
        XCTAssertTrue(stride(from: 3, to: full.pixels.count, by: 4).contains { full.pixels[$0] > 0 && full.pixels[$0] < 255 })
        XCTAssertEqual(try providerBytes(source), originalBytes)
        XCTAssertEqual(snapshot.cropRect, crop)
        XCTAssertTrue(snapshot.annotations.isEmpty)
    }

    func testEveryAnnotationKindMatchesCompleteBitmapAcrossSmallBands() async throws {
        _ = NSApplication.shared
        let source = try makeSource()
        let originalBytes = try providerBytes(source)
        let crop = CGRect(x: 17, y: 29, width: 160, height: 240)
        let kinds = annotationKinds()
        // ScreenshotAnnotationKind currently has 12 cases; crop is document
        // state rather than an annotation node. Keep every case in this table.
        XCTAssertEqual(kinds.count, 12)
        for (index, entry) in kinds.enumerated() {
            let node = makeNode(entry.kind, index: index)
            let stateID = UUID()
            let snapshot = ScreenshotRenderSnapshot(source: source, stateID: stateID, cropRect: crop, annotations: [node])
            let originalAnnotations = annotationFingerprint(snapshot.annotations)
            let full = try await backgroundFullBitmap(snapshot)
            let halo = index % 3 == 0 ? 0 : (index % 3 == 1 ? 2 : 9)
            let tiled = try await backgroundTiled(snapshot, bandHeight: 7, halo: halo)
            XCTAssertEqual(tiled.width, full.width)
            XCTAssertEqual(tiled.height, full.height)
            assertPixels(tiled.pixels, equalTo: full.pixels, width: 160, tolerance: 1,
                         label: "\(entry.name), halo=\(halo), bandHeight=7")
            XCTAssertEqual(snapshot.stateID, stateID)
            XCTAssertEqual(snapshot.cropRect, crop)
            XCTAssertEqual(snapshot.annotations.map(\.id), [node.id])
            XCTAssertEqual(snapshot.annotations.first?.lineWidth, node.lineWidth)
            XCTAssertEqual(snapshot.annotations.first?.fontSize, node.fontSize)
            XCTAssertEqual(annotationFingerprint(snapshot.annotations), originalAnnotations)
        }
        XCTAssertEqual(try providerBytes(source), originalBytes)
    }

    func testCombinedAnnotationsFiltersAndSpotlightRemainSeamlessForArbitraryHalos() async throws {
        _ = NSApplication.shared
        let source = try makeSource()
        let originalBytes = try providerBytes(source)
        let nodes = annotationKinds().enumerated().map { makeNode($0.element.kind, index: $0.offset) }
        let crop = CGRect(x: 17, y: 29, width: 160, height: 240)
        let stateID = UUID()
        let snapshot = ScreenshotRenderSnapshot(source: source, stateID: stateID, cropRect: crop, annotations: nodes)
        let originalAnnotations = annotationFingerprint(snapshot.annotations)
        let full = try await backgroundFullBitmap(snapshot)
        for (bandHeight, halo) in [(1, 0), (7, 2), (13, 9)] {
            let tiled = try await backgroundTiled(snapshot, bandHeight: bandHeight, halo: halo)
            assertPixels(tiled.pixels, equalTo: full.pixels, width: 160, tolerance: 1,
                         label: "all annotations, bandHeight=\(bandHeight), halo=\(halo)")
        }
        XCTAssertEqual(snapshot.stateID, stateID)
        XCTAssertEqual(snapshot.cropRect, crop)
        XCTAssertEqual(snapshot.annotations.map(\.id), nodes.map(\.id))
        XCTAssertEqual(annotationFingerprint(snapshot.annotations), originalAnnotations)
        XCTAssertEqual(try providerBytes(source), originalBytes)
    }

    /// Separates Quartz rasterization at band boundaries from PNG's straight
    /// alpha conversion. A raw failure identifies the renderer; a PNG-only
    /// failure identifies encoding/profile/alpha normalization.
    func testRawBandsPreserveQuartzAntialiasingBeforePNGEncoding() async throws {
        _ = NSApplication.shared
        let source = try makeSource()
        let crop = CGRect(x: 17, y: 29, width: 160, height: 240)
        let focusedKinds = annotationKinds().enumerated().filter {
            ["arrow", "line", "stroke", "highlight"].contains($0.element.name)
        }
        for (index, entry) in focusedKinds {
            let snapshot = ScreenshotRenderSnapshot(source: source, stateID: UUID(), cropRect: crop,
                annotations: [makeNode(entry.kind, index: index)])
            let raw = try await Task.detached(priority: .userInitiated) { @Sendable in
                let renderer = ScreenshotDocumentRenderer(snapshot: snapshot)
                let full = try Self.rawPixels(renderer.renderBand(CGRect(origin: .zero, size: crop.size)))
                var stitched = [UInt8](repeating: 0, count: 160 * 240 * 4)
                for top in stride(from: 0, to: 240, by: 7) {
                    let height = min(7, 240 - top)
                    let band = try Self.rawPixels(renderer.renderBand(CGRect(x: 0, y: top, width: 160, height: height)))
                    stitched.replaceSubrange((top * 160 * 4)..<((top + height) * 160 * 4), with: band)
                }
                return (full, stitched)
            }.value
            assertPixels(raw.1, equalTo: raw.0, width: 160, tolerance: 1,
                         label: "RAW Quartz only: \(entry.name), band=7 halo=0")
            let fullPNG = try await backgroundFullBitmap(snapshot)
            let tiledPNG = try await backgroundTiled(snapshot, bandHeight: 7, halo: 0)
            assertPixels(fullPNG.pixels, equalTo: raw.0, width: 160, tolerance: 1,
                         label: "ImageIO alpha roundtrip only: \(entry.name)")
            assertPixels(tiledPNG.pixels, equalTo: raw.1, width: 160, tolerance: 1,
                         label: "stream alpha roundtrip only: \(entry.name)")
        }
    }

    func testCanonicalGridPreservesXAndYSeamsAndReusesBoundedTiles() async throws {
        _ = NSApplication.shared
        let source = try makeSource(width: 640, height: 320)
        let crop = CGRect(x: 17, y: 29, width: 600, height: 240)
        let nodes: [ScreenshotAnnotationNode] = [
            makeNode(.arrow(start: CGPoint(x: 31, y: 39), end: CGPoint(x: 602, y: 249)), index: 0),
            makeNode(.stroke([CGPoint(x: 33, y: 250), CGPoint(x: 527, y: 151), CGPoint(x: 606, y: 42)]), index: 1),
            makeNode(.text("跨网格 Aa 123", origin: CGPoint(x: 487, y: 147)), index: 2)
        ]
        let snapshot = ScreenshotRenderSnapshot(source: source, stateID: UUID(), cropRect: crop, annotations: nodes)
        let full = try await backgroundFullBitmap(snapshot)
        for (height, halo) in [(7, 0), (31, 3)] {
            let tiled = try await backgroundTiled(snapshot, bandHeight: height, halo: halo)
            assertPixels(tiled.pixels, equalTo: full.pixels, width: 600, tolerance: 1,
                         label: "canonical X/Y seams, band=\(height) halo=\(halo)")
        }
        let reuse = try await Task.detached(priority: .userInitiated) { @Sendable in
            let renderer = ScreenshotDocumentRenderer(snapshot: snapshot)
            _ = try renderer.renderBand(CGRect(x: 0, y: 10, width: 600, height: 7))
            let first = renderer.canonicalTileRenderCount
            _ = try renderer.renderBand(CGRect(x: 0, y: 17, width: 600, height: 7))
            return (first, renderer.canonicalTileRenderCount, renderer.canonicalCachedBytes)
        }.value
        XCTAssertEqual(reuse.0, 2)
        XCTAssertEqual(reuse.1, reuse.0, "adjacent arbitrary export bands reuse identical canonical raster tiles")
        XCTAssertLessThanOrEqual(reuse.2, ScreenshotCanonicalRasterGrid.cacheByteLimit)
    }

    /// Both PNG strategies share the canonical grid. This independent full
    /// surface reference prevents that shared grid from hiding filter seams.
    func testCanonicalFiltersMatchSingleSurfaceWithoutGridSeams() async throws {
        _ = NSApplication.shared
        let source = try makeSource(width: 640, height: 320)
        let crop = CGRect(x: 17, y: 29, width: 600, height: 240)
        let kinds: [(String, ScreenshotAnnotationKind)] = [
            ("blur", .blur(CGRect(x: 24, y: 38, width: 584, height: 220), radius: 9)),
            ("pixelate", .pixelate(CGRect(x: 24, y: 38, width: 584, height: 220), scale: 13))
        ]
        for (name, kind) in kinds {
            let snapshot = ScreenshotRenderSnapshot(source: source, stateID: UUID(), cropRect: crop,
                annotations: [makeNode(kind, index: 0)])
            let result = try await Task.detached(priority: .userInitiated) { @Sendable in
                let expected = try Self.singleSurfacePixels(snapshot)
                let actual = try Self.rawPixels(ScreenshotDocumentRenderer(snapshot: snapshot).renderBand(
                    CGRect(origin: .zero, size: crop.size)))
                return (expected, actual)
            }.value
            assertPixels(result.1, equalTo: result.0, width: 600, tolerance: 1,
                         label: "\(name) canonical grid versus independent single surface")
        }
    }

    private struct Decoded: Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private func backgroundFullBitmap(_ snapshot: ScreenshotRenderSnapshot) async throws -> Decoded {
        let result = try await Task.detached(priority: .userInitiated) { @Sendable in
            let wasMainThread = pthread_main_np() != 0
            let data = try ScreenshotDocumentRenderer(snapshot: snapshot).pngData(strategy: .fullBitmap)
            return (wasMainThread, data)
        }.value
        XCTAssertFalse(result.0, "The actual AppKit/CoreImage render must run on a background worker")
        return try decode(result.1)
    }

    private func backgroundTiled(_ snapshot: ScreenshotRenderSnapshot, bandHeight: Int, halo: Int) async throws -> Decoded {
        let width = Int(snapshot.cropRect.width)
        // Force narrow bands without allocating a huge fixture. The production
        // planner accounts for six RGBA surfaces and the shared fixed scratch reserve.
        let budget = ScreenshotTiledRasterPlan.fixedWorkingReserveBytes + width * 24 * (bandHeight + 2 * halo)
        let result = try await Task.detached(priority: .userInitiated) { @Sendable in
            let wasMainThread = pthread_main_np() != 0
            let data = try ScreenshotDocumentRenderer(snapshot: snapshot).pngData(
                strategy: .tiled(maximumWorkingBytes: budget, haloRows: halo)
            )
            return (wasMainThread, data)
        }.value
        XCTAssertFalse(result.0)
        return try decode(result.1)
    }

    private func decode(_ data: Data) throws -> Decoded {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
        return Decoded(width: image.width, height: image.height, pixels: try normalizedPixels(image))
    }

    private func normalizedPixels(_ image: CGImage) throws -> [UInt8] {
        try Self.rawPixels(image)
    }

    nonisolated private static func rawPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let raw = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: raw, count: image.width * image.height * 4))
    }

    nonisolated private static func singleSurfacePixels(_ snapshot: ScreenshotRenderSnapshot) throws -> [UInt8] {
        let width = Int(snapshot.cropRect.width), height = Int(snapshot.cropRect.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(snapshot.source.cropping(to: snapshot.cropRect)),
            in: CGRect(origin: .zero, size: snapshot.cropRect.size))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        try ScreenshotDocumentRenderer(snapshot: snapshot).draw(nodes: snapshot.annotations,
            mapping: ScreenshotRenderMapping(cropRect: snapshot.cropRect,
                destinationRect: CGRect(origin: .zero, size: snapshot.cropRect.size), isFlippedSurface: false),
            visibleSourceRect: snapshot.cropRect)
        return try rawPixels(XCTUnwrap(context.makeImage()))
    }

    private func assertPixels(_ actual: [UInt8], equalTo expected: [UInt8], width: Int, tolerance: Int,
                              label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, label, file: file, line: line)
        guard actual.count == expected.count else { return }
        var maximumDifference = 0
        var mismatchCount = 0
        var examples: [String] = []
        for offset in actual.indices {
            let difference = abs(Int(actual[offset]) - Int(expected[offset]))
            maximumDifference = max(maximumDifference, difference)
            if difference > tolerance {
                mismatchCount += 1
                if examples.count < 6 {
                    let pixel = offset / 4
                    examples.append("(\(pixel % width),\(pixel / width)) channel=\(offset % 4) expected=\(expected[offset]) actual=\(actual[offset])")
                }
            }
        }
        XCTAssertLessThanOrEqual(maximumDifference, tolerance,
            "\(label): max channel difference=\(maximumDifference), mismatches=\(mismatchCount); \(examples.joined(separator: "; "))",
            file: file, line: line)
    }

    private func makeSource(width: Int = 220, height: Int = 320) throws -> CGImage {
        var bytes = Data(repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = [0, 64, 128, 192, 255][(x / 11 + y / 13) % 5]
                bytes[offset] = UInt8(((x * 17 + y * 3) % 256) * alpha / 255)
                bytes[offset + 1] = UInt8(((y * 7 + x / 3) % 256) * alpha / 255)
                bytes[offset + 2] = UInt8(((x * 5 + y * 11) % 256) * alpha / 255)
                bytes[offset + 3] = UInt8(alpha)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func providerBytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(try XCTUnwrap(image.dataProvider).data) as Data
    }

    private func makeNode(_ kind: ScreenshotAnnotationKind, index: Int) -> ScreenshotAnnotationNode {
        ScreenshotAnnotationNode(id: UUID(), kind: kind,
            color: NSColor(srgbRed: 0.88, green: 0.18, blue: 0.32, alpha: index % 2 == 0 ? 1 : 0.73),
            lineWidth: 3.5, fontSize: 19)
    }

    private func annotationFingerprint(_ nodes: [ScreenshotAnnotationNode]) -> [String] {
        nodes.map { "\($0.id)|\($0.kind)|\($0.color)|\($0.lineWidth)|\($0.fontSize)" }
    }

    private func annotationKinds() -> [(name: String, kind: ScreenshotAnnotationKind)] {
        [
            ("arrow", .arrow(start: CGPoint(x: 23, y: 35), end: CGPoint(x: 164, y: 249))),
            ("line", .line(start: CGPoint(x: 22, y: 247), end: CGPoint(x: 173, y: 41))),
            ("rectangle", .rectangle(CGRect(x: 33, y: 47, width: 116, height: 182))),
            ("filledRectangle", .filledRectangle(CGRect(x: 41, y: 52, width: 97, height: 164))),
            ("ellipse", .ellipse(CGRect(x: 38, y: 45, width: 123, height: 197))),
            ("stroke", .stroke([CGPoint(x: 29, y: 35), CGPoint(x: 129, y: 88), CGPoint(x: 58, y: 151), CGPoint(x: 168, y: 251)])),
            ("highlight", .highlight([CGPoint(x: 25, y: 38), CGPoint(x: 144, y: 93), CGPoint(x: 37, y: 175), CGPoint(x: 159, y: 247)])),
            ("text", .text("跨带文字 Aa 123", origin: CGPoint(x: 28, y: 83))),
            ("blur", .blur(CGRect(x: 31, y: 42, width: 132, height: 203), radius: 9)),
            ("pixelate", .pixelate(CGRect(x: 26, y: 50, width: 147, height: 211), scale: 13)),
            ("spotlight", .spotlight(CGRect(x: 43, y: 63, width: 104, height: 169))),
            ("counter", .counter(12, center: CGPoint(x: 99, y: 151)))
        ]
    }
}
