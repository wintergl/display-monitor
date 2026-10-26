import AppKit
import OSLog

@MainActor
final class MainMenuBarStatusItemController: NSObject, ObservableObject {
    static let entryLength = NSStatusItem.variableLength
    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "MainMenuBarStatusItem"
    )
    private let quickBarController = MenuBarQuickBarPanelController()

    private var statusItem: NSStatusItem?
    private var renderedSymbol: (name: String, description: String)?
    private(set) var symbolWriteCount = 0
    var hasVisibleEntry: Bool { statusItem?.isVisible == true && statusItem?.button != nil }
    private var quickBarItems: [MenuBarQuickBarItem] = []
    private var rightClickMonitor: Any?
    private var isPresentingContextMenu = false
    private var hoverTrackingArea: NSTrackingArea?
    var hasHoverTrackingArea: Bool { hoverTrackingArea != nil }
    private var hoverTask: Task<Void, Never>?
    private var hoverEnabled = false
    private var pointerIsInside = false
    private var suppressHoverUntilExit = false
    private var activeChangePresentationID: UUID?
    private var lastPresentedChangeID: UUID?

    private(set) var presentationMode: MenuBarPrimaryPresentationMode = .nativeMenuBar
    var onRevealNativeMenuBar: (() -> Void)?
    var onQuickBarItemSelected: ((MenuBarQuickBarItem) -> Void)?
    var onQuickBarOrderApplied: (([String], [String]) -> Void)?
    var onContextMenuRequested: ((NSStatusItem) -> Void)?
    /// Carries the exact change batch that owned the dismissed panel. `nil`
    /// means an ordinary quick bar was dismissed and must not clear a newer
    /// pending change batch.
    var onQuickBarDismissed: ((UUID?) -> Void)?

    override init() {
        super.init()
        quickBarController.onDismiss = { [weak self] in
            guard let self else { return }
            let dismissedChangeID = self.activeChangePresentationID
            self.activeChangePresentationID = nil
            self.onQuickBarDismissed?(dismissedChangeID)
        }
        quickBarController.onApplyOrder = { [weak self] originalIDs, proposedIDs in
            self?.onQuickBarOrderApplied?(originalIDs, proposedIDs)
        }
    }

    func start(
        symbolName: String,
        title: String,
        accessibilityIdentifier: String
    ) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.entryLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            logger.error("main.create.failed reason=noButton")
            return
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        renderedSymbol = (symbolName, title)
        symbolWriteCount += 1
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        item.autosaveName = NSStatusItem.AutosaveName("\(AppConstants.bundleIdentifier).main")
        statusItem = item
        installPrimaryClickAction(on: button)
        installRightClickMonitor(for: item)
        synchronizeHoverTracking()
        logger.info("main.create.success")
    }

    func updateSymbol(name: String, accessibilityDescription: String) {
        guard let button = statusItem?.button,
              renderedSymbol?.name != name || renderedSymbol?.description != accessibilityDescription else { return }
        button.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        )
        renderedSymbol = (name, accessibilityDescription)
        symbolWriteCount += 1
    }

    func updatePresentationMode(_ mode: MenuBarPrimaryPresentationMode) {
        guard presentationMode != mode else { return }
        cancelHover()
        let dismissedVisibleBar = quickBarController.isVisible
        let dismissedChangeID = activeChangePresentationID
        quickBarController.dismiss(notify: false)
        activeChangePresentationID = nil
        presentationMode = mode
        synchronizeHoverTracking()
        if let button = statusItem?.button {
            installPrimaryClickAction(on: button)
        }
        logger.info("main.mode.changed mode=\(mode.rawValue, privacy: .public)")
        if dismissedVisibleBar {
            onQuickBarDismissed?(dismissedChangeID)
        }
    }

    func updateQuickBarItems(_ items: [MenuBarQuickBarItem]) {
        quickBarItems = items
    }

    /// Presents a change-only proxy layer even when the user's normal mode is
    /// the native menu bar. It never changes the saved presentation preference
    /// and never releases the active native visibility assertion.
    func updateChangePresentation(_ presentation: MenuBarChangePresentation?) {
        guard let presentation else {
            if activeChangePresentationID != nil {
                activeChangePresentationID = nil
                quickBarController.dismiss(notify: false)
            }
            return
        }
        guard presentation.id != lastPresentedChangeID,
              let statusItem else { return }
        // Never replace a panel the user is already searching or arranging.
        // Its dismissal triggers a shell synchronization and retries this batch.
        guard !quickBarController.isVisible else { return }
        lastPresentedChangeID = presentation.id
        activeChangePresentationID = presentation.id
        logger.info(
            "quickbar.change.present id=\(presentation.id.uuidString, privacy: .public) items=\(presentation.items.count, privacy: .public)"
        )
        quickBarController.show(
            items: presentation.items,
            relativeTo: statusItem
        ) { [weak self] item in
            self?.activeChangePresentationID = nil
            self?.onQuickBarItemSelected?(item)
        }
    }

    func updateHoverEnabled(_ enabled: Bool) {
        hoverEnabled = enabled
        if !enabled { cancelHover() }
        synchronizeHoverTracking()
    }

    private func synchronizeHoverTracking() {
        guard let button = statusItem?.button else { return }
        let shouldTrack = hoverEnabled && presentationMode == .quickBar
        if shouldTrack, hoverTrackingArea == nil {
            let tracking = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self, userInfo: nil)
            button.addTrackingArea(tracking)
            hoverTrackingArea = tracking
        } else if !shouldTrack, let tracking = hoverTrackingArea {
            button.removeTrackingArea(tracking)
            hoverTrackingArea = nil
            pointerIsInside = false
            cancelHover()
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        cancelHover()
        guard hoverEnabled, presentationMode == .quickBar, !suppressHoverUntilExit else { return }
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self,
                  !Task.isCancelled,
                  MenuBarQuickBarHoverPolicy.shouldPresent(
                    enabled: self.hoverEnabled,
                    quickBarMode: self.presentationMode == .quickBar,
                    pointerInside: self.pointerIsInside,
                    alreadyVisible: self.quickBarController.isVisible,
                    contextMenuOpen: self.isPresentingContextMenu,
                    mouseButtonPressed: NSEvent.pressedMouseButtons != 0,
                    suppressedUntilExit: self.suppressHoverUntilExit
                  ),
                  let item = self.statusItem else { return }
            self.presentQuickBar(relativeTo: item)
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        suppressHoverUntilExit = false
        cancelHover()
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    func stop() {
        cancelHover()
        if let hoverTrackingArea { statusItem?.button?.removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        pointerIsInside = false
        removeRightClickMonitor()
        quickBarController.stop()
        activeChangePresentationID = nil
        lastPresentedChangeID = nil
        statusItem?.button?.target = nil
        statusItem?.button?.action = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        renderedSymbol = nil
        logger.info("main.destroy")
    }

    @objc private func statusItemInvoked(_ sender: Any?) {
        guard let statusItem else { return }
        let pointerButton: MenuBarStatusItemPointerButton =
            NSApp.currentEvent?.modifierFlags.contains(.control) == true ? .secondary : .primary
        logger.info(
            "main.click button=\(pointerButton == .primary ? "primary" : "secondary", privacy: .public) mode=\(self.presentationMode.rawValue, privacy: .public) items=\(self.quickBarItems.count, privacy: .public)"
        )
        performAction(for: pointerButton, statusItem: statusItem)
    }

    private func performAction(
        for pointerButton: MenuBarStatusItemPointerButton,
        statusItem: NSStatusItem
    ) {
        cancelHover()
        suppressHoverUntilExit = true
        switch MenuBarStatusItemActionRouter.action(
            for: pointerButton,
            presentationMode: presentationMode,
            quickBarIsVisible: quickBarController.isVisible
        ) {
        case .revealNativeMenuBar:
            if quickBarController.isVisible {
                quickBarController.dismiss()
            }
            onRevealNativeMenuBar?()
        case .presentQuickBar:
            presentQuickBar(relativeTo: statusItem)
        case .dismissQuickBar:
            quickBarController.dismiss()
        case .presentContextMenu:
            presentContextMenu(relativeTo: statusItem)
        }
    }

    private func presentContextMenu(relativeTo statusItem: NSStatusItem) {
        guard !isPresentingContextMenu else { return }
        let dismissedVisibleBar = quickBarController.isVisible
        let dismissedChangeID = activeChangePresentationID
        quickBarController.dismiss(notify: false)
        activeChangePresentationID = nil
        isPresentingContextMenu = true
        defer {
            isPresentingContextMenu = false
            if dismissedVisibleBar {
                onQuickBarDismissed?(dismissedChangeID)
            }
        }
        onContextMenuRequested?(statusItem)
    }

    private func installRightClickMonitor(for statusItem: NSStatusItem) {
        removeRightClickMonitor()
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { [weak self, weak statusItem] event in
            guard let self,
                  let statusItem,
                  let button = statusItem.button,
                  event.window === button.window else { return event }
            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point) else { return event }
            DispatchQueue.main.async { [weak self, weak statusItem] in
                guard let self, let statusItem else { return }
                self.performAction(for: .secondary, statusItem: statusItem)
            }
            return nil
        }
    }

    private func removeRightClickMonitor() {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
        }
        rightClickMonitor = nil
    }

    private func presentQuickBar(relativeTo statusItem: NSStatusItem) {
        activeChangePresentationID = nil
        logger.info("quickbar.present items=\(self.quickBarItems.count, privacy: .public)")
        quickBarController.show(
            items: quickBarItems,
            relativeTo: statusItem
        ) { [weak self] item in
            self?.onQuickBarItemSelected?(item)
        }
    }

    private func installPrimaryClickAction(on button: NSStatusBarButton) {
        // Use one owner for primary-click handling. Mixing an explicit button
        // action with NSStatusItemExpandedInterfaceDelegate caused AppKit to
        // deliver the action while never beginning the expanded session.
        button.target = self
        button.action = #selector(statusItemInvoked(_:))
        button.sendAction(on: [.leftMouseUp])
    }

}
