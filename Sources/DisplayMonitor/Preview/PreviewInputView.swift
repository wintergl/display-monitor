import AppKit
import CoreGraphics
import DisplayMonitorCore
import SwiftUI

struct PreviewInputView: NSViewRepresentable {
    let displayID: CGDirectDisplayID?
    let triggerModifier: DirectControlModifier
    let shortcutBindings: [ShortcutBinding]
    let isEnabled: Bool
    let isAuthorized: Bool
    let onDirectCaptureChanged: @MainActor (Bool) -> Void
    let onDirectCaptureFailure: @MainActor (String) -> Void
    let onDirectShortcut: @MainActor (ToolSuiteCommand) -> Void

    func makeNSView(context: Context) -> PreviewInputHostView {
        PreviewInputHostView(
            displayID: displayID,
            triggerModifier: triggerModifier,
            shortcutBindings: shortcutBindings,
            isEnabled: isEnabled,
            isAuthorized: isAuthorized,
            onDirectCaptureChanged: onDirectCaptureChanged,
            onDirectCaptureFailure: onDirectCaptureFailure,
            onDirectShortcut: onDirectShortcut
        )
    }

    func updateNSView(_ nsView: PreviewInputHostView, context: Context) {
        nsView.displayID = displayID
        nsView.triggerModifier = triggerModifier
        nsView.shortcutBindings = shortcutBindings
        nsView.isEnabled = isEnabled
        nsView.isAuthorized = isAuthorized
        nsView.onDirectCaptureChanged = onDirectCaptureChanged
        nsView.onDirectCaptureFailure = onDirectCaptureFailure
        nsView.onDirectShortcut = onDirectShortcut
    }

    static func dismantleNSView(_ nsView: PreviewInputHostView, coordinator: ()) {
        nsView.shutdown()
    }
}

/// Owns the narrow AppKit boundary needed for direct pointer capture.
///
/// It deliberately performs no click, scroll, drag, or keyboard forwarding of
/// its own. The session event tap only consumes the configured modifier
/// after `directCapturePreparation` proves that the pointer is over the visible
/// preview image in Display Monitor's frontmost window at that point.
final class PreviewInputHostView: NSView {
    private var isShutDown = false
    var displayID: CGDirectDisplayID? {
        didSet {
            guard displayID != oldValue else {
                return
            }
            directPointerCaptureController.cancelCapture(reason: "targetChanged")
        }
    }

    var triggerModifier: DirectControlModifier {
        didSet {
            guard triggerModifier != oldValue else {
                return
            }
            directPointerCaptureController.setTriggerModifier(triggerModifier)
        }
    }

    var shortcutBindings: [ShortcutBinding] {
        didSet {
            guard shortcutBindings != oldValue else {
                return
            }
            directPointerCaptureController.setShortcutBindings(shortcutBindings)
        }
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            isEnabled ? startControlSessionIfPossible() : stopControlSession()
        }
    }

    var isAuthorized: Bool {
        didSet {
            guard isAuthorized != oldValue else {
                return
            }
            if isAuthorized {
                startControlSessionIfPossible()
            } else {
                stopControlSession()
            }
        }
    }

    var onDirectCaptureChanged: @MainActor (Bool) -> Void
    var onDirectCaptureFailure: @MainActor (String) -> Void
    var onDirectShortcut: @MainActor (ToolSuiteCommand) -> Void

    private lazy var directPointerCaptureController = DirectPointerCaptureController(
        triggerModifier: triggerModifier,
        shortcutBindings: shortcutBindings,
        contextProvider: { [weak self] pointerLocation in
            self?.directCapturePreparation(at: pointerLocation) ?? .outsidePreview
        },
        onStateChange: { [weak self] isActive in
            self?.onDirectCaptureChanged(isActive)
        },
        onFailure: { [weak self] message in
            self?.onDirectCaptureFailure(message)
        },
        onShortcut: { [weak self] command in
            self?.onDirectShortcut(command)
        }
    )

    init(
        displayID: CGDirectDisplayID?,
        triggerModifier: DirectControlModifier,
        shortcutBindings: [ShortcutBinding],
        isEnabled: Bool,
        isAuthorized: Bool,
        onDirectCaptureChanged: @escaping @MainActor (Bool) -> Void,
        onDirectCaptureFailure: @escaping @MainActor (String) -> Void,
        onDirectShortcut: @escaping @MainActor (ToolSuiteCommand) -> Void
    ) {
        self.displayID = displayID
        self.triggerModifier = triggerModifier
        self.shortcutBindings = shortcutBindings
        self.isEnabled = isEnabled
        self.isAuthorized = isAuthorized
        self.onDirectCaptureChanged = onDirectCaptureChanged
        self.onDirectCaptureFailure = onDirectCaptureFailure
        self.onDirectShortcut = onDirectShortcut
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("目标屏幕直控触发区域")
        startControlSessionIfPossible()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopControlSession()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Tear down synchronously: merely hiding the panel leaves its event tap alive.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        onDirectCaptureChanged = { _ in }
        onDirectCaptureFailure = { _ in }
        onDirectShortcut = { _ in }
        stopControlSession()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startControlSessionIfPossible()
    }

    private func directCapturePreparation(
        at pointerLocation: CGPoint
    ) -> DirectPointerCapturePreparation {
        guard !isShutDown, isEnabled,
              isAuthorized,
              let displayID,
              let window else {
            return .outsidePreview
        }

        let appKitPoint = NSEvent.mouseLocation
        guard window.isVisible,
              NSWindow.windowNumber(
                  at: appKitPoint,
                  belowWindowWithWindowNumber: 0
              ) == window.windowNumber else {
            return .outsidePreview
        }

        let windowPoint = window.convertPoint(fromScreen: appKitPoint)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            return .outsidePreview
        }
        guard window.screen?.displayID != displayID else {
            return .unavailable("目标屏与 Monitor 窗口在同一屏幕，无法进行实体鼠标穿透")
        }

        let targetBounds = CGDisplayBounds(displayID)
        guard let targetLocation = PreviewCoordinateMapper.map(
            localPoint: localPoint,
            previewBounds: bounds,
            targetBounds: targetBounds,
            contentSize: targetBounds.size
        ) else {
            return .unavailable("请把鼠标放在实际监看画面内再按住 \(triggerModifier.symbol)")
        }

        return .ready(
            DirectPointerCaptureContext(
                returnLocation: pointerLocation,
                targetLocation: targetLocation,
                targetBounds: targetBounds
            )
        )
    }

    private func startControlSessionIfPossible() {
        guard !isShutDown, window != nil, isEnabled, isAuthorized else {
            return
        }
        directPointerCaptureController.start()
    }

    private func stopControlSession() {
        directPointerCaptureController.stop()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
