import AppKit
import CoreGraphics

/// Assessment-mode hiding also disables the clock's Notification Center action.
/// Release it only for an actual clock click. Hovering must keep items hidden.
enum MenuBarSystemPanelAccessPolicy {
    static let eventMask: NSEvent.EventTypeMask = [.leftMouseDown]

    static func shouldRelease(for eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseDown
    }

    static func contains(pointer: CGPoint, displays: [CGRect], clockFrames: [CGRect]) -> Bool {
        guard pointer.x.isFinite, pointer.y.isFinite else { return false }
        return displays.contains { display in
            guard display.width > 0, display.height > 0 else { return false }
            let clocks = clockFrames.filter { $0.width > 0 && $0.height > 0 && display.intersects($0) }
            let regions = clocks.isEmpty
                ? [CGRect(x: display.maxX - min(220, display.width), y: display.minY,
                          width: min(220, display.width), height: 40)]
                : clocks.map { $0.intersection(display) }
            return regions.contains { $0.contains(pointer) }
        }
    }
}

@MainActor
final class MenuBarSystemPanelAccessMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(clockFrames: [CGRect], onAccess: @escaping @MainActor () -> Void) {
        stop()
        let check: @MainActor (NSEvent) -> Void = { event in
            guard MenuBarSystemPanelAccessPolicy.shouldRelease(for: event.type) else { return }
            let screens = NSScreen.screens
            guard let primaryTop = screens.first?.frame.maxY else { return }
            let pointer = NSEvent.mouseLocation
            let displays = screens.map { screen in
                CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                       width: screen.frame.width, height: screen.frame.height)
            }
            if MenuBarSystemPanelAccessPolicy.contains(
                pointer: CGPoint(x: pointer.x, y: primaryTop - pointer.y),
                displays: displays, clockFrames: clockFrames
            ) {
                onAccess()
            }
        }
        // NSEvent invokes both monitors on the main thread. Begin releasing
        // immediately; queuing another Task adds latency to the click path.
        let mask = MenuBarSystemPanelAccessPolicy.eventMask
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { check(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { check(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
