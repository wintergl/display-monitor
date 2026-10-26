import CoreGraphics
import DisplayMonitorCore

/// Derived entirely from view geometry; no bitmap or document mutation.
struct ScreenshotEditorNavigationState: Equatable {
    let position: CGFloat
    let knobProportion: CGFloat
    let overflow: CGFloat
    let visibleStartPercent: Int
    let visibleEndPercent: Int
    var canScroll: Bool { overflow > 0.5 }
    var label: String { "位置 \(visibleStartPercent)–\(visibleEndPercent)%" }
    var pageFraction: CGFloat { overflow > 0 ? knobProportion / max(0.001, 1 - knobProportion) : 0 }

    init(transform: ScreenshotViewportTransform) {
        let image = transform.drawingRect
        let viewport = transform.viewport
        guard image.height.isFinite, image.height > 0, viewport.height.isFinite, viewport.height > 0 else {
            position = 0; knobProportion = 1; overflow = 0
            visibleStartPercent = 0; visibleEndPercent = 100
            return
        }
        overflow = max(0, image.height - viewport.height)
        knobProportion = min(1, viewport.height / image.height)
        position = overflow > 0 ? min(1, max(0, (viewport.minY - image.minY) / overflow)) : 0
        let start = min(1, max(0, (viewport.minY - image.minY) / image.height))
        let end = min(1, max(0, (viewport.maxY - image.minY) / image.height))
        visibleStartPercent = Int(floor(start * 100))
        visibleEndPercent = Int(ceil(end * 100))
    }

    static func scrolled(_ transform: ScreenshotViewportTransform, to position: CGFloat) -> ScreenshotViewportTransform {
        guard position.isFinite else { return transform }
        let state = Self(transform: transform)
        var result = transform
        let y = transform.viewport.minY - state.overflow * min(1, max(0, position))
        result.move(by: CGSize(width: 0, height: y - transform.drawingRect.minY))
        return result
    }
}

struct ScreenshotEditorWindowPlacement {
    static func frame(size: CGSize, visibleFrame: CGRect, previousFrame: CGRect?) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return CGRect(origin: .zero, size: size) }
        let fitted = CGSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        var origin = CGPoint(x: visibleFrame.midX - fitted.width / 2, y: visibleFrame.midY - fitted.height / 2)
        if let previousFrame {
            origin = CGPoint(x: previousFrame.minX + 22, y: previousFrame.minY - 22)
            if !visibleFrame.contains(CGRect(origin: origin, size: fitted)) {
                origin = CGPoint(x: visibleFrame.minX + min(24, visibleFrame.width - fitted.width),
                                 y: visibleFrame.maxY - fitted.height - min(24, visibleFrame.height - fitted.height))
            }
        }
        origin.x = min(max(visibleFrame.minX, origin.x), visibleFrame.maxX - fitted.width)
        origin.y = min(max(visibleFrame.minY, origin.y), visibleFrame.maxY - fitted.height)
        return CGRect(origin: origin, size: fitted)
    }
}
