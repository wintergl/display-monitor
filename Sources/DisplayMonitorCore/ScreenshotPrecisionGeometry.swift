import CoreGraphics

public enum ScreenshotNudgeDirection: Sendable {
    case left, right, up, down
}

/// Selection geometry stays in AppKit points. Keyboard steps and magnifier
/// sampling use the actual frozen-image pixels when they are available.
public enum ScreenshotPrecisionGeometry {
    public static func adjusted(
        _ geometry: SelectionGeometry,
        direction: ScreenshotNudgeDirection,
        pixelScale: CGSize,
        accelerated: Bool,
        resize: Bool
    ) -> SelectionGeometry {
        guard geometry.isValid,
              pixelScale.width.isFinite, pixelScale.height.isFinite,
              pixelScale.width > 0, pixelScale.height > 0 else { return geometry }
        let pixels: CGFloat = accelerated ? 10 : 1
        let dx: CGFloat
        let dy: CGFloat
        switch direction {
        case .left: (dx, dy) = (-pixels / pixelScale.width, 0)
        case .right: (dx, dy) = (pixels / pixelScale.width, 0)
        case .up: (dx, dy) = (0, pixels / pixelScale.height)
        case .down: (dx, dy) = (0, -pixels / pixelScale.height)
        }
        guard resize else { return geometry.moved(by: CGSize(width: dx, height: dy)) }
        // Option adjusts the right/bottom edges with the top-left fixed.
        // AppKit's bottom edge is minY: Up shrinks, Down grows the height.
        let rect = geometry.rect
        let width = min(
            max(geometry.minimumSize.width, rect.width + dx),
            geometry.displayBounds.maxX - rect.minX
        )
        let height = min(
            max(geometry.minimumSize.height, rect.height - dy),
            rect.maxY - geometry.displayBounds.minY
        )
        return SelectionGeometry(
            displayBounds: geometry.displayBounds,
            rect: CGRect(x: rect.minX, y: rect.maxY - height, width: width, height: height),
            minimumSize: geometry.minimumSize
        )
    }

    public static func imagePixel(
        at point: CGPoint,
        in displayBounds: CGRect,
        imageSize: CGSize
    ) -> CGPoint? {
        guard displayBounds.width > 0, displayBounds.height > 0,
              imageSize.width >= 1, imageSize.height >= 1,
              point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(
            x: min(max(0, floor((point.x - displayBounds.minX) * imageSize.width / displayBounds.width)), imageSize.width - 1),
            y: min(max(0, floor((displayBounds.maxY - point.y) * imageSize.height / displayBounds.height)), imageSize.height - 1)
        )
    }

    public static func magnifierSampleRect(
        at point: CGPoint,
        in displayBounds: CGRect,
        imageSize: CGSize,
        sidePixels: Int = 29
    ) -> CGRect? {
        guard let pixel = imagePixel(at: point, in: displayBounds, imageSize: imageSize) else { return nil }
        let width = min(imageSize.width, CGFloat(max(1, sidePixels)))
        let height = min(imageSize.height, CGFloat(max(1, sidePixels)))
        return CGRect(
            x: min(max(0, pixel.x - floor(width / 2)), imageSize.width - width),
            y: min(max(0, pixel.y - floor(height / 2)), imageSize.height - height),
            width: width,
            height: height
        )
    }
}
