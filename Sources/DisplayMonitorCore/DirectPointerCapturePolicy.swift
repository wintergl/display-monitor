import CoreGraphics

public enum DirectPointerCapturePolicy {
    public static func clampedPoint(
        _ point: CGPoint,
        to displayBounds: CGRect,
        edgeInset: CGFloat = 1
    ) -> CGPoint {
        guard point.x.isFinite,
              point.y.isFinite,
              displayBounds.width > 0,
              displayBounds.height > 0 else {
            return point
        }
        let safeInset = max(
            0,
            min(edgeInset, min(displayBounds.width, displayBounds.height) / 2)
        )
        return CGPoint(
            x: min(
                max(point.x, displayBounds.minX + safeInset),
                displayBounds.maxX - safeInset
            ),
            y: min(
                max(point.y, displayBounds.minY + safeInset),
                displayBounds.maxY - safeInset
            )
        )
    }

    public static func shouldDeferExit(pressedMouseButtonCount: Int) -> Bool {
        pressedMouseButtonCount > 0
    }
}

public enum DirectControlActivationPolicy {
    public static func shouldAutoEnable(
        previewVisibility: PreviewVisibility,
        hasAccessibilityPermission: Bool,
        hasOnlineTarget: Bool,
        userDisabledForCurrentPreviewSession: Bool
    ) -> Bool {
        previewVisibility == .shown &&
            hasAccessibilityPermission &&
            hasOnlineTarget &&
            !userDisabledForCurrentPreviewSession
    }
}
