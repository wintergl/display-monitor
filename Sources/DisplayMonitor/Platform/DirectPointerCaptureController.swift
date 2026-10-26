import AppKit
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import DisplayMonitorCore
import OSLog

struct DirectPointerCaptureContext {
    let returnLocation: CGPoint
    let targetLocation: CGPoint
    let targetBounds: CGRect
}

enum DirectPointerCapturePreparation {
    case ready(DirectPointerCaptureContext)
    case outsidePreview
    case unavailable(String)
}

@MainActor
final class DirectPointerCaptureController {
    typealias ContextProvider = @MainActor (CGPoint) -> DirectPointerCapturePreparation
    typealias StateHandler = @MainActor (Bool) -> Void
    typealias FailureHandler = @MainActor (String) -> Void
    typealias ShortcutHandler = @MainActor (ToolSuiteCommand) -> Void

    var contextProvider: ContextProvider
    var onStateChange: StateHandler
    var onFailure: FailureHandler
    var onShortcut: ShortcutHandler
    private(set) var triggerModifier: DirectControlModifier
    private(set) var shortcutBindings: [ShortcutBinding]

    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "DirectPointerCapture"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeContext: DirectPointerCaptureContext?
    private var pressedMouseButtons: Set<Int64> = []
    private var pendingExitAfterMouseUp = false
    private var pendingShortcutCommand: ToolSuiteCommand?
    private var consumedShortcutKeyCodes: Set<UInt16> = []

    init(
        triggerModifier: DirectControlModifier,
        shortcutBindings: [ShortcutBinding] = [],
        contextProvider: @escaping ContextProvider,
        onStateChange: @escaping StateHandler,
        onFailure: @escaping FailureHandler,
        onShortcut: @escaping ShortcutHandler = { _ in }
    ) {
        self.triggerModifier = triggerModifier
        self.shortcutBindings = shortcutBindings
        self.contextProvider = contextProvider
        self.onStateChange = onStateChange
        self.onFailure = onFailure
        self.onShortcut = onShortcut
    }

    var isActive: Bool {
        activeContext != nil
    }

    func setTriggerModifier(_ modifier: DirectControlModifier) {
        guard modifier != triggerModifier else {
            return
        }
        finishCapture(reason: "triggerChanged")
        triggerModifier = modifier
        logger.info("directCapture.triggerChanged modifier=\(modifier.rawValue, privacy: .public)")
    }

    func setShortcutBindings(_ bindings: [ShortcutBinding]) {
        shortcutBindings = bindings
        logger.info("directCapture.shortcuts.updated count=\(self.shortcutBindings.count, privacy: .public)")
    }

    func start() {
        guard eventTap == nil else {
            return
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: directPointerCaptureEventTapCallback,
            userInfo: userInfo
        ) else {
            logger.error("directCapture.eventTap.unavailable")
            onFailure("无法启用 \(triggerModifier.symbol) 直控，请确认 Display Monitor 已获得辅助功能权限")
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            logger.error("directCapture.runLoopSource.unavailable")
            onFailure("无法启动 \(triggerModifier.symbol) 直控事件监听")
            return
        }
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.info("directCapture.eventTap.started")
    }

    func stop() {
        finishCapture(reason: "sessionStopped")
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        pressedMouseButtons.removeAll()
        pendingExitAfterMouseUp = false
        pendingShortcutCommand = nil
        logger.info("directCapture.eventTap.stopped")
    }

    func cancelCapture(reason: String) {
        pendingShortcutCommand = nil
        finishCapture(reason: reason)
    }

