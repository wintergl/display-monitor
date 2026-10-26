import CoreGraphics

final class PointerManager {
    func moveMouse(toCenterOf displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        CGWarpMouseCursorPosition(point)
    }
}
