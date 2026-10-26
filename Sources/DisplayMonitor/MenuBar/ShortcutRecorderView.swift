import AppKit
import Carbon.HIToolbox
import SwiftUI

enum ShortcutRecorderCompletion: Equatable {
    case captured
    case cancelled
}

struct ShortcutRecorderState: Equatable {
    private(set) var isRecording = false
    private(set) var capturedKeyCode: UInt16?

    var acceptsKeyDown: Bool {
        isRecording && capturedKeyCode == nil
    }

    mutating func begin() -> Bool {
        guard !isRecording else {
            return false
        }
        isRecording = true
        capturedKeyCode = nil
        return true
    }

    mutating func capture(keyCode: UInt16) -> Bool {
        guard acceptsKeyDown else {
            return false
        }
        capturedKeyCode = keyCode
        return true
    }

    func shouldFinish(onKeyUp keyCode: UInt16) -> Bool {
        isRecording && capturedKeyCode == keyCode
    }

    mutating func finish() -> Bool {
        guard isRecording else {
            return false
        }
        isRecording = false
        capturedKeyCode = nil
        return true
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    let binding: ShortcutBinding
    let onChange: (ShortcutBinding) -> Bool
    let onRecordingBegan: () -> Bool
    let onRecordingEnded: (ShortcutRecorderCompletion) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(
            binding: binding,
            onChange: onChange,
            onRecordingBegan: onRecordingBegan,
            onRecordingEnded: onRecordingEnded
        )
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.update(
            binding: binding,
            onChange: onChange,
            onRecordingBegan: onRecordingBegan,
            onRecordingEnded: onRecordingEnded
        )
    }
}

final class ShortcutRecorderButton: NSButton {
    private var shortcutBinding: ShortcutBinding
    private var onChange: (ShortcutBinding) -> Bool
    private var onRecordingBegan: () -> Bool
    private var onRecordingEnded: (ShortcutRecorderCompletion) -> Void
    private var localKeyMonitor: Any?
    private var recordingState = ShortcutRecorderState()

    init(
        binding: ShortcutBinding,
        onChange: @escaping (ShortcutBinding) -> Bool,
        onRecordingBegan: @escaping () -> Bool,
        onRecordingEnded: @escaping (ShortcutRecorderCompletion) -> Void
    ) {
        shortcutBinding = binding
        self.onChange = onChange
        self.onRecordingBegan = onRecordingBegan
        self.onRecordingEnded = onRecordingEnded
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        focusRingType = .default
        toolTip = "点击后按下新的全局快捷键，Esc 取消"
        setAccessibilityLabel("\(binding.command.title)快捷键")
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func update(
        binding: ShortcutBinding,
        onChange: @escaping (ShortcutBinding) -> Bool,
        onRecordingBegan: @escaping () -> Bool,
        onRecordingEnded: @escaping (ShortcutRecorderCompletion) -> Void
    ) {
        self.onChange = onChange
        self.onRecordingBegan = onRecordingBegan
        self.onRecordingEnded = onRecordingEnded
        setAccessibilityLabel("\(binding.command.title)快捷键")
        if !recordingState.isRecording {
            shortcutBinding = binding
            refreshTitle()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finishRecording(.cancelled)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            finishRecording(.cancelled)
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard recordingState.isRecording else {
            super.keyDown(with: event)
            return
        }
        captureKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        guard recordingState.isRecording else {
            super.keyUp(with: event)
            return
        }
        captureKeyUp(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recordingState.isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        captureKeyDown(event)
        return true
    }

    @objc private func beginRecording() {
        guard !recordingState.isRecording else { return }
        guard let window, window.makeFirstResponder(self) else {
            NSSound.beep()
            return
        }
        guard onRecordingBegan() else {
            NSSound.beep()
            return
        }
        guard recordingState.begin() else {
            onRecordingEnded(.cancelled)
            return
        }
        title = "请按快捷键…"
        state = .on
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            guard let self, self.recordingState.isRecording else { return event }
            switch event.type {
            case .keyDown:
                self.captureKeyDown(event)
            case .keyUp:
                self.captureKeyUp(event)
            default:
                return event
            }
            return nil
        }
    }

    private func captureKeyDown(_ event: NSEvent) {
        guard recordingState.acceptsKeyDown else {
            return
        }
        if Int(event.keyCode) == kVK_Escape {
            finishRecording(.cancelled)
            return
        }
        guard let binding = ShortcutRecorderKeyPresentation.binding(
            command: shortcutBinding.command,
            event: event
        ) else {
            NSSound.beep()
            title = "请使用组合键"
            return
        }
        let accepted = onChange(binding)
        if accepted {
            shortcutBinding = binding
            title = "\(binding.keyEquivalent) · 松开按键"
        } else {
            title = "未更改 · 松开按键"
        }
        _ = recordingState.capture(keyCode: event.keyCode)
    }

    private func captureKeyUp(_ event: NSEvent) {
        guard recordingState.shouldFinish(onKeyUp: event.keyCode) else {
            return
        }
        finishRecording(.captured)
    }

    private func finishRecording(_ completion: ShortcutRecorderCompletion) {
        guard recordingState.finish() else { return }
        state = .off
        removeLocalKeyMonitor()
        refreshTitle()
        onRecordingEnded(completion)
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func refreshTitle() {
        title = shortcutBinding.keyEquivalent
    }
}

private enum ShortcutRecorderKeyPresentation {
    static func binding(command: ToolSuiteCommand, event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        var modifierText = ""
        if flags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            modifierText += "⌃"
        }
        if flags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            modifierText += "⌥"
        }
        if flags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            modifierText += "⇧"
        }
        if flags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            modifierText += "⌘"
        }
        guard carbonModifiers != 0,
              let keyText = keyText(for: event) else {
            return nil
        }

        let commandOnly = carbonModifiers == UInt32(cmdKey)
        let reservedCommandKeys: Set<String> = ["Q", "W", "H", "M", ","]
        guard !commandOnly || !reservedCommandKeys.contains(keyText) else {
            return nil
        }

        return ShortcutBinding(
            command: command,
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            keyEquivalent: modifierText + keyText
        )
    }

    private static func keyText(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default:
            guard let characters = event.charactersIgnoringModifiers?.uppercased(),
                  !characters.isEmpty,
                  characters.count <= 2,
                  characters.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            return characters
        }
    }
}