    fileprivate func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if isActive,
               !CGEventSource.flagsState(.combinedSessionState).contains(triggerModifier.eventFlag) {
                finishCapture(reason: "eventTapRecoveredAfterTriggerRelease")
            }
            logger.error("directCapture.eventTap.reenabled type=\(type.rawValue, privacy: .public)")
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = keyCode(for: event)
            if consumedShortcutKeyCodes.contains(keyCode) {
                return nil
            }
            if isActive, let binding = registeredShortcutBinding(for: event) {
                consumeShortcut(binding, keyCode: keyCode)
                return nil
            }
        }

        if type == .keyUp {
            let keyCode = keyCode(for: event)
            if consumedShortcutKeyCodes.remove(keyCode) != nil {
                logger.info("directCapture.shortcut.keyUpConsumed keyCode=\(keyCode, privacy: .public)")
                return nil
            }
        }

        if type == .flagsChanged, isTriggerKeyEvent(event) {
            if isActive {
                if !event.flags.contains(triggerModifier.eventFlag) {
                    requestExitAfterTriggerRelease()
                }
                return nil
            }
            if event.flags.contains(triggerModifier.eventFlag),
               beginCapture(from: event.location) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard isActive else {
            return Unmanaged.passUnretained(event)
        }

        updatePressedMouseButtons(for: type, event: event)
        var flags = event.flags
        flags.remove(triggerModifier.eventFlag)
        event.flags = flags
        if Self.pointerMotionEventTypes.contains(type),
           let activeContext {
            event.location = DirectPointerCapturePolicy.clampedPoint(
                event.location,
                to: activeContext.targetBounds
            )
        }

        if pendingExitAfterMouseUp,
           !DirectPointerCapturePolicy.shouldDeferExit(
               pressedMouseButtonCount: pressedMouseButtons.count
           ) {
            pendingExitAfterMouseUp = false
            if let pendingShortcutCommand {
                self.pendingShortcutCommand = nil
                finishCapture(reason: "shortcutPreemptAfterMouseUp")
                onShortcut(pendingShortcutCommand)
            } else {
                finishCapture(reason: "triggerReleasedAfterMouseUp")
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func consumeShortcut(_ binding: ShortcutBinding, keyCode: UInt16) {
        consumedShortcutKeyCodes.insert(keyCode)
        if DirectPointerCapturePolicy.shouldDeferExit(
            pressedMouseButtonCount: pressedMouseButtons.count
        ) {
            pendingExitAfterMouseUp = true
            pendingShortcutCommand = binding.command
            logger.info(
                "directCapture.shortcut.preemptDeferred command=\(binding.command.title, privacy: .public) mouseButtons=\(self.pressedMouseButtons.count, privacy: .public)"
            )
            return
        }

        finishCapture(reason: "shortcutPreempt")
        logger.info("directCapture.shortcut.preempt command=\(binding.command.title, privacy: .public)")
        onShortcut(binding.command)
    }

    private func beginCapture(from pointerLocation: CGPoint) -> Bool {
        switch contextProvider(pointerLocation) {
        case .ready(let context):
            activeContext = context
            pressedMouseButtons.removeAll()
            pendingExitAfterMouseUp = false
            pendingShortcutCommand = nil
            onStateChange(true)
            CGWarpMouseCursorPosition(context.targetLocation)
            logger.info("directCapture.entered")
            return true
        case .outsidePreview:
            return false
        case .unavailable(let message):
            onFailure(message)
            logger.info("directCapture.entryRejected")
            return false
        }
    }

    private func requestExitAfterTriggerRelease() {
        if DirectPointerCapturePolicy.shouldDeferExit(
            pressedMouseButtonCount: pressedMouseButtons.count
        ) {
            pendingExitAfterMouseUp = true
            logger.info("directCapture.exitDeferred mouseButtons=\(self.pressedMouseButtons.count, privacy: .public)")
        } else {
            finishCapture(reason: "triggerReleased")
        }
    }

    private func finishCapture(reason: String) {
        guard let context = activeContext else {
            return
        }
        activeContext = nil
        pressedMouseButtons.removeAll()
        pendingExitAfterMouseUp = false
        CGWarpMouseCursorPosition(context.returnLocation)
        onStateChange(false)
        logger.info("directCapture.exited reason=\(reason, privacy: .public)")
    }

    private func registeredShortcutBinding(for event: CGEvent) -> ShortcutBinding? {
        let keyCode = UInt32(keyCode(for: event))
        return shortcutBindings.first { binding in
            guard binding.keyCode == keyCode else {
                return false
            }
            let requiredFlags = cgEventFlags(for: binding.modifiers)
            return event.flags.intersection(Self.shortcutModifierFlags) == requiredFlags
        }
    }

    private func keyCode(for event: CGEvent) -> UInt16 {
        UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func cgEventFlags(for modifiers: UInt32) -> CGEventFlags {
        var flags = CGEventFlags(rawValue: 0)
        if modifiers & UInt32(optionKey) != 0 {
            flags.insert(.maskAlternate)
        }
        if modifiers & UInt32(controlKey) != 0 {
            flags.insert(.maskControl)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.maskShift)
        }
        if modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.maskCommand)
        }
        return flags
    }

    private static let shortcutModifierFlags: CGEventFlags = [
        .maskAlternate,
        .maskControl,
        .maskShift,
        .maskCommand
    ]

    private func isTriggerKeyEvent(_ event: CGEvent) -> Bool {
        triggerModifier.keyCodes.contains(keyCode(for: event))
    }

    private func updatePressedMouseButtons(for type: CGEventType, event: CGEvent) {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedMouseButtons.insert(button)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedMouseButtons.remove(button)
        default:
            break
        }
    }

    private static let pointerMotionEventTypes: Set<CGEventType> = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged
    ]

    private static let eventMask: CGEventMask = [
        CGEventType.flagsChanged,
        .keyDown,
        .keyUp,
        .mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel
    ].reduce(CGEventMask(0)) { mask, eventType in
        mask | (CGEventMask(1) << eventType.rawValue)
    }
}

private extension DirectControlModifier {
    var eventFlag: CGEventFlags {
        switch self {
        case .option:
            return .maskAlternate
        case .control:
            return .maskControl
        case .shift:
            return .maskShift
        case .command:
            return .maskCommand
        }
    }

    var keyCodes: Set<UInt16> {
        switch self {
        case .option:
            return [UInt16(kVK_Option), UInt16(kVK_RightOption)]
        case .control:
            return [UInt16(kVK_Control), UInt16(kVK_RightControl)]
        case .shift:
            return [UInt16(kVK_Shift), UInt16(kVK_RightShift)]
        case .command:
            return [UInt16(kVK_Command), UInt16(kVK_RightCommand)]
        }
    }
}

private func directPointerCaptureEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<DirectPointerCaptureController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handleEventTap(type: type, event: event)
    }
}
