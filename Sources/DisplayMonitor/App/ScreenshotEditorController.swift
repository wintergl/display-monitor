import AppKit
import CoreImage
import DisplayMonitorCore
import OSLog
import UniformTypeIdentifiers

struct ScreenshotEditorCloseResult {
    let pngData: Data
    let fileURL: URL
}

private extension ScreenshotAnnotationTool {
    static let toolbarTools: [ScreenshotAnnotationTool] = [
        .select, .arrow, .rectangle, .text, .blur, .pixelate, .crop
    ]

    static let advancedTools: [ScreenshotAnnotationTool] = [
        .line, .ellipse, .pen, .filledRectangle, .highlighter, .spotlight, .counter
    ]

    var title: String {
        switch self {
        case .select: return "选择"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .filledRectangle: return "实心矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .text: return "文字"
        case .blur: return "模糊"
        case .pixelate: return "打码"
        case .spotlight: return "聚光灯"
        case .counter: return "步骤编号"
        case .crop: return "裁剪"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .blur: return "eye.slash"
        case .pixelate: return "square.grid.3x3"
        case .spotlight: return "light.max"
        case .counter: return "list.number"
        case .crop: return "crop"
        }
    }

    var hint: String {
        switch self {
        case .select: return "选择标注后可移动、缩放或按 Delete 删除"
        case .arrow: return "拖动以添加箭头"
        case .line: return "拖动以添加直线"
        case .rectangle: return "拖动以框选重点区域"
        case .filledRectangle: return "拖动以添加半透明色块"
        case .ellipse: return "拖动以圈选重点区域"
        case .pen: return "按住鼠标自由绘制"
        case .highlighter: return "拖动以添加半透明高亮"
        case .text: return "单击图片位置后输入文字"
        case .blur: return "拖动以模糊敏感内容"
        case .pixelate: return "拖动以像素化遮挡敏感内容"
        case .spotlight: return "拖动以突出区域并压暗周围"
        case .counter: return "单击以添加连续步骤编号"
        case .crop: return "拖动保留区域，裁剪后可撤销"
        }
    }
}

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private final class EditorWindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private static var editorWindows: [EditorWindowReference] = []
    var onClose: ((ScreenshotEditorCloseResult?) -> Void)?
    var onToolSelected: ((ScreenshotAnnotationTool) -> Void)?
    /// The editor never mutates its source artifact. The owning artifact
    /// controller turns this rendered data into a new revision artifact.
    var onSaveRevision: (@MainActor (Data) async throws -> ArtifactManifest)?
    var onExportRevision: (@MainActor (ArtifactManifest, URL) async throws -> Void)?
    var currentAnnotationTool: ScreenshotAnnotationTool { canvas.tool }

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ScreenshotEditor")
    private let fileURL: URL
    private let canvas: ScreenshotAnnotationCanvasView
    private let statusLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let saveStatusLabel = NSTextField(labelWithString: "原图已保留")
    private let saveButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "位置 0–100%")
    private let verticalScroller = NSScroller(frame: CGRect(x: 0, y: 0, width: 14, height: 200))
    private let topButton = NSButton()
    private let bottomButton = NSButton()
    private var viewportButtons: [Int: NSButton] = [:]
    private var lastPresentedStateID: UUID?
    private var saveStatusIsWorking = false
    private var savePresentationSequence: UInt64 = 0
    private let annotationColors: [(name: String, color: NSColor)] = [
        ("红色", .systemRed),
        ("橙色", .systemOrange),
        ("黄色", .systemYellow),
        ("绿色", .systemGreen),
        ("蓝色", .systemBlue),
        ("白色", .white)
    ]
    private let colorPaletteControl = NSSegmentedControl()
    private let lineWidthControl = NSSegmentedControl(
        labels: ["细", "中", "粗"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let advancedToolPopup = NSPopUpButton()
    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private var savedStateID: UUID
    private var saveTask: Task<Bool, Never>?
    private var renderActionTask: Task<Void, Never>?
    private var lastSavedArtifact: ArtifactManifest?
    private var windowIsClosed = false
    var hasUnsavedChanges: Bool { canvas.documentStateID != savedStateID }
    var isSaving: Bool { saveTask != nil }
    private var allowsImmediateClose = false
    private var sharingPicker: NSSharingServicePicker?
    private var lastSavedResult: ScreenshotEditorCloseResult?
    private var pendingCloseResult: ScreenshotEditorCloseResult?

    init(
        image: CGImage,
        fileURL: URL,
        preferredScreen: NSScreen?,
        initialTool: ScreenshotAnnotationTool = .arrow
    ) {
        self.fileURL = fileURL
        canvas = ScreenshotAnnotationCanvasView(image: image, sourceURL: fileURL)
        savedStateID = canvas.documentStateID

        let visibleFrame = preferredScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1280, max(820, visibleFrame.width - 48))
        let height = min(820, max(500, visibleFrame.height - 64))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑截图 — \(fileURL.lastPathComponent)"
        window.minSize = CGSize(width: min(820, visibleFrame.width), height: min(500, visibleFrame.height))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .documentWindow
        Self.editorWindows.removeAll { $0.window == nil }
        window.setFrame(ScreenshotEditorWindowPlacement.frame(size: window.frame.size,
            visibleFrame: visibleFrame, previousFrame: Self.editorWindows.last?.window?.frame), display: false)
        Self.editorWindows.append(EditorWindowReference(window))

        super.init(window: window)
        window.delegate = self
        configureContent()
        selectTool(initialTool)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showEditor() {
        AppWindowActivation.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func closeWithoutConfirmation() {
        allowsImmediateClose = true
        pendingCloseResult = nil
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allowsImmediateClose || !isSaving else {
            showStatus("正在保存，请等保存完成后关闭", isError: false)
            return false
        }
        guard canvas.commitInlineTextIfNeeded() else { return false }
        guard !allowsImmediateClose, canvas.documentStateID != savedStateID else {
            if !allowsImmediateClose {
                pendingCloseResult = makeCloseResult(
                    fileURL: lastSavedResult?.fileURL ?? fileURL
                )
            }
            return true
        }

        let alert = NSAlert()
        alert.messageText = "保存截图标注吗？"
        alert.informativeText = "关闭编辑器会丢弃尚未保存的标注。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存并关闭")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginSave(closeAfterSaving: true)
            return false
        case .alertSecondButtonReturn:
            allowsImmediateClose = true
            pendingCloseResult = lastSavedResult
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        windowIsClosed = true
        Self.editorWindows.removeAll { $0.window == nil || $0.window === window }
        onClose?(pendingCloseResult)
    }

    private func configureContent() {
        guard let window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = NSVisualEffectView()
        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active

        let toolbarStack = NSStackView()
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 4
        toolbarStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        for tool in ScreenshotAnnotationTool.toolbarTools {
            if tool == .arrow || tool == .blur { toolbarStack.addArrangedSubview(makeSeparator()) }
            let button = makeToolButton(tool)
            toolButtons[tool] = button
            toolbarStack.addArrangedSubview(button)
        }

        advancedToolPopup.addItem(withTitle: "更多")
        advancedToolPopup.menu?.addItem(.separator())
        for tool in ScreenshotAnnotationTool.advancedTools {
            let item = NSMenuItem(title: tool.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
            item.representedObject = tool.rawValue
            advancedToolPopup.menu?.addItem(item)
        }
        advancedToolPopup.target = self
        advancedToolPopup.action = #selector(advancedToolPressed)
        advancedToolPopup.toolTip = "更多标注工具"
        advancedToolPopup.setAccessibilityLabel("更多标注工具")
        advancedToolPopup.widthAnchor.constraint(equalToConstant: 72).isActive = true
        advancedToolPopup.heightAnchor.constraint(equalToConstant: 30).isActive = true
        toolbarStack.addArrangedSubview(advancedToolPopup)

        toolbarStack.addArrangedSubview(makeSeparator())

        colorPaletteControl.segmentCount = annotationColors.count
        colorPaletteControl.trackingMode = .selectOne
        colorPaletteControl.segmentStyle = .rounded
        colorPaletteControl.selectedSegment = 0
        colorPaletteControl.target = self
        colorPaletteControl.action = #selector(colorChanged)
        colorPaletteControl.toolTip = "标注颜色"
        colorPaletteControl.setAccessibilityLabel("标注颜色")
        for (index, entry) in annotationColors.enumerated() {
            colorPaletteControl.setImage(
                Self.colorSwatchImage(color: entry.color),
                forSegment: index
            )
            colorPaletteControl.setToolTip(entry.name, forSegment: index)
            colorPaletteControl.setWidth(16, forSegment: index)
        }
        colorPaletteControl.widthAnchor.constraint(equalToConstant: 96).isActive = true
        colorPaletteControl.heightAnchor.constraint(equalToConstant: 28).isActive = true
        toolbarStack.addArrangedSubview(colorPaletteControl)

        lineWidthControl.selectedSegment = 1
        lineWidthControl.font = .systemFont(ofSize: 11)
        lineWidthControl.target = self
        lineWidthControl.action = #selector(lineWidthChanged)
        lineWidthControl.toolTip = "线条粗细"
        lineWidthControl.setAccessibilityLabel("线条粗细")
        lineWidthControl.widthAnchor.constraint(equalToConstant: 66).isActive = true
        toolbarStack.addArrangedSubview(lineWidthControl)
        toolbarStack.addArrangedSubview(makeSeparator())

        configureIconButton(
            undoButton,
            symbol: "arrow.uturn.backward",
            accessibilityLabel: "撤销",
            action: #selector(undoPressed)
        )
        configureIconButton(
            redoButton,
            symbol: "arrow.uturn.forward",
            accessibilityLabel: "重做",
            action: #selector(redoPressed)
        )
        toolbarStack.addArrangedSubview(undoButton)
        toolbarStack.addArrangedSubview(redoButton)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarStack.addArrangedSubview(spacer)

        saveStatusLabel.identifier = NSUserInterfaceItemIdentifier("editor.save-status")
        saveStatusLabel.font = .systemFont(ofSize: 11)
        saveStatusLabel.textColor = .secondaryLabelColor
        saveStatusLabel.lineBreakMode = .byTruncatingMiddle
        saveStatusLabel.alignment = .right
        saveStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        saveStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        toolbarStack.addArrangedSubview(saveStatusLabel)
        saveButton.title = "保存"
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存编辑副本")
        saveButton.imagePosition = .imageLeading
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.contentTintColor = .white
        saveButton.font = .systemFont(ofSize: 12, weight: .medium)
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.toolTip = "保存编辑副本（⌘S），原图保留"
        saveButton.setAccessibilityLabel("保存编辑副本")
        toolbarStack.addArrangedSubview(saveButton)

        let fileActions = [
            makeToolbarButton(title: "复制", symbol: "doc.on.doc", action: #selector(copyPressed)),
            makeToolbarButton(title: "另存为…", symbol: "folder", action: #selector(saveAsPressed)),
            makeToolbarButton(title: "分享", symbol: "square.and.arrow.up", action: #selector(sharePressed))
        ]

        toolbar.addSubview(toolbarStack)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarStack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail

        let viewportControls = NSStackView()
        viewportControls.orientation = .horizontal
        viewportControls.spacing = 5
        viewportControls.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for (title, tag) in [("适应窗口", 0), ("适应宽度", 1), ("100%", 2), ("−", 3), ("+", 4)] {
            let button = NSButton(title: title, target: self, action: #selector(viewportPressed))
            button.tag = tag
            button.bezelStyle = .rounded
            if tag <= 2 { button.setButtonType(.toggle) }
            button.font = .systemFont(ofSize: 11)
            button.setAccessibilityLabel(title == "−" ? "缩小" : title == "+" ? "放大" : title)
            viewportControls.addArrangedSubview(button)
            viewportButtons[tag] = button
        }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        viewportControls.addArrangedSubview(zoomLabel)
        viewportControls.addArrangedSubview(makeSeparator())
        configureNavigationButton(topButton, symbol: "arrow.up.to.line", label: "回到顶部", tag: 0)
        configureNavigationButton(bottomButton, symbol: "arrow.down.to.line", label: "回到底部", tag: 1)
        viewportControls.addArrangedSubview(topButton)
        positionLabel.identifier = NSUserInterfaceItemIdentifier("editor.viewport-position")
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        positionLabel.alignment = .center
        positionLabel.textColor = .secondaryLabelColor
        positionLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        viewportControls.addArrangedSubview(positionLabel)
        viewportControls.addArrangedSubview(bottomButton)
        let viewportHint = NSTextField(labelWithString: "滚轮平移 · 捏合 / ⌘滚轮缩放 · 空格拖动")
        viewportHint.font = .systemFont(ofSize: 11)
        viewportHint.textColor = .secondaryLabelColor
        let viewportSpacer = NSView()
        viewportSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewportControls.addArrangedSubview(viewportSpacer)
        fileActions.forEach { viewportControls.addArrangedSubview($0) }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, viewportHint])
        footer.orientation = .horizontal
        footer.spacing = 12

        root.addSubview(toolbar)
        root.addSubview(viewportControls)
        root.addSubview(canvas)
        verticalScroller.identifier = NSUserInterfaceItemIdentifier("editor.vertical-scroller")
        verticalScroller.controlSize = .small
        verticalScroller.scrollerStyle = .legacy
        verticalScroller.target = self
        verticalScroller.action = #selector(scrollerChanged)
        verticalScroller.setAccessibilityLabel("长图垂直位置")
        root.addSubview(verticalScroller)
        root.addSubview(footer)
        for view in [toolbar, viewportControls, canvas, verticalScroller, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),

            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: verticalScroller.leadingAnchor),
            verticalScroller.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            verticalScroller.topAnchor.constraint(equalTo: canvas.topAnchor),
            verticalScroller.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            verticalScroller.widthAnchor.constraint(equalToConstant: NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)),
            viewportControls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            viewportControls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            viewportControls.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            viewportControls.heightAnchor.constraint(equalToConstant: 32),
            canvas.topAnchor.constraint(equalTo: viewportControls.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            footer.heightAnchor.constraint(equalToConstant: 20)
        ])

        canvas.onDocumentChange = { [weak self] _ in
            self?.updateDocumentStatus()
        }
        canvas.onSelectionChange = { [weak self] in
            self?.updateDocumentStatus()
        }
        canvas.onCopyRequest = { [weak self] in self?.copyEditedImage() }
        canvas.onSaveRequest = { [weak self] in self?.beginSave() }
        canvas.onViewportChange = { [weak self] _ in
            self?.updateViewportPresentation()
        }
        window.contentView = root
        updateHistoryButtons()
    }

    private func makeToolButton(_ tool: ScreenshotAnnotationTool) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title) ?? NSImage(),
            target: self,
            action: #selector(toolPressed)
        )
        button.tag = ScreenshotAnnotationTool.allCases.firstIndex(of: tool) ?? 0
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.toolTip = tool.title
        button.setAccessibilityLabel(tool.title)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.target = self
        button.action = action
        button.bezelStyle = .texturedRounded
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func makeToolbarButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11.5)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    private func configureNavigationButton(_ button: NSButton, symbol: String, label: String, tag: Int) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(navigationPressed)
        button.tag = tag
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
    }

    private func updateViewportPresentation() {
        let transform = canvas.viewportTransform
        zoomLabel.stringValue = String(format: "%.0f%%", transform.displayZoom * 100)
        let selectedTag: Int?
        switch transform.mode {
        case .fit: selectedTag = 0
        case .fitWidth: selectedTag = 1
        case .actualPixels: selectedTag = 2
        case .manual: selectedTag = nil
        }
        for (tag, button) in viewportButtons where tag <= 2 {
            button.state = selectedTag == tag ? .on : .off
            button.setAccessibilityValue(selectedTag == tag ? "已选择" : nil)
        }
        let state = ScreenshotEditorNavigationState(transform: transform)
        verticalScroller.doubleValue = Double(state.position)
        verticalScroller.knobProportion = state.knobProportion
        verticalScroller.isEnabled = state.canScroll
        verticalScroller.isHidden = !state.canScroll
        topButton.isEnabled = state.canScroll && state.position > 0.0001
        bottomButton.isEnabled = state.canScroll && state.position < 0.9999
        positionLabel.stringValue = state.label
        positionLabel.toolTip = state.canScroll ? "拖动右侧滚动条可快速定位长图" : "整张图片已在视野内"
    }

    @objc private func navigationPressed(_ sender: NSButton) {
        canvas.scrollViewport(to: sender.tag == 0 ? 0 : 1)
    }

    @objc private func scrollerChanged(_ sender: NSScroller) {
        let state = ScreenshotEditorNavigationState(transform: canvas.viewportTransform)
        var position = CGFloat(sender.doubleValue)
        switch sender.hitPart {
        case .decrementLine: position = state.position - min(0.1, state.pageFraction / 8)
        case .incrementLine: position = state.position + min(0.1, state.pageFraction / 8)
        case .decrementPage: position = state.position - state.pageFraction * 0.9
        case .incrementPage: position = state.position + state.pageFraction * 0.9
        default: break
        }
        canvas.scrollViewport(to: position)
    }

    private static func colorSwatchImage(color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            circle.fill()
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }

    @objc private func toolPressed(_ sender: NSButton) {
        guard ScreenshotAnnotationTool.allCases.indices.contains(sender.tag) else { return }
        let tool = ScreenshotAnnotationTool.allCases[sender.tag]
        selectTool(tool)
    }

    @objc private func advancedToolPressed(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let tool = ScreenshotAnnotationTool(rawValue: rawValue) else { return }
        selectTool(tool)
    }

    private func selectTool(_ tool: ScreenshotAnnotationTool) {
        guard canvas.commitInlineTextIfNeeded() else {
            updateToolSelectionUI(canvas.tool)
            showStatus("请先确认输入法候选，再切换工具", isError: false)
            return
        }
        canvas.tool = tool
        updateToolSelectionUI(tool)
        onToolSelected?(tool)
        updateDocumentStatus()
        window?.makeFirstResponder(canvas)
    }

    private func updateToolSelectionUI(_ tool: ScreenshotAnnotationTool) {
        let isAdvanced = ScreenshotAnnotationTool.advancedTools.contains(tool)
        advancedToolPopup.selectItem(at: 0)
        advancedToolPopup.title = isAdvanced ? tool.title : "更多"
        let usesColor: Bool
        switch tool {
        case .select, .crop, .blur, .pixelate: usesColor = false
        default: usesColor = true
        }
        colorPaletteControl.isEnabled = usesColor
        lineWidthControl.isEnabled = usesColor && tool != .text
        for (candidate, button) in toolButtons {
            let isSelected = candidate == tool
            button.state = isSelected ? .on : .off
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
            button.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
            button.layer?.borderWidth = isSelected ? 1 : 0
            button.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
                : NSColor.clear.cgColor
            button.setAccessibilityValue(isSelected ? "已选择" : nil)
        }
    }

    @objc private func colorChanged() {
        guard canvas.commitInlineTextIfNeeded() else {
            colorPaletteControl.selectedSegment = annotationColors.firstIndex { $0.color == canvas.annotationColor } ?? 0
            return
        }
        let index = colorPaletteControl.selectedSegment
        guard annotationColors.indices.contains(index) else { return }
        canvas.annotationColor = annotationColors[index].color
        window?.makeFirstResponder(canvas)
    }

    @objc private func lineWidthChanged() {
        let multipliers: [CGFloat] = [0.65, 1, 1.8]
        guard canvas.commitInlineTextIfNeeded() else {
            lineWidthControl.selectedSegment = multipliers.firstIndex(of: canvas.lineWidthMultiplier) ?? 1
            return
        }
        let index = max(0, min(lineWidthControl.selectedSegment, multipliers.count - 1))
        canvas.lineWidthMultiplier = multipliers[index]
        window?.makeFirstResponder(canvas)
    }

    @objc private func undoPressed() {
        guard canvas.commitInlineTextIfNeeded() else { return }
        canvas.undo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func redoPressed() {
        guard canvas.commitInlineTextIfNeeded() else { return }
        canvas.redo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func copyPressed() {
        copyEditedImage()
    }

    private func copyEditedImage() {
        beginRenderedAction(status: "正在准备复制") { [self] data in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else {
                throw ScreenshotEditorError.clipboardWriteFailed
            }
            showStatus("已复制编辑后的截图", isError: false)
            logger.info("screenshot.editor.copied stateID=\(self.canvas.documentStateID.uuidString, privacy: .public)")
        }
    }

    @objc private func savePressed() {
        beginSave()
    }

    @objc private func saveAsPressed() {
        guard let window else { return }
        guard canvas.commitInlineTextIfNeeded() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "\(fileURL.deletingPathExtension().lastPathComponent)-edited.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.beginSave(exportURL: url)
        }
    }

    @objc private func viewportPressed(_ sender: NSButton) {
        switch sender.tag {
        case 0: canvas.setViewportMode(.fit)
        case 1: canvas.setViewportMode(.fitWidth)
        case 2: canvas.setViewportMode(.actualPixels)
        case 3: canvas.zoomViewport(by: 1 / 1.25)
        default: canvas.zoomViewport(by: 1.25)
        }
    }

    @objc private func sharePressed(_ sender: NSButton) {
        beginRenderedAction(status: "正在准备分享") { [self] data in
            guard let image = NSImage(data: data) else {
                throw ScreenshotEditorError.imageRenderingFailed
            }
            let picker = NSSharingServicePicker(items: [image])
            sharingPicker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            showStatus("请选择分享方式", isError: false)
            logger.info("screenshot.editor.share.presented")
        }
    }

    private func beginRenderedAction(status: String, completion: @escaping @MainActor (Data) throws -> Void) {
        guard renderActionTask == nil else {
            showStatus("正在准备上一项图片操作，请稍候", isError: false)
            return
        }
        let snapshot: ScreenshotRenderSnapshot
        do { snapshot = try canvas.makeRenderSnapshot() }
        catch { showStatus(error.localizedDescription, isError: true); return }
        showStatus(status + "…", isError: false)
        renderActionTask = Task { @MainActor [self] in
            defer { renderActionTask = nil }
            await canvas.beginBackgroundRendering()
            defer { canvas.endBackgroundRendering() }
            do {
                let data = try await ScreenshotRenderQueue.shared.render(snapshot)
                guard !windowIsClosed else { return }
                try completion(data)
            } catch {
                guard !windowIsClosed else { return }
                showStatus("图片操作失败，修改已保留：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func beginSave(exportURL: URL? = nil, closeAfterSaving: Bool = false) {
        Task { @MainActor [weak self] in
            _ = await self?.saveRevision(exportURL: exportURL, closeAfterSaving: closeAfterSaving)
        }
    }

    @discardableResult
    func saveRevision(exportURL: URL? = nil, closeAfterSaving: Bool = false) async -> Bool {
        guard canvas.commitInlineTextIfNeeded() else {
            showStatus("请先确认输入法候选，再保存", isError: true)
            return false
        }
        let requestedStateID = canvas.documentStateID
        // Serialize writes. An explicit second save of a newer state must not
        // be acknowledged by the receipt for the older in-flight snapshot.
        if let saveTask {
            let result = await saveTask.value
            if exportURL != nil || (result && requestedStateID != savedStateID) {
                return await saveRevision(exportURL: exportURL, closeAfterSaving: closeAfterSaving)
            }
            if result, closeAfterSaving { closeAfterConfirmedSave() }
            return result
        }
        let stateID = canvas.documentStateID
        let snapshot: ScreenshotRenderSnapshot
        do { snapshot = try canvas.makeRenderSnapshot() }
        catch {
            showStatus("保存失败：\(error.localizedDescription)", isError: true)
            return false
        }
        savePresentationSequence &+= 1
        let savingSequence = savePresentationSequence
        showStatus("正在保存编辑版本…", isError: false)
        let task = Task { @MainActor [self] () -> Bool in
            defer { saveTask = nil; updateDocumentIdentity() }
            await canvas.beginBackgroundRendering()
            defer { canvas.endBackgroundRendering() }
            do {
                let data: Data
                let revision: ArtifactManifest
                if stateID == savedStateID, let existing = lastSavedArtifact {
                    revision = existing
                    data = try lastSavedResult?.pngData ?? Data(contentsOf: existing.canonicalURL, options: .alwaysMapped)
                } else {
                    guard let onSaveRevision else { throw RevisionSaveError.unavailable }
                    data = try await ScreenshotRenderQueue.shared.render(snapshot) { [self] fraction in
                            Task { @MainActor [self] in
                                guard self.isSaving, self.saveStatusIsWorking,
                                      self.savePresentationSequence == savingSequence else { return }
                                self.showStatus("正在渲染编辑版本… \(Int(fraction * 100))%", isError: false)
                            }
                    }
                    revision = try await onSaveRevision(data)
                }
                savedStateID = stateID
                lastSavedArtifact = revision
                lastSavedResult = ScreenshotEditorCloseResult(pngData: data, fileURL: revision.canonicalURL)
                if let exportURL {
                    do {
                        guard let onExportRevision else { throw RevisionSaveError.unavailable }
                        try await onExportRevision(revision, exportURL)
                        showStatus("已保存副本 · 已导出 \(exportURL.lastPathComponent)", isError: false, detail: exportURL.path)
                    } catch {
                        showStatus("编辑版本已保存，导出失败，可重试：\(error.localizedDescription)", isError: true)
                        return false
                    }
                } else {
                    showStatus(hasUnsavedChanges ? "上一版已保存，当前仍有未保存修改" : "已保存编辑版本，截图浮窗已更新", isError: false)
                }
                return true
            } catch {
                showStatus("保存失败，修改已保留：\(error.localizedDescription)", isError: true)
                return false
            }
        }
        saveTask = task
        let result = await task.value
        if result, closeAfterSaving { closeAfterConfirmedSave() }
        return result
    }

    private func closeAfterConfirmedSave() {
        guard !windowIsClosed, canvas.commitInlineTextIfNeeded(), !hasUnsavedChanges else { return }
        allowsImmediateClose = true
        pendingCloseResult = lastSavedResult
        close()
    }

    private func makeCloseResult(fileURL: URL) -> ScreenshotEditorCloseResult? {
        if let lastSavedResult { return lastSavedResult }
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return nil }
        return ScreenshotEditorCloseResult(pngData: data, fileURL: fileURL)
    }

    private func updateDocumentStatus() {
        let dirty = canvas.documentStateID == savedStateID ? "" : " · 有未保存修改"
        let selection = canvas.hasSelection ? " · Delete 删除所选标注" : ""
        statusLabel.stringValue = "\(canvas.tool.title)：\(canvas.tool.hint)\(selection)\(dirty) · ⌘Z 撤销 / ⇧⌘Z 重做"
        statusLabel.textColor = .secondaryLabelColor
        updateDocumentIdentity()
        if lastPresentedStateID != canvas.documentStateID {
            lastPresentedStateID = canvas.documentStateID
            if !isSaving && !saveStatusIsWorking {
                saveStatusLabel.stringValue = hasUnsavedChanges ? "有未保存修改" : (lastSavedArtifact == nil ? "原图已保留" : "已保存编辑副本")
                saveStatusLabel.textColor = hasUnsavedChanges ? .secondaryLabelColor : .systemGreen
                saveStatusLabel.toolTip = hasUnsavedChanges ? "保存会生成编辑副本，原图保持不变" : "原图保持不变"
            }
        }
        updateHistoryButtons()
    }

    private func updateDocumentIdentity() {
        let size = canvas.viewportTransform.cropRect.size
        window?.title = "编辑截图 — \(fileURL.lastPathComponent) · \(Int(size.width)) × \(Int(size.height))"
        window?.isDocumentEdited = hasUnsavedChanges
    }

    private func updateHistoryButtons() {
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
    }

    private func showStatus(_ text: String, isError: Bool, detail: String? = nil) {
        statusLabel.stringValue = text
        saveStatusIsWorking = text.hasPrefix("正在")
        let isSuccess = text.hasPrefix("已") && !text.contains("失败") && !text.contains("未保存")
        let color: NSColor = isError ? .systemRed : (isSuccess ? .systemGreen : .secondaryLabelColor)
        statusLabel.textColor = color
        saveStatusLabel.stringValue = text == "已保存编辑版本，截图浮窗已更新" ? "已保存编辑副本" : text
        saveStatusLabel.textColor = color
        saveStatusLabel.toolTip = detail ?? text
        saveButton.setAccessibilityValue(text)
        updateDocumentIdentity()
        updateHistoryButtons()
    }
}

private enum ScreenshotEditorError: LocalizedError {
    case clipboardWriteFailed
    case imageRenderingFailed
    case pngEncodingFailed
    case uncommittedText
    case rasterBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            return "无法写入系统剪贴板"
        case .imageRenderingFailed:
            return "无法创建编辑后的图像"
        case .pngEncodingFailed:
            return "无法编码编辑后的 PNG"
        case .uncommittedText:
            return "请先确认输入法候选"
        case .rasterBudgetExceeded:
            return "图片超过当前完整位图导出预算，修改已保留；请先裁剪较小区域。原始长图仍可从浮窗保存或拖出"
        }
    }
}

