import CoreGraphics

public enum SelectionHandle: String, CaseIterable, Codable, Equatable, Sendable {
    case none
    case move
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    public var isResizeHandle: Bool {
        switch self {
        case .topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight:
            return true
        case .none, .move:
            return false
        }
    }
}

/// Pure AppKit-point geometry for the active screenshot selection.
///
/// The model deliberately does not know about display scale, Quartz origins,
/// or ScreenCaptureKit. Those conversions remain the responsibility of
/// `ScreenCoordinateAdapter`.
public struct SelectionGeometry: Equatable, Sendable {
    public let displayBounds: CGRect
    public private(set) var rect: CGRect
    public let minimumSize: CGSize

    public init(
        displayBounds: CGRect,
        rect: CGRect = .zero,
        minimumSize: CGSize = CGSize(width: 16, height: 16)
    ) {
        self.displayBounds = displayBounds.standardized
        self.rect = rect.standardized
        self.minimumSize = CGSize(
            width: max(0, minimumSize.width),
            height: max(0, minimumSize.height)
        )
    }

    public var meetsMinimumSize: Bool {
        rect.width >= minimumSize.width && rect.height >= minimumSize.height
    }

    public var isWithinDisplayBounds: Bool {
        displayBounds.contains(rect) || displayBounds.equalTo(rect)
    }

    public var isValid: Bool {
        rect.width > 0 && rect.height > 0 && meetsMinimumSize && isWithinDisplayBounds
    }

    public func normalized() -> SelectionGeometry {
        SelectionGeometry(
            displayBounds: displayBounds,
            rect: rect.standardized,
            minimumSize: minimumSize
        )
    }

    /// Clamps the selection to the supplied display bounds and enforces the
    /// minimum final size. The supplied bounds are normalized independently so
    /// this method is safe for negative-origin displays and reverse drags.
    public func clamped(to bounds: CGRect) -> SelectionGeometry {
        let normalizedBounds = bounds.standardized
        let boundedRect = Self.clampedRect(
            rect.standardized,
            to: normalizedBounds,
            minimumSize: minimumSize
        )
        return SelectionGeometry(
            displayBounds: normalizedBounds,
            rect: boundedRect,
            minimumSize: minimumSize
        )
    }

    public func moved(by delta: CGSize) -> SelectionGeometry {
        let current = rect.standardized
        let candidate = current.offsetBy(dx: delta.width, dy: delta.height)
        let boundedRect = Self.clampedRect(
            candidate,
            to: displayBounds,
            minimumSize: minimumSize
        )
        return SelectionGeometry(
            displayBounds: displayBounds,
            rect: boundedRect,
            minimumSize: minimumSize
        )
    }

