import CoreGraphics
import Foundation

/// Geometry rules for a screenshot pinned directly on the desktop.
///
/// A pin starts where its source region was selected, rather than in the
/// Quick Access shelf. Its initial frame is fully visible; after a user drags
/// it, only a small handle-sized portion must remain visible so it can always
/// be recovered without changing the user's intended placement.
public enum PinnedScreenshotPlacement {
    public static let defaultMargin: CGFloat = 8
    public static let minimumVisibleSize = CGSize(width: 24, height: 24)

    public static func initialFrame(
        selectionFrame: CGRect?,
        imagePixelSize: PixelSize?,
        pixelScale: Double?,
        visibleFrame: CGRect,
        cascadeIndex: Int = 0,
        margin: CGFloat = defaultMargin
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: max(0, margin), dy: max(0, margin))
        guard availableFrame.width > 0, availableFrame.height > 0 else {
            return CGRect(origin: visibleFrame.origin, size: .zero)
        }

        let preferredSize = sourceSize(
            selectionFrame: selectionFrame,
            imagePixelSize: imagePixelSize,
            pixelScale: pixelScale
        )
        let size = fittedSize(preferredSize, in: availableFrame.size)
        let cascadeOffset = CGFloat(max(0, cascadeIndex % 6)) * 12

        let preferredOrigin: CGPoint
        if let selectionFrame, selectionFrame.width > 0, selectionFrame.height > 0 {
            preferredOrigin = CGPoint(
                x: selectionFrame.minX + cascadeOffset,
                y: selectionFrame.minY - cascadeOffset
            )
        } else {
            preferredOrigin = CGPoint(
                x: availableFrame.midX - size.width / 2 + cascadeOffset,
                y: availableFrame.midY - size.height / 2 - cascadeOffset
            )
        }

        return CGRect(
            x: min(max(preferredOrigin.x, availableFrame.minX), availableFrame.maxX - size.width),
            y: min(max(preferredOrigin.y, availableFrame.minY), availableFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    public static func clampedDraggedFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minimumVisibleSize: CGSize = minimumVisibleSize
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0 else {
            return frame
        }

        let visibleWidth = min(minimumVisibleSize.width, frame.width, visibleFrame.width)
        let visibleHeight = min(minimumVisibleSize.height, frame.height, visibleFrame.height)
        let minimumX = visibleFrame.minX - frame.width + visibleWidth
        let maximumX = visibleFrame.maxX - visibleWidth
        let minimumY = visibleFrame.minY - frame.height + visibleHeight
        let maximumY = visibleFrame.maxY - visibleHeight

        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: frame.width,
            height: frame.height
        )
    }

    public static func preferredVisibleFrame(for frame: CGRect, among visibleFrames: [CGRect]) -> CGRect? {
        visibleFrames.max { lhs, rhs in
            intersectionArea(frame, lhs) < intersectionArea(frame, rhs)
        }
    }

    /// Absolute scale relative to the initial presentation, never a cumulative
    /// resize of the previous frame. Source image pixels remain untouched.
    public static func scaledFrame(
        initialSize: CGSize,
        scale: Double,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        guard scale.isFinite, scale > 0,
              initialSize.width > 0, initialSize.height > 0 else { return currentFrame }
        let safeScale = min(4, max(0.25, scale))
        let size = CGSize(width: initialSize.width * safeScale, height: initialSize.height * safeScale)
        return clampedDraggedFrame(
            CGRect(x: currentFrame.midX - size.width / 2, y: currentFrame.midY - size.height / 2, width: size.width, height: size.height),
            in: visibleFrame
        )
    }

    private static func sourceSize(
        selectionFrame: CGRect?,
        imagePixelSize: PixelSize?,
        pixelScale: Double?
    ) -> CGSize {
        if let selectionFrame, selectionFrame.width > 0, selectionFrame.height > 0 {
            return selectionFrame.size
        }
        if let imagePixelSize,
           let pixelScale,
           pixelScale.isFinite,
           pixelScale > 0 {
            return CGSize(
                width: CGFloat(imagePixelSize.width) / pixelScale,
                height: CGFloat(imagePixelSize.height) / pixelScale
            )
        }
        if let imagePixelSize, imagePixelSize.width > 0, imagePixelSize.height > 0 {
            return CGSize(
                width: CGFloat(imagePixelSize.width),
                height: CGFloat(imagePixelSize.height)
            )
        }
        return CGSize(width: 320, height: 180)
    }

    private static func fittedSize(_ preferredSize: CGSize, in availableSize: CGSize) -> CGSize {
        let safePreferredSize = CGSize(
            width: max(1, preferredSize.width),
            height: max(1, preferredSize.height)
        )
        let scale = min(
            1,
            availableSize.width / safePreferredSize.width,
            availableSize.height / safePreferredSize.height
        )
        return CGSize(
            width: max(1, safePreferredSize.width * scale),
            height: max(1, safePreferredSize.height * scale)
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