enum ScreenshotAnnotationKind: Sendable {
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case ellipse(CGRect)
    case stroke([CGPoint])
    case highlight([CGPoint])
    case text(String, origin: CGPoint)
    case blur(CGRect, radius: CGFloat)
    case pixelate(CGRect, scale: CGFloat)
    case spotlight(CGRect)
    case counter(Int, center: CGPoint)
}

struct ScreenshotAnnotationNode: @unchecked Sendable {
    let id: UUID
    var kind: ScreenshotAnnotationKind
    let color: NSColor
    let lineWidth: CGFloat
    var fontSize: CGFloat
}

private struct ScreenshotDocumentState {
    var id: UUID
    var cropRect: CGRect
    var annotations: [ScreenshotAnnotationNode]
}

private enum ScreenshotSelectionHandle {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private enum ScreenshotCanvasInteraction {
    case drawing(tool: ScreenshotAnnotationTool, start: CGPoint, before: ScreenshotDocumentState)
    case moving(nodeID: UUID, start: CGPoint, before: ScreenshotDocumentState, original: ScreenshotAnnotationNode)
    case resizing(
        nodeID: UUID,
        handle: ScreenshotSelectionHandle,
        before: ScreenshotDocumentState,
        original: ScreenshotAnnotationNode,
        originalBounds: CGRect
    )
}

struct ScreenshotRenderMapping {
    let cropRect: CGRect
    let destinationRect: CGRect
    let isFlippedSurface: Bool

