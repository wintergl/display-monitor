import AppKit
import DisplayMonitorCore
import OSLog

private final class PinnedScreenshotScreenObserverResources {
    var screenParametersObserver: NSObjectProtocol?

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }
}

/// Owns process-local windows for screenshots intentionally pinned above other
/// applications. Pins share the canonical artifact with Quick Access, but have
/// independent placement and do not disappear after a copy or save action.
@MainActor
final class PinnedScreenshotController {
    var onStatusMessage: ((String) -> Void)?
    var onPinnedScreenshotsChanged: (() -> Void)?

    private let artifactStore: ArtifactStore
    private let screenshotSaveDirectory: () -> URL
    private let copyToPasteboard: @MainActor (ArtifactManifest, URL) throws -> Void
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "PinnedScreenshot")
    private var overlays: [UUID: PinnedScreenshotOverlay] = [:]
    private let screenObserverResources = PinnedScreenshotScreenObserverResources()

    init(
        artifactStore: ArtifactStore,
        screenshotSaveDirectory: @escaping () -> URL = {
            ScreenshotOutputLocation.defaultDirectory()
        },
        copyToPasteboard: @MainActor @escaping (ArtifactManifest, URL) throws -> Void =
            ArtifactFileActions.writeToPasteboard
    ) {
        self.artifactStore = artifactStore
        self.screenshotSaveDirectory = screenshotSaveDirectory
        self.copyToPasteboard = copyToPasteboard
        installScreenParametersObserver()
    }

    var hasPinnedScreenshots: Bool {
        !overlays.isEmpty
    }

    func present(_ artifact: ArtifactManifest) async {
        guard isPinnable(artifact), let sourceURL = ArtifactFileActions.usableURL(for: artifact) else {
            report("当前产物不能固定到桌面")
            return
        }
        guard let image = NSImage(contentsOf: sourceURL) else {
            report("无法读取截图，未固定到桌面")
            return
        }

        if let overlay = overlays[artifact.id] {
            overlay.artifact = artifact
            overlay.panel.orderFrontRegardless()
            return
        }

        let visibleFrame = Self.screen(for: artifact)?.visibleFrame ?? Self.fallbackVisibleFrame
        let frame = PinnedScreenshotPlacement.initialFrame(
            selectionFrame: artifact.captureRegion?.selectionRectInAppKitGlobalPoints,
            imagePixelSize: artifact.dimensions,
            pixelScale: artifact.captureRegion?.pixelScale,
            visibleFrame: visibleFrame,
            cascadeIndex: overlays.count
        )
        let panel = makePanel()
        let overlay = PinnedScreenshotOverlay(artifact: artifact, panel: panel, initialSize: frame.size)
        let content = PinnedScreenshotContentView(
            image: image,
            onCopy: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.copyArtifact(id: overlay.artifact.id)
            },
            onSave: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.saveArtifact(id: overlay.artifact.id)
            },
            onClose: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.dismiss(id: overlay.artifact.id)
            },
            onCloseAll: { [weak self] in
                self?.dismissAll()
            },
            onScale: { [weak self, weak overlay] scale in
                guard let self, let overlay else { return }
                self.setPresentation(for: overlay, scale: scale, opacity: overlay.opacity)
            },
            onOpacity: { [weak self, weak overlay] opacity in
                guard let self, let overlay else { return }
                self.setPresentation(for: overlay, scale: overlay.scale, opacity: opacity)
            }
        )
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        panel.setContentSize(frame.size)
        panel.setFrame(frame, display: true, animate: false)
        overlays[artifact.id] = overlay
        panel.orderFrontRegardless()
        onPinnedScreenshotsChanged?()
        logger.info("pin.presented artifact=\(artifact.id.uuidString, privacy: .public)")
        report("截图已固定到桌面，悬停可调倍率，右键可调透明度；复制保存保留原图")
    }

    func dismissAll() {
        guard !overlays.isEmpty else { return }
        for id in Array(overlays.keys) {
            dismiss(id: id, restoresRemainingPins: false)
        }
        report("已清理所有贴图")
    }

    private func copyArtifact(id: UUID) {
        guard let overlay = overlays[id],
              let sourceURL = ArtifactFileActions.usableURL(for: overlay.artifact) else {
            report("当前截图不可复制，贴图已保留")
            return
        }

        do {
            try copyToPasteboard(overlay.artifact, sourceURL)
            report("已复制截图，贴图保持显示")
        } catch {
            report("复制失败，贴图已保留：\(error.localizedDescription)")
        }
    }

    private func saveArtifact(id: UUID) {
        guard let overlay = overlays[id],
              let sourceURL = ArtifactFileActions.usableURL(for: overlay.artifact) else {
            report("当前截图不可保存，贴图已保留")
            return
        }
        let artifact = overlay.artifact

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let destination = try ArtifactFileActions.saveCopy(
                    artifact,
                    sourceURL: sourceURL,
                    directory: self.screenshotSaveDirectory()
                )
                do {
                    _ = try await self.artifactStore.setDesktopExportURL(destination, for: artifact.id)
                    self.report("已保存：\(destination.lastPathComponent)，贴图保持显示")
                } catch {
                    self.report("已保存：\(destination.lastPathComponent)，但未记录导出位置：\(error.localizedDescription)")
                }
            } catch {
                self.report("保存失败，贴图已保留：\(error.localizedDescription)")
            }
        }
    }

    private func dismiss(id: UUID, restoresRemainingPins: Bool = true) {
        guard let overlay = overlays.removeValue(forKey: id) else { return }
        overlay.panel.orderOut(nil)
        overlay.panel.contentView = nil
        overlay.panel.close()
        onPinnedScreenshotsChanged?()
        logger.info("pin.dismissed artifact=\(id.uuidString, privacy: .public) remaining=\(self.overlays.count)")
        if restoresRemainingPins {
            showRemainingPins()
        }
    }

    private func showRemainingPins() {
        overlays.values.forEach { $0.panel.orderFrontRegardless() }
    }

    private func setPresentation(for overlay: PinnedScreenshotOverlay, scale: Double, opacity: Double) {
        guard scale.isFinite, opacity.isFinite else { return }
        overlay.scale = min(4, max(0.25, scale))
        overlay.opacity = min(1, max(0.25, opacity))
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let target = PinnedScreenshotPlacement.preferredVisibleFrame(for: overlay.panel.frame, among: visibleFrames)
            ?? Self.fallbackVisibleFrame
        let frame = PinnedScreenshotPlacement.scaledFrame(
            initialSize: overlay.initialSize,
            scale: overlay.scale,
            currentFrame: overlay.panel.frame,
            visibleFrame: target
        )
        overlay.panel.setFrame(frame, display: true, animate: false)
        (overlay.panel.contentView as? PinnedScreenshotContentView)?.setPresentation(scale: overlay.scale, opacity: overlay.opacity)
    }

    private func isPinnable(_ artifact: ArtifactManifest) -> Bool {
        guard artifact.status.isTerminal,
              artifact.status != .failed,
              artifact.status != .discarded else {
            return false
        }
        switch artifact.kind {
        case .still, .scrollStill, .revision:
            return true
        case .recording, .gif:
            return false
        }
    }

    private func makePanel() -> PinnedScreenshotPanel {
        let panel = PinnedScreenshotPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "固定截图"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func installScreenParametersObserver() {
        guard screenObserverResources.screenParametersObserver == nil else { return }
        screenObserverResources.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.keepPinsReachable()
            }
        }
    }

    private func keepPinsReachable() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }
        for overlay in overlays.values {
            let frame = overlay.panel.frame
            let requiredWidth = min(PinnedScreenshotPlacement.minimumVisibleSize.width, frame.width)
            let requiredHeight = min(PinnedScreenshotPlacement.minimumVisibleSize.height, frame.height)
            let remainsReachable = visibleFrames.contains { visibleFrame in
                let intersection = frame.intersection(visibleFrame)
                return !intersection.isNull &&
                    intersection.width >= requiredWidth &&
                    intersection.height >= requiredHeight
            }
            guard !remainsReachable else { continue }
            let target = Self.screen(for: overlay.artifact)?.visibleFrame
                ?? PinnedScreenshotPlacement.preferredVisibleFrame(for: frame, among: visibleFrames)
                ?? visibleFrames[0]
            overlay.panel.setFrame(
                PinnedScreenshotPlacement.clampedDraggedFrame(frame, in: target),
                display: true,
                animate: false
            )
        }
    }

    private func report(_ message: String) {
        logger.info("pin.message \(message, privacy: .public)")
        onStatusMessage?(message)
    }

    private static func screen(for artifact: ArtifactManifest) -> NSScreen? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let displayID = artifact.displayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == displayID
           }) {
            return screen
        }
        if let selectionFrame = artifact.captureRegion?.selectionRectInAppKitGlobalPoints {
            let center = CGPoint(x: selectionFrame.midX, y: selectionFrame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static var fallbackVisibleFrame: CGRect {
        CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

@MainActor
private final class PinnedScreenshotOverlay {
    var artifact: ArtifactManifest
    let panel: PinnedScreenshotPanel
    let initialSize: CGSize
    var scale: Double = 1
    var opacity: Double = 1

    init(artifact: ArtifactManifest, panel: PinnedScreenshotPanel, initialSize: CGSize) {
        self.artifact = artifact
        self.panel = panel
        self.initialSize = initialSize
    }
}

private final class PinnedScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            orderFrontRegardless()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PinnedScreenshotContentView: NSView {
    private let image: NSImage
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onClose: () -> Void
    private let onCloseAll: () -> Void
    private let onScale: (Double) -> Void
    private let onOpacity: (Double) -> Void
    private let closeButton: PinnedScreenshotIconButton
    private let presentationControls = NSStackView()
    private let scaleLabel = NSTextField(labelWithString: "100% · 不透明")
    private var presentationScale: Double = 1
    private var presentationOpacity: Double = 1
    private var controlsVisible = false
    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var didDrag = false
    private let dragThreshold: CGFloat = 4

    init(
        image: NSImage,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onCloseAll: @escaping () -> Void,
        onScale: @escaping (Double) -> Void = { _ in },
        onOpacity: @escaping (Double) -> Void = { _ in }
    ) {
        self.image = image
        self.onCopy = onCopy
        self.onSave = onSave
        self.onClose = onClose
        self.onCloseAll = onCloseAll
        self.onScale = onScale
        self.onOpacity = onOpacity
        closeButton = PinnedScreenshotIconButton(
            symbol: "xmark",
            toolTip: "关闭贴图",
            accessibilityLabel: "关闭贴图",
            action: onClose
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.68).cgColor
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("固定截图，可拖动移动，悬停调整相对初始尺寸的倍率，右键调整透明度、复制、保存或关闭")

        closeButton.alphaValue = 0
        closeButton.isHidden = true
        addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        let smaller = NSButton(title: "−", target: self, action: #selector(decreaseScale))
        let larger = NSButton(title: "+", target: self, action: #selector(increaseScale))
        smaller.toolTip = "缩小贴图（不改原图）"
        larger.toolTip = "放大贴图（不改原图）"
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        scaleLabel.textColor = .white
        scaleLabel.alignment = .center
        scaleLabel.toolTip = "倍率相对初始贴图尺寸；右键可恢复初始尺寸或调整透明度"
        presentationControls.orientation = .horizontal
        presentationControls.spacing = 3
        [smaller, scaleLabel, larger].forEach { presentationControls.addArrangedSubview($0) }
        presentationControls.wantsLayer = true
        presentationControls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        presentationControls.layer?.cornerRadius = 6
        presentationControls.isHidden = true
        addSubview(presentationControls)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        presentationControls.frame = CGRect(x: 7, y: 7, width: min(190, max(0, bounds.width - 14)), height: 27)
        presentationControls.isHidden = !controlsVisible || bounds.width < 160 || bounds.height < 65
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.14 * presentationOpacity).setFill()
        bounds.fill()

        let drawingBounds = bounds.insetBy(dx: 1, dy: 1)
        guard drawingBounds.width > 0, drawingBounds.height > 0 else { return }
        let sourceSize = imageSourceSize
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let scale = min(drawingBounds.width / sourceSize.width, drawingBounds.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let rect = CGRect(
            x: drawingBounds.midX - size.width / 2,
            y: drawingBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: presentationOpacity,
            respectFlipped: true,
            hints: nil
        )
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        didDrag = false
        window?.orderFrontRegardless()
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
        if hypot(horizontalDistance, verticalDistance) >= dragThreshold {
            didDrag = true
        }
        guard didDrag else { return }
        NSCursor.closedHand.set()
        window.setFrameOrigin(
            NSPoint(
                x: initialWindowOrigin.x + horizontalDistance,
                y: initialWindowOrigin.y + verticalDistance
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            initialWindowOrigin = nil
            didDrag = false
            NSCursor.openHand.set()
        }
        guard didDrag,
              let window,
              let visibleFrame = PinnedScreenshotPlacement.preferredVisibleFrame(
                  for: window.frame,
                  among: NSScreen.screens.map(\.visibleFrame)
              ) else {
            return
        }
        window.setFrame(
            PinnedScreenshotPlacement.clampedDraggedFrame(window.frame, in: visibleFrame),
            display: true,
            animate: false
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "固定截图")
        menu.autoenablesItems = false
        menu.addItem(menuItem(title: "复制图片", symbol: "doc.on.doc", action: #selector(copyFromContextMenu)))
        menu.addItem(menuItem(title: "保存到设定位置", symbol: "square.and.arrow.down", action: #selector(saveFromContextMenu)))
        menu.addItem(.separator())
        let scaleMenu = NSMenu(title: "倍率（相对初始尺寸）")
        for value in [0.25, 0.5, 1, 1.5, 2, 3, 4] {
            let item = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(scaleFromContextMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = abs(presentationScale - value) < 0.001 ? .on : .off
            scaleMenu.addItem(item)
        }
        let scaleItem = NSMenuItem(title: "倍率（相对初始尺寸）", action: nil, keyEquivalent: "")
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)
        menu.addItem(menuItem(title: "恢复初始尺寸", symbol: "arrow.counterclockwise", action: #selector(resetScale)))
        let opacityMenu = NSMenu(title: "不透明度")
        for value in [1.0, 0.75, 0.5, 0.25] {
            let item = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(opacityFromContextMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = abs(presentationOpacity - value) < 0.001 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "关闭贴图", symbol: "xmark", action: #selector(closeFromContextMenu)))
        menu.addItem(menuItem(title: "关闭全部贴图", symbol: "xmark.circle", action: #selector(closeAllFromContextMenu)))
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        closeButton.isHidden = !visible
        closeButton.alphaValue = visible ? 1 : 0
        needsLayout = true
    }

    func setPresentation(scale: Double, opacity: Double) {
        presentationScale = scale
        presentationOpacity = opacity
        scaleLabel.stringValue = "\(Int((scale * 100).rounded()))% · \(Int((opacity * 100).rounded()))% 不透明"
        needsDisplay = true
    }

    @objc private func decreaseScale() { onScale(max(0.25, presentationScale - 0.25)) }
    @objc private func increaseScale() { onScale(min(4, presentationScale + 0.25)) }
    @objc private func resetScale() { onScale(1) }
    @objc private func scaleFromContextMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        onScale(value.doubleValue)
    }
    @objc private func opacityFromContextMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        onOpacity(value.doubleValue)
    }

    @objc private func copyFromContextMenu() {
        onCopy()
    }

    @objc private func saveFromContextMenu() {
        onSave()
    }

    @objc private func closeFromContextMenu() {
        onClose()
    }

    @objc private func closeAllFromContextMenu() {
        onCloseAll()
    }

    private var imageSourceSize: CGSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let representation = image.representations.first,
           representation.pixelsWide > 0,
           representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return CGSize(width: 1, height: 1)
    }

    private func menuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

private final class PinnedScreenshotIconButton: NSButton {
    private let handler: () -> Void

    init(
        symbol: String,
        toolTip: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        handler = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageOnly
        bezelStyle = .circular
        isBordered = true
        contentTintColor = .labelColor
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityLabel)
        target = self
        self.action = #selector(trigger)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func trigger() {
        handler()
    }
}
