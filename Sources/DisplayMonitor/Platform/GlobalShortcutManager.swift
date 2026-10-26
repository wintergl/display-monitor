import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import Foundation
import OSLog

enum ToolSuiteCommand: UInt32, CaseIterable, Hashable, Sendable {
    case toggleMonitor = 1
    case captureRegion = 2
    case togglePause = 3
    case moveToTarget = 4
    case moveToMain = 5

    var title: String {
        switch self {
        case .toggleMonitor:
            return "切换 Monitor"
        case .captureRegion:
            return "框选截图"
        case .togglePause:
            return "暂停/继续采集"
        case .moveToTarget:
            return "鼠标到目标屏"
        case .moveToMain:
            return "鼠标回主屏"
        }
    }

    var settingsKey: String {
        switch self {
        case .toggleMonitor:
            return "toggleMonitor"
        case .captureRegion:
            return "captureRegion"
        case .togglePause:
            return "togglePause"
        case .moveToTarget:
            return "moveToTarget"
        case .moveToMain:
            return "moveToMain"
        }
    }
}

struct ShortcutBinding: Equatable, Hashable, Sendable {
    var command: ToolSuiteCommand
    var keyCode: UInt32
    var modifiers: UInt32
    var keyEquivalent: String

    var shortcut: ToolSuiteCommand {
        command
    }
}

enum ShortcutRegistry {
    private static let persistedPrefix = "v1"
    private static let allowedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    static let defaultBindings: [ShortcutBinding] = [
        ShortcutBinding(
            command: .toggleMonitor,
            keyCode: UInt32(kVK_F1),
            modifiers: UInt32(optionKey),
            keyEquivalent: "⌥F1"
        ),
        ShortcutBinding(
            command: .captureRegion,
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey),
            keyEquivalent: "⌥A"
        ),
        ShortcutBinding(
            command: .togglePause,
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(optionKey | cmdKey),
            keyEquivalent: "⌥⌘P"
        ),
        ShortcutBinding(
            command: .moveToTarget,
            keyCode: UInt32(kVK_RightArrow),
            modifiers: UInt32(optionKey | cmdKey),
            keyEquivalent: "⌥⌘→"
        ),
        ShortcutBinding(
            command: .moveToMain,
            keyCode: UInt32(kVK_LeftArrow),
            modifiers: UInt32(optionKey | cmdKey),
            keyEquivalent: "⌥⌘←"
        )
    ]

    private static let supportedKeyEquivalents: [String: (keyCode: UInt32, modifiers: UInt32)] = [
        "⌥F1": (UInt32(kVK_F1), UInt32(optionKey)),
        "⌥A": (UInt32(kVK_ANSI_A), UInt32(optionKey)),
        "⌥⌘P": (UInt32(kVK_ANSI_P), UInt32(optionKey | cmdKey)),
        "⌥⌘→": (UInt32(kVK_RightArrow), UInt32(optionKey | cmdKey)),
        "⌥⌘←": (UInt32(kVK_LeftArrow), UInt32(optionKey | cmdKey))
    ]

    static func bindings(from persisted: [String: String]) -> [ShortcutBinding] {
        defaultBindings.map { binding in
            guard let requested = persisted[binding.command.settingsKey],
                  let specification = specification(for: requested) else {
                return binding
            }
            return ShortcutBinding(
                command: binding.command,
                keyCode: specification.keyCode,
                modifiers: specification.modifiers,
                keyEquivalent: specification.keyEquivalent
            )
        }
    }

    static func persistedValue(for binding: ShortcutBinding) -> String {
        "\(persistedPrefix):\(binding.keyCode):\(binding.modifiers):\(binding.keyEquivalent)"
    }

    static func conflictingCommand(
        for proposedBinding: ShortcutBinding,
        in bindings: [ShortcutBinding]
    ) -> ToolSuiteCommand? {
        bindings.first {
            $0.command != proposedBinding.command
                && $0.keyCode == proposedBinding.keyCode
                && $0.modifiers == proposedBinding.modifiers
        }?.command
    }

    private static func specification(
        for persistedValue: String
    ) -> (keyCode: UInt32, modifiers: UInt32, keyEquivalent: String)? {
        if let known = supportedKeyEquivalents[persistedValue] {
            return (known.keyCode, known.modifiers, persistedValue)
        }

        let components = persistedValue.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == Substring(persistedPrefix),
              let keyCode = UInt32(components[1]),
              keyCode <= 255,
              let modifiers = UInt32(components[2]),
              modifiers != 0,
              modifiers & ~allowedModifierMask == 0 else {
            return nil
        }
        let keyEquivalent = String(components[3])
        guard !keyEquivalent.isEmpty, keyEquivalent.count <= 16 else {
            return nil
        }
        return (keyCode, modifiers, keyEquivalent)
    }
}

