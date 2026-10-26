import AppKit
import OSLog
import SwiftUI

private final class MenuBarQuickBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarQuickBarPanelController: NSObject, NSWindowDelegate {
    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "MenuBarQuickBar"
    )
    private let model = MenuBarQuickBarModel()
    private var panel: MenuBarQuickBarPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var monitorGeneration = UUID()
    private var isDismissing = false
    private weak var anchorStatusItem: NSStatusItem?

    private(set) var isVisible = false
    var onDismiss: (() -> Void)?
    var onApplyOrder: (([String], [String]) -> Void)?

    override init() {
        super.init()
        model.onPresentationChanged = { [weak self] in
            self?.updatePresentation()
        }
        model.onDismissRequested = { [weak self] in
            self?.dismiss()
        }
        model.onApplyReorder = { [weak self] proposedIDs in
            guard let self else { return }
            let originalIDs = self.model.originalItemIDs
            self.dismiss()
            self.onApplyOrder?(originalIDs, proposedIDs)
        }
    }

    func show(
        items: [MenuBarQuickBarItem],
        relativeTo statusItem: NSStatusItem,
        onSelect: @escaping (MenuBarQuickBarItem) -> Void
    ) {
        anchorStatusItem = statusItem
        model.update(items: items) { [weak self] item in
            self?.dismiss()
            onSelect(item)
        }

        let panel = panel ?? makePanel()
        let size = preferredSize(for: items, statusItem: statusItem)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: panel, statusItem: statusItem, size: size))
        isVisible = true
        panel.orderFrontRegardless()
        installMouseMonitors(panel: panel, statusItem: statusItem)
        logger.info("panel.show items=\(items.count, privacy: .public)")
    }

    func dismiss(notify: Bool = true) {
        guard !isDismissing else { return }
        guard isVisible || panel?.isVisible == true else { return }
        isDismissing = true
        defer { isDismissing = false }
        removeMouseMonitors()
        isVisible = false
        panel?.orderOut(nil)
        model.resetPresentation()
        anchorStatusItem = nil
        logger.info("panel.dismiss notify=\(notify, privacy: .public)")
        if notify { onDismiss?() }
    }

    func stop() {
        dismiss(notify: false)
        removeMouseMonitors()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        isVisible = false
    }

    private func updatePresentation() {
        guard isVisible, let panel, let statusItem = anchorStatusItem else { return }
        let size = preferredSize(for: model.items, statusItem: statusItem)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: panel, statusItem: statusItem, size: size))
        // Typing belongs to this panel only after an explicit search action.
        // Ordinary icon browsing keeps the frontmost application's focus.
        if model.isSearchVisible {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    private func makePanel() -> MenuBarQuickBarPanel {
        let panel = MenuBarQuickBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // This is a nonactivating menu-bar panel. Requiring key status made it
        // resign immediately in an accessory app and disappear as it opened.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MenuBarQuickBarView(model: model))
        self.panel = panel
        return panel
    }

    private func preferredSize(
        for items: [MenuBarQuickBarItem],
        statusItem: NSStatusItem
    ) -> CGSize {
        let visibleFrame = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let maximumWidth = max(1, visibleFrame.width - 16)
        let width = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: items.map { $0.iconSnapshot?.pointSize },
            maximumWidth: maximumWidth,
            isSearchVisible: model.isSearchVisible,
            hasReorderDraft: model.hasReorderDraft
        )
        return CGSize(width: width, height: MenuBarQuickBarLayoutPolicy.panelHeight)
    }

    private func origin(
        for panel: NSPanel,
        statusItem: NSStatusItem,
        size: CGSize
    ) -> CGPoint {
        guard let button = statusItem.button,
              let window = button.window else {
            let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
            return CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - size.height)
        }
        let anchorFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let desiredX = anchorFrame.midX - size.width / 2
        let x = min(max(desiredX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        let desiredY = anchorFrame.minY - size.height - 6
        let y = max(desiredY, visibleFrame.minY + 8)
        return CGPoint(x: x, y: y)
    }

    private func installMouseMonitors(panel: NSPanel, statusItem: NSStatusItem) {
        removeMouseMonitors()
        let generation = monitorGeneration
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self, weak panel, weak statusItem] event in
            guard let self, let panel, self.isVisible else { return event }
            if event.type == .keyDown {
                if event.window === panel,
                   self.model.handleKeyDown(keyCode: event.keyCode) {
                    return nil
                }
                let decision = MenuBarQuickBarEscapePolicy.decision(
                    keyCode: event.keyCode,
                    source: .local
                )
                guard decision != .ignore else { return event }
                self.dismiss()
                return decision == .dismissAndConsume ? nil : event
            }
            let clickedAnchor: Bool
            if let button = statusItem?.button,
               event.window === button.window {
                let point = button.convert(event.locationInWindow, from: nil)
                clickedAnchor = button.bounds.contains(point)
            } else {
                clickedAnchor = false
            }
            if event.window !== panel, !clickedAnchor {
                self.dismiss()
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown,
               MenuBarQuickBarEscapePolicy.decision(keyCode: event.keyCode, source: .global) == .ignore {
                return
            }
            // Global observation leaves the frontmost app in control of its
            // keyboard. Ignore a queued callback from an older presentation.
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation else { return }
                self.dismiss()
            }
        }
    }

    private func removeMouseMonitors() {
        monitorGeneration = UUID()
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        localMouseMonitor = nil
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        globalMouseMonitor = nil
    }

}
