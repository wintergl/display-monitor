import CoreGraphics

/// Pure geometry for placing the post-capture shelf on a display's usable area.
/// Keeping this separate from AppKit makes negative-origin and small-display
/// behavior deterministic and testable.
public enum ScreenshotShelfPlacement {
    public static func frame(
        in visibleFrame: CGRect,
        preferredSize: CGSize,
        margin: CGFloat = 16
    ) -> CGRect {
        let visibleFrame = visibleFrame.standardized
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .zero
        }

        let safeMargin = max(0, margin)
        let availableWidth = max(1, visibleFrame.width - safeMargin * 2)
        let availableHeight = max(1, visibleFrame.height - safeMargin * 2)
        let width = min(max(1, preferredSize.width), availableWidth)
        let height = min(max(1, preferredSize.height), availableHeight)

        return CGRect(
            x: visibleFrame.maxX - safeMargin - width,
            y: visibleFrame.minY + safeMargin,
            width: width,
            height: height
        )
    }
}

/// Frames independent Quick Access cards on the display that was active when
/// each capture completed. New cards stack upward first, then continue left;
/// they never use the cursor's *current* screen to relocate older captures.
public enum ScreenshotQuickAccessPlacement {
    public static func frames(
        in visibleFrame: CGRect,
        preferredSize: CGSize,
        count: Int,
        margin: CGFloat = 16,
        spacing: CGFloat = 12
    ) -> [CGRect] {
        guard count > 0 else { return [] }

        let first = ScreenshotShelfPlacement.frame(
            in: visibleFrame,
            preferredSize: preferredSize,
            margin: margin
        )
        guard first != .zero else { return [] }

        let safeSpacing = max(0, spacing)
        let usableHeight = max(1, visibleFrame.height - max(0, margin) * 2)
        let rowCount = max(
            1,
            Int(floor((usableHeight + safeSpacing) / (first.height + safeSpacing)))
        )

        return (0..<count).map { index in
            let row = index % rowCount
            let column = index / rowCount
            return CGRect(
                x: first.minX - CGFloat(column) * (first.width + safeSpacing),
                y: first.minY + CGFloat(row) * (first.height + safeSpacing),
                width: first.width,
                height: first.height
            )
        }
    }
}

/// A stable, AppKit-free description of the display the shelf is anchored to.
/// The AppKit layer maps `NSScreen` into this value so the decision to move can
/// be tested without a live display configuration.
public struct ScreenshotShelfAnchor: Equatable, Sendable {
    public let displayID: UInt32?
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(displayID: UInt32?, frame: CGRect, visibleFrame: CGRect) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Keeps pointer-following inexpensive: the AppKit panel only moves when the
/// target display or its usable geometry has actually changed.
public enum ScreenshotShelfFollowPolicy {
    public static func needsReanchor(
        previous: ScreenshotShelfAnchor?,
        current: ScreenshotShelfAnchor
    ) -> Bool {
        previous != current
    }
}