struct GlobalShortcutRegistration: Equatable {
    var binding: ShortcutBinding
    var isRegistered: Bool
    var statusCode: OSStatus

    var shortcut: ToolSuiteCommand {
        binding.command
    }

    var menuText: String {
        if isRegistered {
            return binding.keyEquivalent
        }
        return "\(binding.keyEquivalent) 不可用（\(statusCode)）"
    }
}

enum GlobalShortcutRegistrationPolicy {
    /// Non-exclusive Carbon registrations can remain reported as healthy while
    /// an exclusive registration in another process silently suppresses their
    /// callbacks. Owning the user's configured chord exclusively makes that
    /// conflict observable as a registration failure instead.
    static let options = UInt32(kEventHotKeyExclusive)
}

enum GlobalShortcutEventMatcher {
    private static let shortcutModifierFlags: CGEventFlags = [
        .maskAlternate,
        .maskControl,
        .maskShift,
        .maskCommand
    ]

    static func matches(
        keyCode: UInt16,
        flags: CGEventFlags,
        binding: ShortcutBinding
    ) -> Bool {
        guard UInt32(keyCode) == binding.keyCode else {
            return false
        }
        return flags.intersection(shortcutModifierFlags) == eventFlags(for: binding.modifiers)
    }

    private static func eventFlags(for modifiers: UInt32) -> CGEventFlags {
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
}

final class GlobalShortcutManager {
    private enum InvocationSource {
        case carbon
        case eventTap
    }

    private let signature = fourCharacterCode("DMON")
    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "GlobalShortcut"
    )
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var bindingsByID: [UInt32: ShortcutBinding] = [:]
    private var actions: [ToolSuiteCommand: @Sendable () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var fallbackEventTap: CFMachPort?
    private var fallbackRunLoopSource: CFRunLoopSource?
    private var fallbackBindings: [ShortcutBinding] = []
    private var lastInvocation: (commandID: UInt32, uptime: TimeInterval)?

    deinit {
        unregisterAll()
    }

    func register(
        bindings: [ShortcutBinding],
        actions: [ToolSuiteCommand: @Sendable () -> Void]
    ) -> [GlobalShortcutRegistration] {
        unregisterAll()
        bindingsByID = Dictionary(uniqueKeysWithValues: bindings.map { ($0.command.rawValue, $0) })
        self.actions = actions
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            bindingsByID.removeAll()
            self.actions.removeAll()
            return bindings.map {
                GlobalShortcutRegistration(
                    binding: $0,
                    isRegistered: false,
                    statusCode: handlerStatus
                )
            }
        }
        let registrations = bindings.map(register)
        installCaptureShortcutFallback(
            bindings: registrations.compactMap { registration in
                registration.isRegistered ? registration.binding : nil
            }
        )
        return registrations
    }

