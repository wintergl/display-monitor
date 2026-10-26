import CoreGraphics

public enum ScreenshotViewportMode: Equatable, Sendable {
    case fit
    case fitWidth
    case actualPixels
    /// Display pixels per source pixel, independent of screen point density.
    case manual(CGFloat)
}

/// Top-left image pixels mapped to a top-left (flipped) view in points.
/// View changes carry no document state and never affect exported pixels.
public struct ScreenshotViewportTransform: Equatable, Sendable {
    public var cropRect: CGRect
    public var viewport: CGRect
    public var backingScale: CGFloat
    public private(set) var mode: ScreenshotViewportMode
    public private(set) var pan: CGSize

    public init(cropRect: CGRect, viewport: CGRect, backingScale: CGFloat,
                mode: ScreenshotViewportMode = .fit, pan: CGSize = .zero) {
        self.cropRect = cropRect
        self.viewport = viewport
        self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        self.mode = mode
        self.pan = pan
        normalizePan()
    }

    public var scale: CGFloat {
        guard isValid else { return 0 }
        switch mode {
        case .fit: return min(viewport.width / cropRect.width, viewport.height / cropRect.height)
        case .fitWidth: return viewport.width / cropRect.width
        case .actualPixels: return 1 / backingScale
        case .manual(let zoom): return (zoom.isFinite ? min(16, max(0.001, zoom)) : 1) / backingScale
        }
    }

    public var displayZoom: CGFloat { scale * backingScale }

    public var drawingRect: CGRect {
        guard isValid else { return .zero }
        let size = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
        return CGRect(
            x: origin(length: size.width, min: viewport.minX, max: viewport.maxX, offset: pan.width),
            y: origin(length: size.height, min: viewport.minY, max: viewport.maxY, offset: pan.height),
            width: size.width, height: size.height
        )
    }

    public func imagePoint(at point: CGPoint, clamped: Bool = false) -> CGPoint? {
        let rect = drawingRect
        guard scale > 0, clamped || rect.contains(point) else { return nil }
        return CGPoint(
            x: cropRect.minX + (min(rect.maxX, max(rect.minX, point.x)) - rect.minX) / scale,
            y: cropRect.minY + (min(rect.maxY, max(rect.minY, point.y)) - rect.minY) / scale
        )
    }

    public func viewPoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: drawingRect.minX + (point.x - cropRect.minX) * scale,
                y: drawingRect.minY + (point.y - cropRect.minY) * scale)
    }

    public mutating func setMode(_ value: ScreenshotViewportMode) {
        mode = value
        pan = .zero
    }

    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard factor.isFinite, factor > 0, let imageAnchor = imagePoint(at: anchor, clamped: true) else { return }
        mode = .manual(min(16, max(0.001, displayZoom * factor)))
        pan = .zero
        let newAnchor = viewPoint(for: imageAnchor)
        pan = CGSize(width: anchor.x - newAnchor.x, height: anchor.y - newAnchor.y)
        normalizePan()
    }

    public mutating func move(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        pan.width += delta.width
        pan.height += delta.height
        normalizePan()
    }

    private mutating func normalizePan() {
        let rect = drawingRect
        pan = CGSize(width: rect.width > viewport.width ? rect.minX - viewport.minX : 0,
                     height: rect.height > viewport.height ? rect.minY - viewport.minY : 0)
    }

    private var isValid: Bool {
        [cropRect.minX, cropRect.minY, cropRect.width, cropRect.height,
         viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite)
            && cropRect.width > 0 && cropRect.height > 0 && viewport.width > 0 && viewport.height > 0
    }

    private func origin(length: CGFloat, min lower: CGFloat, max upper: CGFloat, offset: CGFloat) -> CGFloat {
        guard length > upper - lower else { return (lower + upper - length) / 2 }
        return min(lower, max(upper - length, lower + (offset.isFinite ? offset : 0)))
    }
}
