import AppKit
import CoreImage
import DisplayMonitorCore
import ImageIO

/// An immutable value captured on the main actor. NSColor instances are resolved
/// to a concrete color space before dispatch, never shared as dynamic appearance
/// providers. Each worker owns its own CGContext and CIContext.
struct ScreenshotRenderSnapshot: @unchecked Sendable {
    let source: CGImage
    let stateID: UUID
    let cropRect: CGRect
    let annotations: [ScreenshotAnnotationNode]
    var rasterSource: ScreenshotRasterSource? = nil
}

enum ScreenshotPNGRenderStrategy {
    case automatic
    case fullBitmap
    case tiled(maximumWorkingBytes: Int, haloRows: Int)
}

final class ScreenshotDocumentRenderer {
    private struct RasterTileKey: Hashable { let x: Int; let y: Int }
    private struct RasterTile {
        let image: CGImage
        let coreRect: CGRect
        let byteCount: Int
        var access: UInt64
    }
    private let snapshot: ScreenshotRenderSnapshot
    private let imageSize: CGSize
    private let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    private var rasterTiles: [RasterTileKey: RasterTile] = [:]
    private var rasterAccess: UInt64 = 0
    private(set) var canonicalTileRenderCount = 0
    private(set) var canonicalCachedBytes = 0

    init(snapshot: ScreenshotRenderSnapshot) {
        self.snapshot = snapshot
        imageSize = CGSize(width: snapshot.source.width, height: snapshot.source.height)
    }