    var scale: CGFloat {
        destinationRect.width / max(1, cropRect.width)
    }

    func point(_ point: CGPoint) -> CGPoint {
        let x = destinationRect.minX + (point.x - cropRect.minX) * scale
        if isFlippedSurface {
            return CGPoint(
                x: x,
                y: destinationRect.minY + (point.y - cropRect.minY) * scale
            )
        }
        return CGPoint(
            x: x,
            y: destinationRect.maxY - (point.y - cropRect.minY) * scale
        )
    }

    func rect(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let first = point(CGPoint(x: rect.minX, y: rect.minY))
        let second = point(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}

@MainActor
final class ScreenshotInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        onCommit?()
    }

    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { super.cancelOperation(sender); return }
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        "直接输入文字，回车完成，Esc 取消".draw(
            at: CGPoint(x: textContainerInset.width + 4, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

@MainActor
final class ScreenshotAnnotationCanvasView: NSView {
    var tool: ScreenshotAnnotationTool = .arrow {
        didSet {
            guard inlineTextView?.hasMarkedText() != true else {
                tool = oldValue
                return
            }
            if oldValue == .text, tool != .text {
                finishInlineTextEditing(commit: true)
            }
            draftAnnotation = nil
            draftCropRect = nil
            interaction = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var annotationColor: NSColor = .systemRed {
        didSet {
            inlineTextView?.textColor = annotationColor
            inlineTextView?.insertionPointColor = annotationColor
        }
    }
    var lineWidthMultiplier: CGFloat = 1
    var onDocumentChange: ((UUID) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onCopyRequest: (() -> Void)?
    var onSaveRequest: (() -> Void)?
    var onViewportChange: ((CGFloat) -> Void)?

    var documentStateID: UUID { document.id }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasSelection: Bool { selectedAnnotationID != nil }

    private let baseCGImage: CGImage
    private let rasterSource: ScreenshotRasterSource
    private let smallPreviewImage: NSImage?
    private let previewCache: ScreenshotPreviewCache
    private let filterPreviewCache = ScreenshotFilterPreviewCache()
    private let previewRenderer: ScreenshotDocumentRenderer
    private let imageSize: CGSize
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ScreenshotEditorCanvas")
    private var document: ScreenshotDocumentState
    private var undoStack: [ScreenshotDocumentState] = []
    private var redoStack: [ScreenshotDocumentState] = []
    private var selectedAnnotationID: UUID?
    private var draftAnnotation: ScreenshotAnnotationNode?
    private var draftCropRect: CGRect?
    private var interaction: ScreenshotCanvasInteraction?
    private var inlineTextView: ScreenshotInlineTextView?
    private var inlineTextPoint: CGPoint?
    private var isFinalizingInlineText = false
    private var viewportMode: ScreenshotViewportMode = .fit
    private var viewportPan: CGSize = .zero
    private var spaceIsDown = false
    private var panDragStart: CGPoint?
    private var panAtDragStart: CGSize = .zero
    private var backgroundRenderCount = 0

    init(image: CGImage, sourceURL: URL? = nil) {
        baseCGImage = image
        let rasterSource = ScreenshotRasterSource(image: image,
            sourceURL: image.width * image.height > 8_000_000 ? sourceURL : nil)
        self.rasterSource = rasterSource
        imageSize = CGSize(width: image.width, height: image.height)
        smallPreviewImage = image.width * image.height <= 8_000_000
            ? NSImage(cgImage: image, size: imageSize) : nil
        previewCache = ScreenshotPreviewCache(image: image, rasterSource: rasterSource)
        previewRenderer = ScreenshotDocumentRenderer(snapshot: ScreenshotRenderSnapshot(
            source: image, stateID: UUID(), cropRect: CGRect(origin: .zero, size: imageSize),
            annotations: [], rasterSource: rasterSource))
        document = ScreenshotDocumentState(
            id: UUID(),
            cropRect: CGRect(origin: .zero, size: imageSize),
            annotations: []
        )
        viewportMode = imageSize.height > imageSize.width * 2 ? .fitWidth : .fit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        layer?.masksToBounds = true
        previewCache.onChange = { [weak self] in self?.needsDisplay = true }
        filterPreviewCache.onChange = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        onViewportChange?(viewportTransform.displayZoom)
        guard let inlineTextView, let inlineTextPoint else { return }
        inlineTextView.frame = inlineTextViewFrame(for: viewPoint(for: inlineTextPoint))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        bounds.fill()

        let imageRect = imageDrawingRect
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        NSColor.black.setFill()
        imageRect.fill()

        let mapping = ScreenshotRenderMapping(
            cropRect: document.cropRect,
            destinationRect: imageRect,
            isFlippedSurface: true
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        if let smallPreviewImage {
            smallPreviewImage.draw(in: imageRect, from: appKitSourceRect(for: document.cropRect),
                operation: .copy, fraction: 1, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high])
        } else if previewCache.isSourceWithinBudget {
            let tiles = previewCache.tiles(for: visibleImageRect, displayScale: mapping.scale,
                                           backingScale: window?.backingScaleFactor ?? 1)
            for tile in tiles {
                let image = NSImage(cgImage: tile.image, size: tile.sourceRect.size)
                image.cacheMode = .never
                image.draw(in: mapping.rect(tile.sourceRect), from: .zero, operation: .copy, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
            if tiles.isEmpty {
                ((previewCache.failureMessage ?? "正在准备大图预览…") as NSString).draw(at: CGPoint(x: 32, y: 32),
                    withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
            }
        } else {
            ("图片超过可预览尺寸（最多 2 亿像素、单边 120000 像素）" as NSString).draw(at: CGPoint(x: 32, y: 32),
                withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
        }
        draw(nodes: document.annotations + (draftAnnotation.map { [$0] } ?? []), mapping: mapping)
        NSGraphicsContext.restoreGraphicsState()

        drawCropOverlay(mapping: mapping)
        drawSelection(mapping: mapping)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        guard commitInlineTextIfNeeded() else { return }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if spaceIsDown {
            panDragStart = viewPoint
            panAtDragStart = viewportTransform.pan
            window?.invalidateCursorRects(for: self)
            return
        }
        guard let point = imagePoint(for: viewPoint) else {
            clearSelection()
            return
        }

        if tool == .select {
            beginSelectionInteraction(viewPoint: viewPoint, imagePoint: point)
            return
        }

        if tool == .text {
            clearSelection()
            beginInlineTextEditing(at: point, viewPoint: viewPoint)
            return
        }

        if tool == .counter {
            clearSelection()
            let before = document
            let node = makeNode(
                kind: .counter(nextCounterNumber, center: point),
                lineWidth: currentLineWidth
            )
            document.annotations.append(node)
            selectedAnnotationID = node.id
            finalizeChange(previous: before)
            return
        }

        clearSelection()
        let before = document
        interaction = .drawing(tool: tool, start: point, before: before)
        let lineWidth = currentLineWidth
        switch tool {
        case .arrow:
            draftAnnotation = makeNode(kind: .arrow(start: point, end: point), lineWidth: lineWidth)
        case .line:
            draftAnnotation = makeNode(kind: .line(start: point, end: point), lineWidth: lineWidth)
        case .rectangle:
            draftAnnotation = makeNode(kind: .rectangle(CGRect(origin: point, size: .zero)), lineWidth: lineWidth)
        case .filledRectangle:
            draftAnnotation = makeNode(kind: .filledRectangle(CGRect(origin: point, size: .zero)), lineWidth: lineWidth)
        case .ellipse:
            draftAnnotation = makeNode(kind: .ellipse(CGRect(origin: point, size: .zero)), lineWidth: lineWidth)
        case .pen:
            draftAnnotation = makeNode(kind: .stroke([point]), lineWidth: lineWidth)
        case .highlighter:
            draftAnnotation = makeNode(kind: .highlight([point]), lineWidth: lineWidth * 5)
        case .blur:
            draftAnnotation = makeNode(
                kind: .blur(CGRect(origin: point, size: .zero), radius: defaultBlurRadius),
                lineWidth: lineWidth
            )
        case .pixelate:
            draftAnnotation = makeNode(
                kind: .pixelate(CGRect(origin: point, size: .zero), scale: defaultPixelScale),
                lineWidth: lineWidth
            )
        case .spotlight:
            draftAnnotation = makeNode(kind: .spotlight(CGRect(origin: point, size: .zero)), lineWidth: lineWidth)
        case .crop:
            draftCropRect = CGRect(origin: point, size: .zero)
        case .select, .text, .counter:
            interaction = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let panDragStart {
            let point = convert(event.locationInWindow, from: nil)
            var transform = viewportTransform
            transform = ScreenshotViewportTransform(
                cropRect: transform.cropRect, viewport: transform.viewport, backingScale: transform.backingScale,
                mode: transform.mode, pan: panAtDragStart
            )
            transform.move(by: CGSize(width: point.x - panDragStart.x, height: point.y - panDragStart.y))
            applyViewport(transform)
            return
        }
        guard let point = imagePoint(
            for: convert(event.locationInWindow, from: nil),
            clamped: true
        ), let interaction else {
            return
        }

        switch interaction {
        case let .drawing(tool, start, _):
            updateDrawing(tool: tool, start: start, point: point)
        case let .moving(nodeID, start, _, original):
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            updateNode(nodeID, with: translated(original, by: offset))
        case let .resizing(nodeID, handle, _, original, originalBounds):
            let newBounds = resizedBounds(originalBounds, handle: handle, point: point)
            updateNode(nodeID, with: transformed(original, from: originalBounds, to: newBounds))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panDragStart != nil {
            panDragStart = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        guard event.buttonNumber == 0, let interaction else { return }
        if let point = imagePoint(for: convert(event.locationInWindow, from: nil), clamped: true) {
            switch interaction {
            case let .drawing(tool, start, _):
                updateDrawing(tool: tool, start: start, point: point)
            case let .moving(nodeID, start, _, original):
                updateNode(
                    nodeID,
                    with: translated(
                        original,
                        by: CGSize(width: point.x - start.x, height: point.y - start.y)
                    )
                )
            case let .resizing(nodeID, handle, _, original, originalBounds):
                updateNode(
                    nodeID,
                    with: transformed(
                        original,
                        from: originalBounds,
                        to: resizedBounds(originalBounds, handle: handle, point: point)
                    )
                )
            }
        }
        finishInteraction(interaction)
        self.interaction = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 49, modifiers.intersection([.command, .control, .option]).isEmpty {
            spaceIsDown = true
            window?.invalidateCursorRects(for: self)
            return
        }
        if modifiers.contains(.command), key == "z" {
            modifiers.contains(.shift) ? redo() : undo()
            return
        }
        if modifiers.contains(.command), key == "c" {
            onCopyRequest?()
            return
        }
        if modifiers.contains(.command), key == "s" {
            onSaveRequest?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }
        if event.keyCode == 53 {
            draftAnnotation = nil
            draftCropRect = nil
            interaction = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        spaceIsDown = false
        panDragStart = nil
        return super.resignFirstResponder()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoomViewport(by: exp(-event.scrollingDeltaY * 0.01), around: convert(event.locationInWindow, from: nil))
        } else {
            var transform = viewportTransform
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            transform.move(by: CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier))
            applyViewport(transform)
        }
    }

    override func magnify(with event: NSEvent) {
        zoomViewport(by: max(0.01, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
        needsLayout = true
    }

    override func resetCursorRects() {
        if spaceIsDown || panDragStart != nil {
            addCursorRect(bounds, cursor: panDragStart == nil ? .openHand : .closedHand)
            return
        }
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    func undo() {
        guard commitInlineTextIfNeeded() else { return }
        guard let previous = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        redoStack.append(document)
        document = previous
        selectedAnnotationID = nil

        notifyDocumentChanged()
    }

    func redo() {
        guard commitInlineTextIfNeeded() else { return }
        guard let next = redoStack.popLast() else {
            NSSound.beep()
            return
        }
        undoStack.append(document)
        document = next
        selectedAnnotationID = nil

        notifyDocumentChanged()
    }

    func addText(_ text: String, at point: CGPoint) {
        let before = document
        document.annotations.append(
            ScreenshotAnnotationNode(
                id: UUID(),
                kind: .text(text, origin: point),
                color: annotationColor,
                lineWidth: currentLineWidth,
                fontSize: max(18, currentLineWidth * 4.2)
            )
        )
        selectedAnnotationID = document.annotations.last?.id
        finalizeChange(previous: before)
    }

    private func beginInlineTextEditing(at imagePoint: CGPoint, viewPoint: CGPoint) {
        guard commitInlineTextIfNeeded() else { return }

        let textView = ScreenshotInlineTextView(frame: inlineTextViewFrame(for: viewPoint))
        textView.string = ""
        textView.font = .systemFont(ofSize: 16, weight: .semibold)
        textView.textColor = annotationColor
        textView.insertionPointColor = annotationColor
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = CGSize(width: 7, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.wantsLayer = true
        textView.layer?.cornerRadius = 7
        textView.layer?.borderWidth = 1
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.setAccessibilityLabel("截图文字标注")
        textView.onCommit = { [weak self, weak textView] in
            guard let self, self.inlineTextView === textView else { return }
            self.finishInlineTextEditing(commit: true)
        }
        textView.onCancel = { [weak self, weak textView] in
            guard let self, self.inlineTextView === textView else { return }
            self.finishInlineTextEditing(commit: false)
        }

        inlineTextView = textView
        inlineTextPoint = imagePoint
        addSubview(textView)
        logger.info(
            "screenshot.editor.text.begin imageX=\(imagePoint.x, privacy: .public) imageY=\(imagePoint.y, privacy: .public) frame=\(NSStringFromRect(textView.frame), privacy: .public)"
        )
        Task { @MainActor [weak self, weak textView] in
            await Task.yield()
            guard let self,
                  let textView,
                  self.inlineTextView === textView else {
                return
            }
            let accepted = self.window?.makeFirstResponder(textView) ?? false
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            self.logger.info(
                "screenshot.editor.text.focus accepted=\(accepted, privacy: .public)"
            )
        }
    }

    private func finishInlineTextEditing(commit: Bool) {
        guard !isFinalizingInlineText,
              let textView = inlineTextView,
              !textView.hasMarkedText() else {
            return
        }
        isFinalizingInlineText = true
        let point = inlineTextPoint
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineTextView = nil
        inlineTextPoint = nil
        textView.onCommit = nil
        textView.onCancel = nil
        textView.removeFromSuperview()
        if commit, !text.isEmpty, let point {
            addText(text, at: point)
        }
        logger.info(
            "screenshot.editor.text.end committed=\(commit && !text.isEmpty, privacy: .public) length=\(text.count, privacy: .public)"
        )
        isFinalizingInlineText = false
        window?.makeFirstResponder(self)
    }

    private func inlineTextViewFrame(for viewPoint: CGPoint) -> CGRect {
        let imageRect = bounds.insetBy(dx: 8, dy: 8)
        let width = min(300, max(80, imageRect.width - 8))
        let height: CGFloat = 42
        let x = min(max(viewPoint.x, imageRect.minX + 4), imageRect.maxX - width - 4)
        let y = min(max(viewPoint.y - 3, imageRect.minY + 4), imageRect.maxY - height - 4)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func viewPoint(for imagePoint: CGPoint) -> CGPoint {
        ScreenshotRenderMapping(
            cropRect: document.cropRect,
            destinationRect: imageDrawingRect,
            isFlippedSurface: true
        ).point(imagePoint)
    }

    @discardableResult
    func commitInlineTextIfNeeded() -> Bool {
        guard inlineTextView?.hasMarkedText() != true else { return false }
        finishInlineTextEditing(commit: true)
        return true
    }

    func makeRenderSnapshot() throws -> ScreenshotRenderSnapshot {
        guard commitInlineTextIfNeeded() else { throw ScreenshotEditorError.uncommittedText }
        let nodes = document.annotations.map { node in
            ScreenshotAnnotationNode(id: node.id, kind: node.kind,
                color: node.color.usingColorSpace(.sRGB) ?? node.color,
                lineWidth: node.lineWidth, fontSize: node.fontSize)
        }
        return ScreenshotRenderSnapshot(source: baseCGImage, stateID: document.id,
                                        cropRect: integralCropRect(document.cropRect), annotations: nodes,
                                        rasterSource: rasterSource)
    }

    func renderPNGData(strategy: ScreenshotPNGRenderStrategy = .automatic) throws -> Data {
        try ScreenshotDocumentRenderer(snapshot: makeRenderSnapshot()).pngData(strategy: strategy)
    }

    func beginBackgroundRendering() async {
        backgroundRenderCount += 1
        previewCache.setSuspended(true)
        filterPreviewCache.setSuspended(true)
        await previewCache.waitUntilIdle()
        await filterPreviewCache.waitUntilIdle()
    }

    func endBackgroundRendering() {
        backgroundRenderCount = max(0, backgroundRenderCount - 1)
        if backgroundRenderCount == 0 {
            previewCache.retryFailedRequests()
            filterPreviewCache.retryFailedRequests()
            previewCache.setSuspended(false)
            filterPreviewCache.setSuspended(false)
        }
        needsDisplay = true
    }

    private var visibleImageRect: CGRect {
        let visible = imageDrawingRect.intersection(bounds)
        guard !visible.isNull, !visible.isEmpty,
              let first = viewportTransform.imagePoint(at: CGPoint(x: visible.minX, y: visible.minY), clamped: true),
              let last = viewportTransform.imagePoint(at: CGPoint(x: visible.maxX, y: visible.maxY), clamped: true) else { return .zero }
        return CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y)
            .integral.intersection(document.cropRect)
    }

    private var currentLineWidth: CGFloat {
        max(3, min(imageSize.width, imageSize.height) / 320) * lineWidthMultiplier
    }

    private var defaultBlurRadius: CGFloat {
        max(8, min(imageSize.width, imageSize.height) / 110)
    }

    private var defaultPixelScale: CGFloat {
        max(10, min(imageSize.width, imageSize.height) / 90)
    }

    private var nextCounterNumber: Int {
        let highest = document.annotations.compactMap { node -> Int? in
            guard case let .counter(number, _) = node.kind else { return nil }
            return number
        }.max() ?? 0
        return highest + 1
    }

    private var imageBounds: CGRect {
        CGRect(origin: .zero, size: imageSize)
    }

    var viewportTransform: ScreenshotViewportTransform {
        ScreenshotViewportTransform(cropRect: document.cropRect, viewport: bounds.insetBy(dx: 24, dy: 24),
                                    backingScale: window?.backingScaleFactor ?? 1,
                                    mode: viewportMode, pan: viewportPan)
    }

    func setViewportMode(_ mode: ScreenshotViewportMode) {
        var transform = viewportTransform
        transform.setMode(mode)
        applyViewport(transform)
    }

    func scrollViewport(to position: CGFloat) {
        applyViewport(ScreenshotEditorNavigationState.scrolled(viewportTransform, to: position))
    }

    func zoomViewport(by factor: CGFloat, around anchor: CGPoint? = nil) {
        var transform = viewportTransform
        transform.zoom(by: factor, around: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY))
        applyViewport(transform)
    }

    private func applyViewport(_ transform: ScreenshotViewportTransform) {
        viewportMode = transform.mode
        viewportPan = transform.pan
        needsDisplay = true
        needsLayout = true
        onViewportChange?(transform.displayZoom)
    }

    private var imageDrawingRect: CGRect {
        viewportTransform.drawingRect
    }

    private func imagePoint(for viewPoint: CGPoint, clamped: Bool = false) -> CGPoint? {
        viewportTransform.imagePoint(at: viewPoint, clamped: clamped)
    }

    private func appKitSourceRect(for topLeftRect: CGRect) -> CGRect {
        let rect = topLeftRect.standardized
        return CGRect(
            x: rect.minX,
            y: imageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func integralCropRect(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized.intersection(imageBounds)
        let minX = floor(rect.minX)
        let minY = floor(rect.minY)
        let maxX = ceil(rect.maxX)
        let maxY = ceil(rect.maxY)
        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        ).intersection(imageBounds)
    }

    private func beginSelectionInteraction(viewPoint: CGPoint, imagePoint: CGPoint) {
        if let selectedAnnotationID,
           let node = annotation(with: selectedAnnotationID),
           let handle = selectionHandle(at: viewPoint, for: node) {
            interaction = .resizing(
                nodeID: selectedAnnotationID,
                handle: handle,
                before: document,
                original: node,
                originalBounds: bounds(of: node)
            )
            return
        }

        guard let node = hitTestAnnotation(at: imagePoint) else {
            clearSelection()
            interaction = nil
            return
        }
        selectedAnnotationID = node.id
        onSelectionChange?()
        interaction = .moving(
            nodeID: node.id,
            start: imagePoint,
            before: document,
            original: node
        )
        needsDisplay = true
    }

    private func clearSelection() {
        guard selectedAnnotationID != nil else { return }
        selectedAnnotationID = nil
        onSelectionChange?()
        needsDisplay = true
    }

    private func deleteSelection() {
        guard let selectedAnnotationID,
              document.annotations.contains(where: { $0.id == selectedAnnotationID }) else {
            NSSound.beep()
            return
        }
        let before = document
        document.annotations.removeAll { $0.id == selectedAnnotationID }

        self.selectedAnnotationID = nil
        finalizeChange(previous: before)
    }

    private func updateDrawing(tool: ScreenshotAnnotationTool, start: CGPoint, point: CGPoint) {
        let rect = Self.rect(from: start, to: point).intersection(document.cropRect)
        switch tool {
        case .arrow:
            draftAnnotation?.kind = .arrow(start: start, end: point)
        case .line:
            draftAnnotation?.kind = .line(start: start, end: point)
        case .rectangle:
            draftAnnotation?.kind = .rectangle(rect)
        case .filledRectangle:
            draftAnnotation?.kind = .filledRectangle(rect)
        case .ellipse:
            draftAnnotation?.kind = .ellipse(rect)
        case .pen:
            if case let .stroke(points) = draftAnnotation?.kind {
                var points = points
                if let last = points.last,
                   hypot(point.x - last.x, point.y - last.y) >= max(1, currentLineWidth / 3) {
                    points.append(point)
                }
                draftAnnotation?.kind = .stroke(points)
            }
        case .highlighter:
            if case let .highlight(points) = draftAnnotation?.kind {
                var points = points
                if let last = points.last,
                   hypot(point.x - last.x, point.y - last.y) >= max(1, currentLineWidth / 3) {
                    points.append(point)
                }
                draftAnnotation?.kind = .highlight(points)
            }
        case .blur:
            draftAnnotation?.kind = .blur(rect, radius: defaultBlurRadius)
        case .pixelate:
            draftAnnotation?.kind = .pixelate(rect, scale: defaultPixelScale)
        case .spotlight:
            draftAnnotation?.kind = .spotlight(rect)
        case .crop:
            draftCropRect = rect
        case .select, .text, .counter:
            break
        }
        needsDisplay = true
    }

    private func finishInteraction(_ interaction: ScreenshotCanvasInteraction) {
        switch interaction {
        case let .drawing(tool, _, before):
            if tool == .crop {
                guard let crop = draftCropRect, crop.width >= 8, crop.height >= 8 else {
                    draftCropRect = nil
                    NSSound.beep()
                    return
                }
                document.cropRect = integralCropRect(crop)
                draftCropRect = nil
                finalizeChange(previous: before)
                return
            }
            guard let draftAnnotation, isMeaningful(draftAnnotation) else {
                self.draftAnnotation = nil
                return
            }
            document.annotations.append(draftAnnotation)
            selectedAnnotationID = draftAnnotation.id
            self.draftAnnotation = nil
            finalizeChange(previous: before)

        case let .moving(nodeID, _, before, original):
            guard let updated = annotation(with: nodeID), bounds(of: updated) != bounds(of: original) else {
                document = before
                return
            }
            finalizeChange(previous: before)

        case let .resizing(nodeID, _, before, original, _):
            guard let updated = annotation(with: nodeID), bounds(of: updated) != bounds(of: original) else {
                document = before
                return
            }
            finalizeChange(previous: before)
        }
    }

    private func finalizeChange(previous: ScreenshotDocumentState) {
        undoStack.append(previous)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
        document.id = UUID()

        notifyDocumentChanged()
    }

    private func notifyDocumentChanged() {
        onDocumentChange?(document.id)
        needsDisplay = true
    }

    private func makeNode(kind: ScreenshotAnnotationKind, lineWidth: CGFloat) -> ScreenshotAnnotationNode {
        ScreenshotAnnotationNode(
            id: UUID(),
            kind: kind,
            color: annotationColor,
            lineWidth: lineWidth,
            fontSize: max(18, lineWidth * 4.2)
        )
    }

    private func annotation(with id: UUID) -> ScreenshotAnnotationNode? {
        document.annotations.first { $0.id == id }
    }

    private func updateNode(_ id: UUID, with node: ScreenshotAnnotationNode) {
        guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        document.annotations[index] = node

    }

    private func translated(_ node: ScreenshotAnnotationNode, by offset: CGSize) -> ScreenshotAnnotationNode {
        var node = node
        let currentBounds = bounds(of: node)
        let allowedX = min(
            max(offset.width, document.cropRect.minX - currentBounds.minX),
            document.cropRect.maxX - currentBounds.maxX
        )
        let allowedY = min(
            max(offset.height, document.cropRect.minY - currentBounds.minY),
            document.cropRect.maxY - currentBounds.maxY
        )
        let offset = CGSize(width: allowedX, height: allowedY)
        let translate: (CGPoint) -> CGPoint = { point in
            CGPoint(x: point.x + offset.width, y: point.y + offset.height)
        }
        switch node.kind {
        case let .arrow(start, end): node.kind = .arrow(start: translate(start), end: translate(end))
        case let .line(start, end): node.kind = .line(start: translate(start), end: translate(end))
        case let .rectangle(rect): node.kind = .rectangle(rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .filledRectangle(rect): node.kind = .filledRectangle(rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .ellipse(rect): node.kind = .ellipse(rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .stroke(points): node.kind = .stroke(points.map(translate))
        case let .highlight(points): node.kind = .highlight(points.map(translate))
        case let .text(text, origin): node.kind = .text(text, origin: translate(origin))
        case let .blur(rect, radius): node.kind = .blur(rect.offsetBy(dx: offset.width, dy: offset.height), radius: radius)
        case let .pixelate(rect, scale): node.kind = .pixelate(rect.offsetBy(dx: offset.width, dy: offset.height), scale: scale)
        case let .spotlight(rect): node.kind = .spotlight(rect.offsetBy(dx: offset.width, dy: offset.height))
        case let .counter(number, center): node.kind = .counter(number, center: translate(center))
        }
        return node
    }

    private func transformed(
        _ node: ScreenshotAnnotationNode,
        from oldBounds: CGRect,
        to requestedBounds: CGRect
    ) -> ScreenshotAnnotationNode {
        let newBounds = requestedBounds.intersection(document.cropRect)
        guard newBounds.width >= 3, newBounds.height >= 3 else { return node }
        let old = Self.nonDegenerate(oldBounds)
        let map: (CGPoint) -> CGPoint = { point in
            CGPoint(
                x: newBounds.minX + (point.x - old.minX) * newBounds.width / old.width,
                y: newBounds.minY + (point.y - old.minY) * newBounds.height / old.height
            )
        }
        let mapRect: (CGRect) -> CGRect = { rect in
            let first = map(CGPoint(x: rect.minX, y: rect.minY))
            let second = map(CGPoint(x: rect.maxX, y: rect.maxY))
            return Self.rect(from: first, to: second)
        }

        var node = node
        switch node.kind {
        case let .arrow(start, end): node.kind = .arrow(start: map(start), end: map(end))
        case let .line(start, end): node.kind = .line(start: map(start), end: map(end))
        case let .rectangle(rect): node.kind = .rectangle(mapRect(rect))
        case let .filledRectangle(rect): node.kind = .filledRectangle(mapRect(rect))
        case let .ellipse(rect): node.kind = .ellipse(mapRect(rect))
        case let .stroke(points): node.kind = .stroke(points.map(map))
        case let .highlight(points): node.kind = .highlight(points.map(map))
        case let .text(text, origin):
            node.kind = .text(text, origin: map(origin))
            let scale = min(newBounds.width / old.width, newBounds.height / old.height)
            node.fontSize = max(9, node.fontSize * scale)
        case let .blur(rect, radius): node.kind = .blur(mapRect(rect), radius: radius)
        case let .pixelate(rect, scale): node.kind = .pixelate(mapRect(rect), scale: scale)
        case let .spotlight(rect): node.kind = .spotlight(mapRect(rect))
        case let .counter(number, center):
            node.kind = .counter(number, center: map(center))
            let scale = min(newBounds.width / old.width, newBounds.height / old.height)
            node.fontSize = max(14, node.fontSize * scale)
        }
        return node
    }

    private func resizedBounds(
        _ bounds: CGRect,
        handle: ScreenshotSelectionHandle,
        point: CGPoint
    ) -> CGRect {
        let anchor: CGPoint
        switch handle {
        case .topLeft: anchor = CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .topRight: anchor = CGPoint(x: bounds.minX, y: bounds.maxY)
        case .bottomLeft: anchor = CGPoint(x: bounds.maxX, y: bounds.minY)
        case .bottomRight: anchor = CGPoint(x: bounds.minX, y: bounds.minY)
        }
        let rect = Self.rect(from: anchor, to: point)
        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(8, rect.width),
            height: max(8, rect.height)
        )
    }

    private func isMeaningful(_ node: ScreenshotAnnotationNode) -> Bool {
        switch node.kind {
        case let .arrow(start, end), let .line(start, end):
            return hypot(end.x - start.x, end.y - start.y) >= 3
        case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
             let .blur(rect, _), let .pixelate(rect, _), let .spotlight(rect):
            return rect.width >= 3 && rect.height >= 3
        case let .stroke(points), let .highlight(points):
            return points.count >= 2
        case let .text(text, _):
            return !text.isEmpty
        case .counter:
            return true
        }
    }

    private func hitTestAnnotation(at point: CGPoint) -> ScreenshotAnnotationNode? {
        let tolerance = max(3, 8 / max(0.01, imageDrawingRect.width / document.cropRect.width))
        return document.annotations.reversed().first { node in
            switch node.kind {
            case let .arrow(start, end), let .line(start, end):
                return Self.distance(point, toSegmentFrom: start, to: end) <= tolerance
            case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
                 let .blur(rect, _), let .pixelate(rect, _), let .spotlight(rect):
                return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case let .stroke(points), let .highlight(points):
                return zip(points, points.dropFirst()).contains { pair in
                    Self.distance(point, toSegmentFrom: pair.0, to: pair.1) <= tolerance
                }
            case .text, .counter:
                return bounds(of: node).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
        }
    }

    private func bounds(of node: ScreenshotAnnotationNode) -> CGRect {
        switch node.kind {
        case let .arrow(start, end), let .line(start, end):
            return Self.nonDegenerate(Self.rect(from: start, to: end))
        case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
             let .blur(rect, _), let .pixelate(rect, _), let .spotlight(rect):
            return Self.nonDegenerate(rect.standardized)
        case let .stroke(points), let .highlight(points):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return Self.nonDegenerate(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        case let .text(text, origin):
            let size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: node.fontSize, weight: .semibold)])
            return Self.nonDegenerate(CGRect(origin: origin, size: size))
        case let .counter(_, center):
            let diameter = max(24, node.fontSize * 1.6)
            return CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        }
    }

    private func selectionHandle(
        at viewPoint: CGPoint,
        for node: ScreenshotAnnotationNode
    ) -> ScreenshotSelectionHandle? {
        let mapping = ScreenshotRenderMapping(
            cropRect: document.cropRect,
            destinationRect: imageDrawingRect,
            isFlippedSurface: true
        )
        let rect = mapping.rect(bounds(of: node))
        let handles: [(ScreenshotSelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        return handles.first { _, center in
            abs(viewPoint.x - center.x) <= 8 && abs(viewPoint.y - center.y) <= 8
        }?.0
    }

    private func draw(nodes: [ScreenshotAnnotationNode], mapping: ScreenshotRenderMapping) {
        let visible = visibleImageRect
        let filters = nodes.filter { node in
            switch node.kind { case .blur, .pixelate: return true; default: return false }
        }
        let desiredScale = min(1, mapping.scale * (window?.backingScaleFactor ?? 1))
        var level = max(0, Int(floor(-log2(max(0.0001, desiredScale)))))
        let area = filters.reduce(CGFloat(0)) { total, node in
            let rect = bounds(of: node).intersection(visible)
            return total + (rect.isNull ? 0 : rect.width * rect.height)
        }
        // Fit every visible filter into the shared cache, rather than thrash
        // between overlapping full-viewport masks. Export stays full resolution.
        while area * pow(0.25, CGFloat(level)) * 4 > 12 * 1_024 * 1_024 { level += 1 }
        let outputScale = pow(0.5, CGFloat(level))
        let sourceSnapshot = ScreenshotRenderSnapshot(source: baseCGImage, stateID: document.id,
            cropRect: document.cropRect, annotations: [], rasterSource: rasterSource)
        filterPreviewCache.beginFrame()
        defer { filterPreviewCache.endFrame() }
        do {
            for node in nodes {
                switch node.kind {
                case .blur, .pixelate:
                    let region = bounds(of: node).intersection(visible).intersection(imageBounds).integral
                    guard !region.isNull, !region.isEmpty else { continue }
                    let key = ScreenshotFilterPreviewCache.Key(stateID: document.id, nodeID: node.id, sourceRect: region, level: level)
                    if let filtered = filterPreviewCache.image(for: key, producer: {
                        try? ScreenshotDocumentRenderer(snapshot: sourceSnapshot)
                            .renderFilterPreview(node: node, region: region, outputScale: outputScale)
                    }) {
                        let image = NSImage(cgImage: filtered, size: region.size)
                        image.cacheMode = .never
                        image.draw(in: mapping.rect(region), from: .zero, operation: .copy, fraction: 1,
                                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
                    } else {
                        NSColor.black.setFill()
                        mapping.rect(region).fill()
                    }
                default:
                    try previewRenderer.draw(nodes: [node], mapping: mapping, visibleSourceRect: visible)
                }
            }
        } catch {
            // Never silently show an unmasked source as if a failed filter were
            // applied. The editor still retains the source and annotations.
            NSColor.black.setFill()
            mapping.rect(visible).fill()
            ("预览渲染失败，请重试" as NSString).draw(at: CGPoint(x: 30, y: 30),
                withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
        }
    }

    private func drawCropOverlay(mapping: ScreenshotRenderMapping) {
        guard let draftCropRect else { return }
        let cropRect = mapping.rect(draftCropRect)
        let overlay = NSBezierPath(rect: mapping.destinationRect)
        overlay.append(NSBezierPath(rect: cropRect))
        overlay.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill()
        overlay.fill()

        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = 2
        border.stroke()
    }

    private func drawSelection(mapping: ScreenshotRenderMapping) {
        guard let selectedAnnotationID,
              let node = annotation(with: selectedAnnotationID) else {
            return
        }
        let rect = mapping.rect(bounds(of: node)).insetBy(dx: -3, dy: -3)
        let selectionColor = NSColor.controlAccentColor
        selectionColor.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = tool == .select ? 2 : 1.5
        border.setLineDash([6, 3], count: 2, phase: 0)
        border.stroke()

        guard tool == .select else { return }

        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for point in points {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            selectionColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
            NSColor.white.setStroke()
            let outline = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private static func nonDegenerate(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let width = max(1, rect.width)
        let height = max(1, rect.height)
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func distance(
        _ point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = min(
            1,
            max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
        )
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }
}