    /// Resizes from a fixed handle toward the supplied point. If the pointer
    /// crosses the opposite edge, the candidate is normalized before the
    /// bounds/minimum-size clamp, so reverse drags remain predictable.
    public func resized(handle: SelectionHandle, to point: CGPoint) -> SelectionGeometry {
        guard handle.isResizeHandle else {
            return self
        }

        let current = rect.standardized
        var minX = current.minX
        var maxX = current.maxX
        var minY = current.minY
        var maxY = current.maxY

        switch handle {
        case .topLeft:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.maxX,
                pointer: point.x,
                controlsMinimum: true,
                minimum: minimumSize.width
            )
            (minY, maxY) = Self.resizedAxis(
                anchor: current.minY,
                pointer: point.y,
                controlsMinimum: false,
                minimum: minimumSize.height
            )
        case .top:
            (minY, maxY) = Self.resizedAxis(
                anchor: current.minY,
                pointer: point.y,
                controlsMinimum: false,
                minimum: minimumSize.height
            )
        case .topRight:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.minX,
                pointer: point.x,
                controlsMinimum: false,
                minimum: minimumSize.width
            )
            (minY, maxY) = Self.resizedAxis(
                anchor: current.minY,
                pointer: point.y,
                controlsMinimum: false,
                minimum: minimumSize.height
            )
        case .left:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.maxX,
                pointer: point.x,
                controlsMinimum: true,
                minimum: minimumSize.width
            )
        case .right:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.minX,
                pointer: point.x,
                controlsMinimum: false,
                minimum: minimumSize.width
            )
        case .bottomLeft:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.maxX,
                pointer: point.x,
                controlsMinimum: true,
                minimum: minimumSize.width
            )
            (minY, maxY) = Self.resizedAxis(
                anchor: current.maxY,
                pointer: point.y,
                controlsMinimum: true,
                minimum: minimumSize.height
            )
        case .bottom:
            (minY, maxY) = Self.resizedAxis(
                anchor: current.maxY,
                pointer: point.y,
                controlsMinimum: true,
                minimum: minimumSize.height
            )
        case .bottomRight:
            (minX, maxX) = Self.resizedAxis(
                anchor: current.minX,
                pointer: point.x,
                controlsMinimum: false,
                minimum: minimumSize.width
            )
            (minY, maxY) = Self.resizedAxis(
                anchor: current.maxY,
                pointer: point.y,
                controlsMinimum: true,
                minimum: minimumSize.height
            )
        case .none, .move:
            return self
        }

        let candidate = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
        let boundedRect = Self.clampedRect(
            candidate,
            to: displayBounds,
            minimumSize: minimumSize
        )
        return SelectionGeometry(
            displayBounds: displayBounds,
            rect: boundedRect,
            minimumSize: minimumSize
        )
    }

    /// Returns the resize handle first, then the interior move target. This
    /// priority prevents a corner/edge drag from being mistaken for a move.
    public func hitTest(_ point: CGPoint, edgeTolerance: CGFloat = 8) -> SelectionHandle {
        let current = rect.standardized
        guard current.width > 0, current.height > 0 else {
            return .none
        }

        let tolerance = min(
            max(0, edgeTolerance),
            max(1, min(current.width, current.height) / 3)
        )
        let corners: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: current.minX, y: current.maxY)),
            (.topRight, CGPoint(x: current.maxX, y: current.maxY)),
            (.bottomLeft, CGPoint(x: current.minX, y: current.minY)),
            (.bottomRight, CGPoint(x: current.maxX, y: current.minY))
        ]
        for (handle, corner) in corners where Self.isNear(point, corner, tolerance: tolerance) {
            return handle
        }

        if abs(point.y - current.maxY) <= tolerance,
           point.x >= current.minX - tolerance,
           point.x <= current.maxX + tolerance {
            return .top
        }
        if abs(point.y - current.minY) <= tolerance,
           point.x >= current.minX - tolerance,
           point.x <= current.maxX + tolerance {
            return .bottom
        }
        if abs(point.x - current.minX) <= tolerance,
           point.y >= current.minY - tolerance,
           point.y <= current.maxY + tolerance {
            return .left
        }
        if abs(point.x - current.maxX) <= tolerance,
           point.y >= current.minY - tolerance,
           point.y <= current.maxY + tolerance {
            return .right
        }
        if current.contains(point) {
            return .move
        }
        return .none
    }

    private static func isNear(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    private static func resizedAxis(
        anchor: CGFloat,
        pointer: CGFloat,
        controlsMinimum: Bool,
        minimum: CGFloat
    ) -> (CGFloat, CGFloat) {
        let lower = min(anchor, pointer)
        let upper = max(anchor, pointer)
        guard upper - lower < minimum else {
            return (lower, upper)
        }

        if controlsMinimum {
            return pointer <= anchor
                ? (anchor - minimum, anchor)
                : (anchor, anchor + minimum)
        }
        return pointer >= anchor
            ? (anchor, anchor + minimum)
            : (anchor - minimum, anchor)
    }

    private static func clampedRect(
        _ rect: CGRect,
        to bounds: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        let bounds = bounds.standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let minimumWidth = min(max(0, minimumSize.width), bounds.width)
        let minimumHeight = min(max(0, minimumSize.height), bounds.height)
        let width = min(max(rect.width, minimumWidth), bounds.width)
        let height = min(max(rect.height, minimumHeight), bounds.height)
        let minX = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let minY = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}