    func pngData(strategy: ScreenshotPNGRenderStrategy = .automatic,
                 progress: @Sendable (Double) -> Void = { _ in }) throws -> Data {
        let crop = snapshot.cropRect
        guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.width > 0, crop.height > 0, crop.width <= 120_000, crop.height <= 120_000,
              crop.width * crop.height <= 200_000_000, imageBounds.contains(crop) else {
            throw ScreenshotDocumentRenderError.cannotRender
        }
        let width = Int(snapshot.cropRect.width)
        let height = Int(snapshot.cropRect.height)
        let usesTiling: Bool
        let workingBytes: Int
        let halo: Int
        switch strategy {
        case .automatic:
            usesTiling = max(width, height) > 16_384 || !ScreenshotRasterBudget.permits(width: width, height: height)
            workingBytes = 64 * 1_024 * 1_024
            halo = 2
        case .fullBitmap:
            guard ScreenshotRasterBudget.permits(width: width, height: height) else {
                throw ScreenshotDocumentRenderError.bitmapBudgetExceeded
            }
            usesTiling = false; workingBytes = 64 * 1_024 * 1_024; halo = 0
        case let .tiled(budget, rows): usesTiling = true; workingBytes = budget; halo = rows
        }
        if !usesTiling {
            let image = try renderBand(CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                throw ScreenshotDocumentRenderError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ScreenshotDocumentRenderError.encodingFailed }
            progress(1)
            return data as Data
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-render-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        try ScreenshotTiledPNGExporter.write(width: width, height: height, destination: output,
                                             maximumWorkingBytes: workingBytes, haloRows: halo) { rect in
            try Task.checkCancellation()
            let image = try self.renderBand(rect)
            progress(min(1, rect.maxY / CGFloat(height)))
            return image
        }
        // Keep the completed PNG file-backed through revision persistence.
        // Removing its temporary name does not invalidate the mapped contents.
        return try Data(contentsOf: output, options: .alwaysMapped)
    }

    /// bandRect is relative to the exported crop, in top-left image pixels.
    func renderBand(_ bandRect: CGRect) throws -> CGImage {
        try ScreenshotRasterWorkGate.shared.withPermit {
            defer { snapshot.rasterSource?.releaseReadPages() }
            return try renderBandWithPermit(bandRect)
        }
    }

    private func renderBandWithPermit(_ bandRect: CGRect) throws -> CGImage {
        try Task.checkCancellation()
        let width = Int(bandRect.width), height = Int(bandRect.height)
        let outputBounds = CGRect(origin: .zero, size: snapshot.cropRect.size)
        guard width > 0, height > 0, bandRect == bandRect.integral,
              outputBounds.contains(bandRect),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotDocumentRenderError.cannotRender
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        let firstX = Int(bandRect.minX) / ScreenshotCanonicalRasterGrid.tileWidth
        let lastX = (Int(bandRect.maxX) - 1) / ScreenshotCanonicalRasterGrid.tileWidth
        let firstY = Int(bandRect.minY) / ScreenshotCanonicalRasterGrid.tileHeight
        let lastY = (Int(bandRect.maxY) - 1) / ScreenshotCanonicalRasterGrid.tileHeight
        for y in firstY...lastY {
            for x in firstX...lastX {
                try Task.checkCancellation()
                let tile = try canonicalTile(for: RasterTileKey(x: x, y: y))
                let overlap = tile.coreRect.intersection(bandRect)
                guard !overlap.isNull, !overlap.isEmpty,
                      let piece = tile.image.cropping(to: overlap.offsetBy(dx: -tile.coreRect.minX, dy: -tile.coreRect.minY)) else {
                    throw ScreenshotDocumentRenderError.cannotRender
                }
                context.draw(piece, in: CGRect(x: overlap.minX - bandRect.minX,
                    y: bandRect.maxY - overlap.maxY, width: overlap.width, height: overlap.height))
            }
        }
        guard let result = context.makeImage() else { throw ScreenshotDocumentRenderError.cannotRender }
        return result
    }

    private func canonicalTile(for key: RasterTileKey) throws -> RasterTile {
        rasterAccess &+= 1
        if var tile = rasterTiles[key] {
            tile.access = rasterAccess
            rasterTiles[key] = tile
            return tile
        }
        let outputBounds = CGRect(origin: .zero, size: snapshot.cropRect.size)
        let core = CGRect(x: key.x * ScreenshotCanonicalRasterGrid.tileWidth,
            y: key.y * ScreenshotCanonicalRasterGrid.tileHeight,
            width: ScreenshotCanonicalRasterGrid.tileWidth, height: ScreenshotCanonicalRasterGrid.tileHeight)
            .intersection(outputBounds)
        let halo = CGFloat(ScreenshotCanonicalRasterGrid.halo)
        let expanded = core.insetBy(dx: -halo, dy: -halo).intersection(outputBounds)
        // The grid and halo never depend on the requested band, including for
        // full-bitmap output. This removes clip-dependent Quartz AA drift.
        let rendered = try autoreleasepool { try renderCanonicalTile(expanded) }
        guard let image = rendered.cropping(to: core.offsetBy(dx: -expanded.minX, dy: -expanded.minY)) else {
            throw ScreenshotDocumentRenderError.cannotRender
        }
        // Cropped CGImages may retain the full expanded provider. Account for
        // that provider rather than just the visible core dimensions.
        let bytes = Int(expanded.width) * Int(expanded.height) * 4
        while canonicalCachedBytes + bytes > ScreenshotCanonicalRasterGrid.cacheByteLimit,
              let victim = rasterTiles.min(by: { $0.value.access < $1.value.access })?.key {
            canonicalCachedBytes -= rasterTiles.removeValue(forKey: victim)!.byteCount
        }
        canonicalTileRenderCount += 1
        let tile = RasterTile(image: image, coreRect: core, byteCount: bytes, access: rasterAccess)
        rasterTiles[key] = tile
        canonicalCachedBytes += bytes
        return tile
    }

    /// Rasterizes a fixed global-grid tile, never an export-dependent band.
    /// The source remains immutable; each context/CI output covers this tile.
    private func renderCanonicalTile(_ bandRect: CGRect) throws -> CGImage {
        let width = Int(bandRect.width), height = Int(bandRect.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotDocumentRenderError.cannotRender
        }
        let sourceRect = bandRect.offsetBy(dx: snapshot.cropRect.minX, dy: snapshot.cropRect.minY)
        let raster = try snapshot.rasterSource?.imageForRendering() ?? snapshot.source
        guard let source = raster.cropping(to: sourceRect) else { throw ScreenshotDocumentRenderError.cannotRender }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -bandRect.minX, y: bandRect.maxY - snapshot.cropRect.height)
        let mapping = ScreenshotRenderMapping(cropRect: snapshot.cropRect,
            destinationRect: CGRect(origin: .zero, size: snapshot.cropRect.size),
            isFlippedSurface: false)
        try draw(nodes: snapshot.annotations, mapping: mapping, visibleSourceRect: sourceRect)
        guard let result = context.makeImage() else { throw ScreenshotDocumentRenderError.cannotRender }
        return result
    }

