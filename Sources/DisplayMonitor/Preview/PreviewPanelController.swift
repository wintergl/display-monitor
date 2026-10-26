import AppKit
import DisplayMonitorCore
import SwiftUI

@MainActor
final class PreviewPanelController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let sampleDisplayCoordinator: SampleBufferDisplayCoordinator
    private var panel: NSPanel?
    private var companionPanel: NSPanel?
    private var collapsedPanel: NSPanel?
    private var isShutDown = false
    private let companionPanelSize = CGSize(width: 560, height: 54)
    private let companionPanelGap: CGFloat = 8

    init(model: AppModel, sampleDisplayCoordinator: SampleBufferDisplayCoordinator) {
        self.model = model
        self.sampleDisplayCoordinator = sampleDisplayCoordinator
    }

    func show(restoredFrame: CGRect?) {
        guard !isShutDown else { return }
        collapsedPanel?.orderOut(nil)
        let panel = ensurePanel()
        let frame = resolvedFrame(savedFrame: restoredFrame)
        panel.setFrame(frame, display: true)
        let companionPanel = ensureCompanionPanel()
        attachCompanionPanel(companionPanel, to: panel)
        updateCompanionPanelFrame()
        panel.orderFrontRegardless()
        companionPanel.orderFrontRegardless()
    }

    func showCollapsed(restoredFrame: CGRect?) {
        guard !isShutDown else { return }
        panel?.orderOut(nil)
        companionPanel?.orderOut(nil)
        let collapsedPanel = ensureCollapsedPanel()
        collapsedPanel.setFrame(resolvedCollapsedFrame(savedFrame: restoredFrame), display: true)
        collapsedPanel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        companionPanel?.orderOut(nil)
        collapsedPanel?.orderOut(nil)
    }

    func updatePinning() {
        guard !isShutDown else { return }
        for window in [panel, companionPanel, collapsedPanel].compactMap({ $0 }) {
            applyPinning(to: window)
        }
    }

    private func applyPinning(to window: NSPanel) {
        window.isFloatingPanel = model.previewIsPinned
        window.level = model.previewIsPinned ? .floating : .normal
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        for window in [panel, companionPanel, collapsedPanel].compactMap({ $0 }) {
            if let contentView = window.contentView {
                stopInputHosts(in: contentView)
            }
            window.delegate = nil
            window.orderOut(nil)
            window.parent?.removeChildWindow(window)
            window.contentView = nil
            window.close()
        }
        panel = nil
        companionPanel = nil
        collapsedPanel = nil
    }

    private func stopInputHosts(in view: NSView) {
        (view as? PreviewInputHostView)?.shutdown()
        for child in view.subviews { stopInputHosts(in: child) }
    }

    func resetFrame() {
        guard !isShutDown else { return }
        let frame = defaultFrame()
        let panel = ensurePanel()
        panel.setFrame(frame, display: true, animate: true)
        updateCompanionPanelFrame()
        model.previewPanelFrameDidChange(frame)
        panel.orderFrontRegardless()
        companionPanel?.orderFrontRegardless()
    }

    func resetCollapsedFrame() {
        guard !isShutDown else { return }
        let frame = defaultCollapsedFrame()
        let collapsedPanel = ensureCollapsedPanel()
        collapsedPanel.setFrame(frame, display: true, animate: true)
        model.collapsedIconFrameDidChange(frame)
        collapsedPanel.orderFrontRegardless()
    }

    func resizePreview(to contentSize: CGSize) {
        guard !isShutDown else { return }
        guard let panel else {
            return
        }
        panel.setContentSize(contentSize)
        updateCompanionPanelFrame()
        model.previewPanelFrameDidChange(panel.frame)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel {
            model.previewPanelDidClose()
            companionPanel?.orderOut(nil)
        } else {
            model.hidePreview()
        }
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        updateCompanionPanelFrame()
        saveCurrentFrames()
    }

    func windowDidResize(_ notification: Notification) {
        updateCompanionPanelFrame()
        saveCurrentFrames()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateCompanionPanelFrame()
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = PreviewFloatingPanel(
            contentRect: defaultFrame(),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppConstants.appName
        applyPinning(to: panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentMinSize = PreviewWindowSizePreset.large.contentSize
        panel.delegate = self
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.contentView = NSHostingView(
            rootView: PreviewPanelView(
                model: model,
                sampleDisplayCoordinator: sampleDisplayCoordinator
            )
        )
        self.panel = panel
        return panel
    }

    private func ensureCompanionPanel() -> NSPanel {
        if let companionPanel {
            return companionPanel
        }

        let companionPanel = PreviewFloatingPanel(
            contentRect: CGRect(origin: .zero, size: companionPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        companionPanel.title = "Display Monitor 控制条"
        applyPinning(to: companionPanel)
        companionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        companionPanel.isReleasedWhenClosed = false
        companionPanel.hidesOnDeactivate = false
        companionPanel.becomesKeyOnlyIfNeeded = true
        companionPanel.isMovableByWindowBackground = false
        companionPanel.backgroundColor = .clear
        companionPanel.isOpaque = false
        companionPanel.hasShadow = false
        companionPanel.contentView = NSHostingView(
            rootView: PreviewCompanionControlView(model: model)
        )
        self.companionPanel = companionPanel
        return companionPanel
    }

    private func attachCompanionPanel(_ companionPanel: NSPanel, to panel: NSPanel) {
        guard panel.childWindows?.contains(where: { $0 === companionPanel }) != true else {
            return
        }
        companionPanel.parent?.removeChildWindow(companionPanel)
        panel.addChildWindow(companionPanel, ordered: .above)
    }

    private func updateCompanionPanelFrame() {
        guard let panel, let companionPanel else {
            return
        }
        let visibleFrame = visibleFrame(for: panel)
        let size = companionPanelSize
        let centeredX = clamp(
            panel.frame.midX - size.width / 2,
            minimum: visibleFrame.minX,
            maximum: visibleFrame.maxX - size.width
        )
        let belowY = panel.frame.minY - size.height - companionPanelGap
        let aboveY = panel.frame.maxY + companionPanelGap
        let origin: CGPoint

        if belowY >= visibleFrame.minY {
            origin = CGPoint(x: centeredX, y: belowY)
        } else if aboveY + size.height <= visibleFrame.maxY {
            origin = CGPoint(x: centeredX, y: aboveY)
        } else {
            let centeredY = clamp(
                panel.frame.midY - size.height / 2,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY - size.height
            )
            let rightX = panel.frame.maxX + companionPanelGap
            let leftX = panel.frame.minX - size.width - companionPanelGap
            if rightX + size.width <= visibleFrame.maxX {
                origin = CGPoint(x: rightX, y: centeredY)
            } else if leftX >= visibleFrame.minX {
                origin = CGPoint(x: leftX, y: centeredY)
            } else {
                origin = CGPoint(
                    x: centeredX,
                    y: clamp(
                        belowY,
                        minimum: visibleFrame.minY,
                        maximum: visibleFrame.maxY - size.height
                    )
                )
            }
        }
        companionPanel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func visibleFrame(for panel: NSPanel) -> CGRect {
        if let screen = panel.screen {
            return screen.visibleFrame
        }
        let bestScreen = NSScreen.screens.max { left, right in
            left.visibleFrame.intersection(panel.frame).area <
                right.visibleFrame.intersection(panel.frame).area
        }
        return bestScreen?.visibleFrame ?? mainVisibleFrame()
    }

    private func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else {
            return minimum
        }
        return min(max(value, minimum), maximum)
    }

    private func ensureCollapsedPanel() -> NSPanel {
        if let collapsedPanel {
            return collapsedPanel
        }

        let collapsedPanel = PreviewFloatingPanel(
            contentRect: defaultCollapsedFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collapsedPanel.title = "Display Monitor"
        applyPinning(to: collapsedPanel)
        collapsedPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        collapsedPanel.isReleasedWhenClosed = false
        collapsedPanel.hidesOnDeactivate = false
        collapsedPanel.isMovableByWindowBackground = false
        collapsedPanel.backgroundColor = .clear
        collapsedPanel.isOpaque = false
        collapsedPanel.hasShadow = true
        collapsedPanel.delegate = self
        collapsedPanel.contentView = NSHostingView(rootView: CollapsedPreviewButtonView(model: model))
        self.collapsedPanel = collapsedPanel
        return collapsedPanel
    }

    private func saveCurrentFrames() {
        if let panel, panel.isVisible {
            model.previewPanelFrameDidChange(panel.frame)
        }
        if let collapsedPanel, collapsedPanel.isVisible {
            model.collapsedIconFrameDidChange(collapsedPanel.frame)
        }
    }

    private func defaultFrame() -> CGRect {
        WindowFrameResolver.defaultFrame(
            in: mainVisibleFrame(),
            contentSize: model.previewWindowContentSize
        )
    }

    private func resolvedFrame(savedFrame: CGRect?) -> CGRect {
        WindowFrameResolver.resolve(
            savedFrame: savedFrame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            mainVisibleFrame: mainVisibleFrame(),
            contentSize: model.previewWindowContentSize
        )
    }

    private func defaultCollapsedFrame() -> CGRect {
        let visibleFrame = mainVisibleFrame()
        let size: CGFloat = 52
        return CGRect(
            x: visibleFrame.maxX - size - 10,
            y: visibleFrame.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func resolvedCollapsedFrame(savedFrame: CGRect?) -> CGRect {
        guard let savedFrame,
              savedFrame.width >= 40,
              savedFrame.height >= 40,
              WindowFrameResolver.hasEnoughVisibleIntersection(
                savedFrame,
                visibleFrames: NSScreen.screens.map(\.visibleFrame),
                minimumVisibleSize: CGSize(width: 24, height: 24)
              ) else {
            return defaultCollapsedFrame()
        }
        return savedFrame
    }

    private func mainVisibleFrame() -> CGRect {
        NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}

private final class PreviewFloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private struct CollapsedPreviewButtonView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Circle()
                .fill(DisplayMonitorColors.brightYellow)
            Circle()
                .strokeBorder(.white.opacity(0.72), lineWidth: 1)
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(symbolColor)

            CollapsedPreviewInteractionView(
                onActivate: {
                    model.expandPreview()
                },
                onQuit: {
                    model.quit()
                }
            )
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .help("单击展开，拖动移动，右键退出")
    }

    private var symbolName: String {
        switch model.capturePhase {
        case .paused, .pausing:
            return "pause.rectangle"
        case .failed:
            return "exclamationmark.triangle"
        case .capturing:
            return "display.and.arrow.down"
        default:
            return "display"
        }
    }

    private var symbolColor: Color {
        if case .failed = model.capturePhase {
            return .red
        }
        return .black
    }
}

private struct CollapsedPreviewInteractionView: NSViewRepresentable {
    let onActivate: () -> Void
    let onQuit: () -> Void

    func makeNSView(context: Context) -> CollapsedPreviewDragView {
        CollapsedPreviewDragView(
            onActivate: onActivate,
            onQuit: onQuit
        )
    }

    func updateNSView(_ nsView: CollapsedPreviewDragView, context: Context) {
        nsView.onActivate = onActivate
        nsView.onQuit = onQuit
    }
}

private final class CollapsedPreviewDragView: NSView {
    var onActivate: () -> Void
    var onQuit: () -> Void
    private var mouseDownLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDrag = false
    private let dragThreshold: CGFloat = 4

    init(
        onActivate: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onQuit = onQuit
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("展开 Display Monitor 预览")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let mouseDownLocation,
              let initialWindowOrigin else {
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let horizontalDistance = currentLocation.x - mouseDownLocation.x
        let verticalDistance = currentLocation.y - mouseDownLocation.y
        let distance = hypot(horizontalDistance, verticalDistance)

        if distance >= dragThreshold {
            didDrag = true
        }
        guard didDrag else {
            return
        }

        window.setFrameOrigin(
            NSPoint(
                x: initialWindowOrigin.x + horizontalDistance,
                y: initialWindowOrigin.y + verticalDistance
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = !didDrag
        mouseDownLocation = nil
        initialWindowOrigin = nil
        didDrag = false

        if shouldActivate {
            onActivate()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu(title: "Display Monitor")
        menu.autoenablesItems = false

        let quitItem = NSMenuItem(
            title: "退出 Display Monitor",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.isEnabled = true
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "退出")
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func quitApplication() {
        onQuit()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate()
        return true
    }
}