    func unregisterAll() {
        removeCaptureShortcutFallback()
        for ref in hotKeys.values {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        bindingsByID.removeAll()
        actions.removeAll()
        lastInvocation = nil

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(_ binding: ShortcutBinding) -> GlobalShortcutRegistration {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: binding.command.rawValue)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            GlobalShortcutRegistrationPolicy.options,
            &hotKeyRef
        )
        let isRegistered = status == noErr && hotKeyRef != nil
        let effectiveStatus = status == noErr && !isRegistered
            ? OSStatus(eventInternalErr)
            : status
        if isRegistered, let hotKeyRef {
            hotKeys[binding.command.rawValue] = hotKeyRef
        }
        logger.info(
            "shortcut.carbon.registration command=\(binding.command.title, privacy: .public) keyCode=\(binding.keyCode, privacy: .public) modifiers=\(binding.modifiers, privacy: .public) status=\(effectiveStatus, privacy: .public) registered=\(isRegistered, privacy: .public)"
        )
        return GlobalShortcutRegistration(
            binding: binding,
            isRegistered: isRegistered,
            statusCode: effectiveStatus
        )
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else {
            return noErr
        }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalShortcutManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                manager.invoke(commandID: hotKeyID.id, source: .carbon)
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        let effectiveStatus = status == noErr && eventHandler == nil
            ? OSStatus(eventInternalErr)
            : status
        logger.info(
            "shortcut.carbon.handler status=\(effectiveStatus, privacy: .public) installed=\(self.eventHandler != nil, privacy: .public)"
        )
        return effectiveStatus
    }

    private func installCaptureShortcutFallback(bindings: [ShortcutBinding]) {
        removeCaptureShortcutFallback()
        fallbackBindings = bindings.filter { $0.command == .captureRegion }
        guard !fallbackBindings.isEmpty else {
            return
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: globalShortcutFallbackEventTapCallback,
            userInfo: userInfo
        ) else {
            fallbackBindings.removeAll()
            logger.error("shortcut.eventTap.installFailed command=框选截图")
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            fallbackBindings.removeAll()
            logger.error("shortcut.eventTap.runLoopSourceFailed command=框选截图")
            return
        }

        fallbackEventTap = eventTap
        fallbackRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.info("shortcut.eventTap.installed command=框选截图 listenOnly=true")
    }

    private func removeCaptureShortcutFallback() {
        if let fallbackEventTap {
            CGEvent.tapEnable(tap: fallbackEventTap, enable: false)
        }
        if let fallbackRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), fallbackRunLoopSource, .commonModes)
        }
        if let fallbackEventTap {
            CFMachPortInvalidate(fallbackEventTap)
        }
        fallbackEventTap = nil
        fallbackRunLoopSource = nil
        fallbackBindings.removeAll()
    }

    fileprivate func handleFallbackEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let fallbackEventTap {
                CGEvent.tapEnable(tap: fallbackEventTap, enable: true)
            }
            logger.error("shortcut.eventTap.reenabled type=\(type.rawValue, privacy: .public)")
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let binding = fallbackBindings.first(where: {
            GlobalShortcutEventMatcher.matches(
                keyCode: keyCode,
                flags: event.flags,
                binding: $0
            )
        }) else {
            return Unmanaged.passUnretained(event)
        }

        invoke(commandID: binding.command.rawValue, source: .eventTap)
        return Unmanaged.passUnretained(event)
    }

    private func invoke(commandID: UInt32, source: InvocationSource) {
        guard let command = bindingsByID[commandID]?.command else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastInvocation,
           lastInvocation.commandID == commandID,
           now - lastInvocation.uptime < 0.15 {
            logger.info("shortcut.duplicate.ignored command=\(command.title, privacy: .public)")
            return
        }
        lastInvocation = (commandID, now)
        switch source {
        case .carbon:
            logger.info("shortcut.carbon.received command=\(command.title, privacy: .public)")
        case .eventTap:
            logger.info("shortcut.eventTap.received command=\(command.title, privacy: .public)")
        }
        actions[command]?()
    }
}

private func globalShortcutFallbackEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<GlobalShortcutManager>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return manager.handleFallbackEventTap(type: type, event: event)
}

private func fourCharacterCode(_ string: String) -> OSType {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + UInt32(scalar.value)
    }
    return OSType(result)
}