    func draw(nodes: [ScreenshotAnnotationNode], mapping: ScreenshotRenderMapping,
              visibleSourceRect: CGRect, previewScale: CGFloat = 1) throws {
        for node in nodes {
            try draw(node: node, mapping: mapping, visibleSourceRect: visibleSourceRect, previewScale: previewScale)
        }
    }

    private func bounds(of node: ScreenshotAnnotationNode) -> CGRect {
        switch node.kind {
        case let .arrow(start, end), let .line(start, end):
            return Self.nonDegenerate(Self.rect(from: start, to: end))
        case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
             let .blur(rect, _), let .pixelate(rect, _), let .spotlight(rect):
            return Self.nonDegenerate(rect.standardized)
        case let .stroke(points), let .highlight(points):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return Self.nonDegenerate(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        case let .text(text, origin):
            let size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: node.fontSize, weight: .semibold)])
            return Self.nonDegenerate(CGRect(origin: origin, size: size))
        case let .counter(_, center):
            let diameter = max(24, node.fontSize * 1.6)
            return CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
    }

    private func draw(node: ScreenshotAnnotationNode, mapping: ScreenshotRenderMapping, visibleSourceRect: CGRect, previewScale: CGFloat) throws {
        let scale = mapping.scale
        let lineWidth = max(1, node.lineWidth) * scale
        node.color.setStroke()
        node.color.setFill()

        switch node.kind {
        case let .arrow(start, end):
            let mappedStart = mapping.point(start)
            let mappedEnd = mapping.point(end)
            drawLine(from: mappedStart, to: mappedEnd, color: node.color, lineWidth: lineWidth)
            let angle = atan2(mappedEnd.y - mappedStart.y, mappedEnd.x - mappedStart.x)
            let headLength = max(max(1, node.lineWidth) * 4.5, 12) * scale
            let spread: CGFloat = 0.58
            let first = CGPoint(
                x: mappedEnd.x - cos(angle - spread) * headLength,
                y: mappedEnd.y - sin(angle - spread) * headLength
            )
            let second = CGPoint(
                x: mappedEnd.x - cos(angle + spread) * headLength,
                y: mappedEnd.y - sin(angle + spread) * headLength
            )
            let head = NSBezierPath()
            head.move(to: mappedEnd)
            head.line(to: first)
            head.line(to: second)
            head.close()
            node.color.setFill()
            head.fill()

        case let .line(start, end):
            drawLine(
                from: mapping.point(start),
                to: mapping.point(end),
                color: node.color,
                lineWidth: lineWidth
            )

        case let .rectangle(rect):
            let mapped = mapping.rect(rect)
            node.color.setStroke()
            let path = NSBezierPath(roundedRect: mapped, xRadius: lineWidth, yRadius: lineWidth)
            path.lineWidth = lineWidth
            path.stroke()

        case let .filledRectangle(rect):
            let mapped = mapping.rect(rect)
            let path = NSBezierPath(roundedRect: mapped, xRadius: lineWidth, yRadius: lineWidth)
            node.color.withAlphaComponent(0.32).setFill()
            path.fill()
            node.color.withAlphaComponent(0.8).setStroke()
            path.lineWidth = max(1, max(1, node.lineWidth) * 0.65) * scale
            path.stroke()

        case let .ellipse(rect):
            let path = NSBezierPath(ovalIn: mapping.rect(rect))
            node.color.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

        case let .stroke(points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: mapping.point(first))
            for point in points.dropFirst() {
                path.line(to: mapping.point(point))
            }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            node.color.setStroke()
            path.stroke()

        case let .highlight(points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: mapping.point(first))
            for point in points.dropFirst() {
                path.line(to: mapping.point(point))
            }
            path.lineWidth = max(8, node.lineWidth) * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            node.color.withAlphaComponent(0.38).setStroke()
            path.stroke()

        case let .text(text, origin):
            let fontSize = max(9, node.fontSize) * scale
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: node.color
            ]
            let size = text.size(withAttributes: attributes)
            let mapped = mapping.point(origin)
            let drawOrigin = mapping.isFlippedSurface
                ? mapped
                : CGPoint(x: mapped.x, y: mapped.y - size.height)
            let backgroundRect = CGRect(origin: drawOrigin, size: size).insetBy(dx: -5 * scale, dy: -3 * scale)
            NSColor.black.withAlphaComponent(0.52).setFill()
            NSBezierPath(roundedRect: backgroundRect, xRadius: 5 * scale, yRadius: 5 * scale).fill()
            text.draw(at: drawOrigin, withAttributes: attributes)

        case let .spotlight(rect):
            let focusRect = mapping.rect(rect)
            let overlay = NSBezierPath(rect: mapping.destinationRect)
            overlay.append(NSBezierPath(roundedRect: focusRect, xRadius: 7 * scale, yRadius: 7 * scale))
            overlay.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.58).setFill()
            overlay.fill()
            node.color.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(roundedRect: focusRect, xRadius: 7 * scale, yRadius: 7 * scale)
            border.lineWidth = lineWidth
            border.stroke()

        case let .counter(number, center):
            let rect = mapping.rect(bounds(of: node))
            let circle = NSBezierPath(ovalIn: rect)
            node.color.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            circle.lineWidth = max(1, max(1, node.lineWidth) * 0.55) * scale
            circle.stroke()

            let label = String(number)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: max(11, node.fontSize) * scale,
                    weight: .bold
                ),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attributes)
            let mappedCenter = mapping.point(center)
            label.draw(
                at: CGPoint(
                    x: mappedCenter.x - size.width / 2,
                    y: mappedCenter.y - size.height / 2
                ),
                withAttributes: attributes
            )

        case .blur, .pixelate:
            let region = bounds(of: node).intersection(visibleSourceRect).intersection(imageBounds).integral
            guard !region.isNull, !region.isEmpty else { return }
            let filtered = try filteredImage(for: node, region: region, outputScale: previewScale)
            let image = NSImage(cgImage: filtered, size: region.size)
            image.cacheMode = .never
            image.draw(in: mapping.rect(region), from: .zero, operation: .copy, fraction: 1,
                       respectFlipped: mapping.isFlippedSurface, hints: [.interpolation: NSImageInterpolation.none])
        }
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private static func nonDegenerate(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let width = max(1, rect.width)
        let height = max(1, rect.height)
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func filteredImage(for node: ScreenshotAnnotationNode, region: CGRect, outputScale: CGFloat) throws -> CGImage {
        let raster = try snapshot.rasterSource?.imageForRendering() ?? snapshot.source
        let input = CIImage(cgImage: raster)
        let output: CIImage
        switch node.kind {
        case let .blur(_, radius):
            // The graph retains the full immutable input. CoreImage requests
            // neighboring pixels for each output ROI, so blur never clamps at
            // an export band boundary. No whole-node filtered bitmap is cached.
            output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        case let .pixelate(rect, scale):
            let center = coreImageRect(for: rect.standardized.intersection(imageBounds))
            output = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale,
                kCIInputCenterKey: CIVector(x: center.midX, y: center.midY)
            ])
        default: throw ScreenshotDocumentRenderError.cannotRender
        }
        let scale = max(0.0001, min(1, outputScale))
        let area = coreImageRect(for: region)
        let scaled = output.cropped(to: input.extent).cropped(to: area)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = ciContext.createCGImage(scaled, from: area.applying(CGAffineTransform(scaleX: scale, y: scale)),
                                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ScreenshotDocumentRenderError.cannotRender
        }
        return image
    }

    func renderFilterPreview(node: ScreenshotAnnotationNode, region: CGRect, outputScale: CGFloat) throws -> CGImage {
        let width = ceil(region.width * outputScale), height = ceil(region.height * outputScale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width * height * 4 <= 16 * 1_024 * 1_024 else { throw ScreenshotDocumentRenderError.cannotRender }
        return try ScreenshotRasterWorkGate.shared.withPermit {
            defer { snapshot.rasterSource?.releaseReadPages() }
            return try filteredImage(for: node, region: region, outputScale: outputScale)
        }
    }

    private func coreImageRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: imageSize.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

enum ScreenshotDocumentRenderError: LocalizedError {
    case bitmapBudgetExceeded
    case cannotRender
    case encodingFailed
    var errorDescription: String? {
        switch self {
        case .bitmapBudgetExceeded: return "完整位图超过预算，请使用分块导出"
        case .cannotRender: return "图片分块渲染失败，编辑内容仍保留"
        case .encodingFailed: return "PNG 编码失败，编辑内容仍保留"
        }
    }
}
