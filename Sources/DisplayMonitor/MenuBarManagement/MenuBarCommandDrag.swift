import CoreGraphics
import Foundation

typealias OrderCancellation = MenuBarOrderCancellation

enum OrderInputTag {
    static let value: Int64 = 0x444D_4241_5244_4700 | Int64(ProcessInfo.processInfo.processIdentifier & 255)
}

enum MenuBarCommandDrag {
    static func perform(
        from item: MenuBarOrderItem,
        relativeTo target: MenuBarOrderItem,
        placement: AnchoredMenuBarMovePlacement,
        cancellation: OrderCancellation,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try checkCancellation(cancellation)
        guard !CGEventSource.buttonState(.hidSystemState, button: .left),
              !CGEventSource.buttonState(.hidSystemState, button: .right),
              !CGEventSource.buttonState(.hidSystemState, button: .center),
              !CGEventSource.keyState(.hidSystemState, key: 55),
              !CGEventSource.keyState(.hidSystemState, key: 54) else {
            throw OrderFailure("检测到鼠标按键或 ⌘ 正被按住，未开始拖动。请松开后重试。")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let original = CGEvent(source: nil)?.location else {
            throw OrderFailure("无法创建输入事件，未开始拖动。")
        }
        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let end = try AnchoredMenuBarDropGeometry.destination(
            relativeTo: target.frame,
            placement: placement
        )
        guard CGDisplayIsActive(item.displayID) != 0,
              CGDisplayBounds(item.displayID).contains(start), CGDisplayBounds(item.displayID).contains(end) else {
            throw OrderFailure("显示器或图标位置已变化，未开始拖动。")
        }
        source.userData = OrderInputTag.value
        var lastPoint = start
        var mouseDown = false
        var commandInjected = false
        var pointerInterfered = false

        func post(_ type: CGEventType, at point: CGPoint) throws {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw OrderFailure("无法生成拖动事件，已停止。")
            }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: OrderInputTag.value)
            event.post(tap: .cghidEventTap)
        }
        func releaseCommand() {
            guard commandInjected else { return }
            commandInjected = false
            // `commandInjected` proves this drag posted the matching key-down.
            // Always balance it; querying HID state here sees our own key-down
            // and would otherwise suppress the key-up indefinitely.
            if let release = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) {
                release.flags = []
                release.setIntegerValueField(.eventSourceUserData, value: OrderInputTag.value)
                release.post(tap: .cghidEventTap)
            }
        }
        defer {
            if let actual = CGEvent(source: nil)?.location {
                if hypot(actual.x - lastPoint.x, actual.y - lastPoint.y) > 12 {
                    pointerInterfered = true
                }
                lastPoint = actual
            }
            if mouseDown { try? post(.leftMouseUp, at: lastPoint) }
            releaseCommand()
            if !pointerInterfered && !cancellation.wasHumanInput { CGWarpMouseCursorPosition(original) }
        }

        func validateInputAndCancellation() throws {
            if let actual = CGEvent(source: nil)?.location,
               hypot(actual.x - lastPoint.x, actual.y - lastPoint.y) > 12 {
                pointerInterfered = true
                let expected = lastPoint
                lastPoint = actual
                cancellation.cancel(humanInput: true, reason: "指针未到预期位置：预期 (\(Int(expected.x)),\(Int(expected.y)))，实际 (\(Int(actual.x)),\(Int(actual.y)))；可能是系统未执行事件或鼠标被移动")
            }
            if CGEventSource.buttonState(.hidSystemState, button: .right)
                || CGEventSource.buttonState(.hidSystemState, button: .center) {
                cancellation.cancel(humanInput: true, reason: "检测到鼠标其他按键")
            }
            try checkCancellation(cancellation)
        }

        progress("开始拖动：\(item.applicationName)，起点 (\(Int(start.x)),\(Int(start.y)))，落点 (\(Int(end.x)),\(Int(end.y)))。")
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true) else {
            throw OrderFailure("无法生成 Command 按下事件，尚未开始拖动。")
        }
        commandDown.flags = .maskCommand
        commandDown.setIntegerValueField(.eventSourceUserData, value: OrderInputTag.value)
        commandDown.post(tap: .cghidEventTap)
        commandInjected = true
        try await Task.sleep(for: .milliseconds(60))
        try post(.leftMouseDown, at: start)
        mouseDown = true
        try await Task.sleep(for: .milliseconds(180))
        let steps = min(20, max(6, Int(abs(end.x - start.x) / 30)))
        for index in 1...steps {
            try validateInputAndCancellation()
            let t = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t)
            try post(.leftMouseDragged, at: point)
            lastPoint = point
            try await Task.sleep(for: .milliseconds(35))
        }
        try await Task.sleep(for: .milliseconds(120))
        try validateInputAndCancellation()
        try post(.leftMouseUp, at: end)
        mouseDown = false
        releaseCommand()
        // Posting is asynchronous. Give mouse-up time to reach the tracking
        // loop before the deferred cursor restoration can move the pointer.
        try await Task.sleep(for: .milliseconds(80))
    }

    /// Explicit recovery for an interrupted drag. The coordinator calls this only
    /// while it owns the menu-bar input lease or during termination cleanup.
    static func releaseSyntheticInputForRecovery() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        source.userData = OrderInputTag.value
        if let location = CGEvent(source: nil)?.location,
           let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
           ) {
            mouseUp.flags = []
            mouseUp.setIntegerValueField(.eventSourceUserData, value: OrderInputTag.value)
            mouseUp.post(tap: .cghidEventTap)
        }
        for key: CGKeyCode in [55, 54] {
            guard let release = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { continue }
            release.flags = []
            release.setIntegerValueField(.eventSourceUserData, value: OrderInputTag.value)
            release.post(tap: .cghidEventTap)
        }
    }

    private static func checkCancellation(_ cancellation: OrderCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled || CGEventSource.keyState(.hidSystemState, key: 53) {
            throw CancellationError()
        }
    }
}

struct OrderFailure: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
