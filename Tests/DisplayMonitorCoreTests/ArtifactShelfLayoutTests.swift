import AppKit
import DisplayMonitorCore
import XCTest

@testable import DisplayMonitor

final class ArtifactShelfLayoutTests: XCTestCase {
    @MainActor
    func testRecordingResultCardUsesDedicatedPlaybackAndFileActions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording.mp4")
        let artifact = ArtifactManifest(
            id: UUID(),
            kind: .recording,
            status: .completed,
            canonicalURL: url,
            temporaryURL: url,
            dimensions: PixelSize(width: 1920, height: 1080),
            durationSeconds: 10,
            originOperationID: UUID(),
            activeOperationID: UUID(),
            contentByteCount: 1_024
        )
        var invoked: [String] = []
        let content = RecordingResultContentView(
            artifact: artifact,
            isPlayable: true,
            showsGIFExport: true,
            onPlay: { invoked.append("play") },
            onSaveCopy: { invoked.append("save") },
            onCopyFile: { invoked.append("copy") },
            onReveal: { invoked.append("finder") },
            onDelete: { invoked.append("delete") },
            onExportGIF: { invoked.append("gif") },
            onRetry: { invoked.append("retry") },
            onClose: { invoked.append("close") }
        )
        content.frame = CGRect(origin: .zero, size: RecordingResultContentView.preferredSize)
        content.layoutSubtreeIfNeeded()

        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        let titles = Set(buttons.map(\.title).filter { !$0.isEmpty })
        XCTAssertEqual(
            titles,
            Set(["播放", "保存副本", "复制文件", "Finder", "删除", "导出 GIF"])
        )
        for title in titles {
            try XCTUnwrap(buttons.first { $0.title == title }).performClick(nil)
        }
        XCTAssertEqual(Set(invoked), Set(["play", "save", "copy", "finder", "delete", "gif"]))
        XCTAssertEqual(content.intrinsicContentSize, CGSize(width: 260, height: 228))
    }

    @MainActor
    func testPreviewNativeWidthDoesNotExpandQuickAccessPanel() throws {
        let imageURL = try makePNG(width: 1_022, height: 261)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let artifact = ArtifactManifest(
            id: UUID(),
            kind: .still,
            status: .completed,
            canonicalURL: imageURL,
            temporaryURL: imageURL,
            previewURL: imageURL,
            dimensions: PixelSize(width: 1_022, height: 261),
            originOperationID: UUID(),
            activeOperationID: UUID()
        )
        let expectedSize = QuickAccessContentView.preferredSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let content = QuickAccessContentView(
            artifact: artifact,
            allowsFileActions: true,
            allowsEditing: true,
            onCopy: {},
            onEdit: {},
            onSave: {},
            onClose: {}
        )
        content.frame = CGRect(origin: .zero, size: expectedSize)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        panel.setContentSize(expectedSize)
        panel.setFrame(
            CGRect(x: 5_380, y: 105, width: expectedSize.width, height: expectedSize.height),
            display: false
        )
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(expectedSize.width, 260, accuracy: 0.01)
        XCTAssertEqual(expectedSize.height, 228, accuracy: 0.01)
        XCTAssertEqual(panel.frame.size.width, expectedSize.width, accuracy: 0.01)
        XCTAssertEqual(panel.frame.size.height, expectedSize.height, accuracy: 0.01)

        let previewImageView = try XCTUnwrap(
            descendants(of: content)
                .compactMap { $0 as? NSImageView }
                .max { lhs, rhs in
                    lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
                }
        )
        let previewContainer = try XCTUnwrap(previewImageView.superview)
        let previewFrame = content.convert(previewContainer.bounds, from: previewContainer)
        XCTAssertEqual(previewFrame.width, 242, accuracy: 0.01)
        XCTAssertEqual(previewFrame.height, 139, accuracy: 0.01)
    }

    @MainActor
    func testQuickAccessCardExposesWorkingEditActionForCompletedImage() throws {
        let imageURL = try makePNG(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let artifact = ArtifactManifest(
            id: UUID(),
            kind: .still,
            status: .completed,
            canonicalURL: imageURL,
            temporaryURL: imageURL,
            previewURL: imageURL,
            dimensions: PixelSize(width: 320, height: 180),
            originOperationID: UUID(),
            activeOperationID: UUID()
        )
        var didRequestEdit = false
        var saveRequestCount = 0
        let content = QuickAccessContentView(
            artifact: artifact,
            allowsFileActions: true,
            allowsEditing: true,
            onCopy: {},
            onEdit: { didRequestEdit = true },
            onSave: { saveRequestCount += 1 },
            onClose: {}
        )

        let editButton = try XCTUnwrap(
            descendants(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "编辑" }
        )
        let saveButton = try XCTUnwrap(
            descendants(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "保存" }
        )
        XCTAssertTrue(editButton.isEnabled)
        XCTAssertFalse(editButton.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertFalse(saveButton.isHiddenOrHasHiddenAncestor)

        let screenshotActionTitles = descendants(of: content)
            .compactMap { $0 as? NSButton }
            .map(\.title)
            .filter { !$0.isEmpty }
        XCTAssertEqual(Set(screenshotActionTitles), Set(["复制", "编辑", "保存"]))

        content.setHoverActionsVisible(true, animated: false)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(editButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(saveButton.isHiddenOrHasHiddenAncestor)

        for button in descendants(of: content)
            .compactMap({ $0 as? NSButton })
            .filter({ ["复制", "编辑", "保存"].contains($0.title) }) {
            button.updateLayer()
            let buttonSubviews = descendants(of: button)
            let iconView = try XCTUnwrap(buttonSubviews.compactMap { $0 as? NSImageView }.first)
            let label = try XCTUnwrap(buttonSubviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == button.title })
            let buttonColor = try XCTUnwrap(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            let iconFrame = button.convert(iconView.bounds, from: iconView)
            XCTAssertTrue(button.bounds.contains(iconFrame))
            XCTAssertEqual(button.frame.height, 27, accuracy: 0.01)
            XCTAssertGreaterThan(button.frame.width, 65)
            XCTAssertEqual(button.alphaValue, 1, accuracy: 0.01)
            XCTAssertFalse(button.allowsVibrancy)
            XCTAssertEqual(buttonColor.alphaComponent, 1, accuracy: 0.01)
            XCTAssertEqual(button.toolTip, button.title)
            XCTAssertEqual(button.accessibilityLabel(), button.title)
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        }

        editButton.performClick(nil)
        saveButton.performClick(nil)

        XCTAssertTrue(didRequestEdit)
        XCTAssertEqual(saveRequestCount, 1)

        content.setHoverActionsVisible(false, animated: false)
        XCTAssertFalse(editButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(saveButton.isHiddenOrHasHiddenAncestor)

        let contextMenuEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        let saveMenuItem = try XCTUnwrap(
            ([content] + descendants(of: content))
                .compactMap { $0.menu(for: contextMenuEvent) }
                .flatMap(\.items)
                .first { $0.title == "存储到设定位置" }
        )
        let saveAction = try XCTUnwrap(saveMenuItem.action)
        XCTAssertTrue(NSApplication.shared.sendAction(
            saveAction,
            to: saveMenuItem.target,
            from: saveMenuItem
        ))
        XCTAssertEqual(saveRequestCount, 2)
    }

    @MainActor
    func testQuickAccessPrimaryActionsRemainVisibleAcrossPointerStates() async throws {
        let imageURL = try makePNG(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let artifact = makeArtifact(imageURL: imageURL, width: 640, height: 360)
        let content = QuickAccessContentView(
            artifact: artifact,
            allowsFileActions: true,
            allowsEditing: true,
            onCopy: {},
            onEdit: {},
            onSave: {},
            onClose: {}
        )
        content.frame = CGRect(origin: .zero, size: QuickAccessContentView.preferredSize)
        await content.waitUntilPreviewIsReady()
        content.layoutSubtreeIfNeeded()

        let idlePNG = try renderPNG(of: content)
        content.setHoverActionsVisible(true, animated: false)
        content.layoutSubtreeIfNeeded()
        let hoverPNG = try renderPNG(of: content)

        XCTAssertFalse(idlePNG.isEmpty)
        XCTAssertFalse(hoverPNG.isEmpty)
        XCTAssertEqual(idlePNG, hoverPNG, "Moving the pointer must not reveal a previously hidden editing entry")

        if let outputPath = ProcessInfo.processInfo.environment["DISPLAY_MONITOR_VISUAL_FIXTURE_DIR"] {
            let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try idlePNG.write(to: outputDirectory.appendingPathComponent("quick-access-idle.png"))
            try hoverPNG.write(to: outputDirectory.appendingPathComponent("quick-access-hover.png"))
        }
    }

    @MainActor
    func testPinnedScreenshotCopyKeepsPinVisibleAndContextMenuCanCloseIt() async throws {
        _ = NSApplication.shared
        let imageURL = try makePNG(width: 320, height: 180)
        let sourceData = try Data(contentsOf: imageURL)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorPinnedStore-\(UUID().uuidString)", isDirectory: true)
        let selectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorPinnedSave-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: storeRoot)
            try? FileManager.default.removeItem(at: selectedDirectory)
            NSApp.windows
                .filter { $0.title == "固定截图" }
                .forEach { $0.close() }
        }

        var copyCount = 0
        let store = ArtifactStore(rootURL: storeRoot)
        let session = try await store.beginArtifact(
            kind: .still,
            fileExtension: "png",
            dimensions: PixelSize(width: 320, height: 180)
        )
        let artifact = try await store.finalizeData(sourceData, for: session)
        let controller = PinnedScreenshotController(
            artifactStore: store,
            screenshotSaveDirectory: { selectedDirectory },
            copyToPasteboard: { _, _ in copyCount += 1 }
        )
        await controller.present(artifact)

        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.title == "固定截图" && $0.isVisible && $0.contentView is PinnedScreenshotContentView
        })
        let content = try XCTUnwrap(panel.contentView as? PinnedScreenshotContentView)
        let contextMenuEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        let menu = try XCTUnwrap(content.menu(for: contextMenuEvent))
        XCTAssertEqual(menu.items.map(\.title), [
            "复制图片", "保存到设定位置", "", "倍率（相对初始尺寸）", "恢复初始尺寸",
            "不透明度", "", "关闭贴图", "关闭全部贴图"
        ])

        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "复制图片" })
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(copyItem.action),
            to: copyItem.target,
            from: copyItem
        ))
        XCTAssertEqual(copyCount, 1)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.hasPinnedScreenshots)

        let saved = expectation(description: "pinned screenshot saved without closing")
        controller.onStatusMessage = { message in
            if message.hasPrefix("已保存：") {
                saved.fulfill()
            }
        }
        let saveItem = try XCTUnwrap(menu.items.first { $0.title == "保存到设定位置" })
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(saveItem.action),
            to: saveItem.target,
            from: saveItem
        ))
        await fulfillment(of: [saved], timeout: 2)
        let destination = selectedDirectory
            .appendingPathComponent("Display Monitor Screenshot.png")
        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
        let savedArtifact = try await store.artifact(id: artifact.id)
        XCTAssertEqual(savedArtifact.desktopExportURL, destination)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.hasPinnedScreenshots)

        let closeItem = try XCTUnwrap(menu.items.first { $0.title == "关闭贴图" })
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(closeItem.action),
            to: closeItem.target,
            from: closeItem
        ))
        XCTAssertFalse(controller.hasPinnedScreenshots)
    }

    @MainActor
    func testEditingUpdatesTheExistingQuickAccessCardWithoutAddingCards() async throws {
        _ = NSApplication.shared
        let imageURL = try makePNG(width: 320, height: 180)
        let sourceData = try Data(contentsOf: imageURL)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorEditorRevisionStore-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: storeRoot)
            NSApp.windows
                .compactMap { $0.windowController as? ScreenshotEditorWindowController }
                .forEach { $0.closeWithoutConfirmation() }
            NSApp.windows
                .filter { $0.title == "截图浮窗" }
                .forEach { $0.close() }
        }

        let store = ArtifactStore(rootURL: storeRoot)
        let sourceSession = try await store.beginArtifact(
            kind: .still,
            fileExtension: "png",
            dimensions: PixelSize(width: 320, height: 180)
        )
        let source = try await store.finalizeData(sourceData, for: sourceSession)
        let controller = ArtifactShelfController(
            artifactStore: store
        )
        await controller.present(source)
        var visibleArtifact = source

        for saveIndex in 1...2 {
            let panel = try XCTUnwrap(NSApp.windows.first {
                $0.title == "截图浮窗" && $0.isVisible && $0.contentView is QuickAccessContentView
            })
            let content = try XCTUnwrap(panel.contentView as? QuickAccessContentView)
            content.setHoverActionsVisible(true, animated: false)
            content.layoutSubtreeIfNeeded()
            let editButton = try XCTUnwrap(
                descendants(of: content)
                    .compactMap { $0 as? NSButton }
                    .first { $0.title == "编辑" }
            )
            editButton.performClick(nil)

            let editorWindow = try XCTUnwrap(NSApp.windows.first {
                $0.title.hasPrefix("编辑截图") && $0.isVisible
            })
            let saveButton = try XCTUnwrap(
                editorWindow.contentView
                    .map(descendants(of:))?
                    .compactMap { $0 as? NSButton }
                    .first { $0.title == "保存" }
            )
            let revisionSaved = expectation(description: "revision \(saveIndex) saved")
            controller.onStatusMessage = { message in
                if message.hasPrefix("已保存编辑版本") {
                    revisionSaved.fulfill()
                }
            }
            saveButton.performClick(nil)
            await fulfillment(of: [revisionSaved], timeout: 2)

            editorWindow.performClose(nil)
            await Task.yield()

            let quickAccessPanels = NSApp.windows.filter {
                $0.title == "截图浮窗" && $0.isVisible && $0.contentView is QuickAccessContentView
            }
            XCTAssertEqual(quickAccessPanels.count, 1)
            let updatedContent = try XCTUnwrap(
                quickAccessPanels.first?.contentView as? QuickAccessContentView
            )
            XCTAssertTrue(
                descendants(of: updatedContent)
                    .compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue == "编辑版本" }
            )
            let revisions = try await store.childArtifacts(of: visibleArtifact.id)
            XCTAssertEqual(revisions.count, 1)
            let revision = try XCTUnwrap(revisions.first)
            visibleArtifact = revision
        }
    }

    func testPinCaptureActionHasItsOwnUserFacingLabel() {
        XCTAssertTrue(CaptureAction.allCases.contains(.pinStill))
        XCTAssertEqual(CaptureAction.pinStill.label, "贴图")
        XCTAssertEqual(CaptureAction.pinStill.symbolName, "pin.fill")
    }

    @MainActor
    func testCopyingOneQuickAccessCardRestoresTheRemainingCard() async throws {
        _ = NSApplication.shared
        let firstImageURL = try makePNG(width: 320, height: 180)
        let secondImageURL = try makePNG(width: 360, height: 200)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorQuickAccessStore-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstImageURL)
            try? FileManager.default.removeItem(at: secondImageURL)
            try? FileManager.default.removeItem(at: storeRoot)
            NSApp.windows
                .filter { $0.title == "截图浮窗" }
                .forEach { $0.close() }
        }

        let controller = ArtifactShelfController(
            artifactStore: ArtifactStore(rootURL: storeRoot),
            copyToPasteboard: { _, _ in }
        )
        await controller.present(makeArtifact(imageURL: firstImageURL, width: 320, height: 180))
        await controller.present(makeArtifact(imageURL: secondImageURL, width: 360, height: 200))

        let panels = NSApp.windows.filter {
            $0.title == "截图浮窗" && $0.contentView is QuickAccessContentView
        }
        XCTAssertEqual(panels.count, 2)
        let copiedPanel = try XCTUnwrap(panels.first)
        let copyButton = try XCTUnwrap(
            copiedPanel.contentView
                .map(descendants(of:))?
                .compactMap { $0 as? NSButton }
                .first { $0.title == "复制" }
        )

        // Closing the key utility panel can transiently order out its sibling
        // panels. The controller must explicitly restore the cards that remain.
        panels.dropFirst().forEach { $0.orderOut(nil) }
        copyButton.performClick(nil)

        let remainingPanels = NSApp.windows.filter {
            $0.title == "截图浮窗" && $0.contentView is QuickAccessContentView
        }
        XCTAssertEqual(remainingPanels.count, 1)
        XCTAssertTrue(try XCTUnwrap(remainingPanels.first).isVisible)
    }

    @MainActor
    func testSaveButtonWritesArtifactToConfiguredDirectory() async throws {
        _ = NSApplication.shared
        let imageURL = try makePNG(width: 320, height: 180)
        let sourceData = try Data(contentsOf: imageURL)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorSaveStore-\(UUID().uuidString)", isDirectory: true)
        let selectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorSelectedSave-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: storeRoot)
            try? FileManager.default.removeItem(at: selectedDirectory)
            NSApp.windows
                .filter { $0.title == "截图浮窗" }
                .forEach { $0.close() }
        }

        let store = ArtifactStore(rootURL: storeRoot)
        let session = try await store.beginArtifact(
            kind: .still,
            fileExtension: "png",
            dimensions: PixelSize(width: 320, height: 180)
        )
        let artifact = try await store.finalizeData(sourceData, for: session)
        let controller = ArtifactShelfController(
            artifactStore: store,
            screenshotSaveDirectory: { selectedDirectory }
        )
        let saved = expectation(description: "configured screenshot directory used")
        var statusMessages: [String] = []
        controller.onStatusMessage = { message in
            statusMessages.append(message)
            if message.hasPrefix("已保存：") {
                saved.fulfill()
            }
        }

        await controller.present(artifact)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.title == "截图浮窗" && $0.isVisible && $0.contentView is QuickAccessContentView
        })
        let content = try XCTUnwrap(panel.contentView as? QuickAccessContentView)
        content.setHoverActionsVisible(true, animated: false)
        content.layoutSubtreeIfNeeded()
        let saveButton = try XCTUnwrap(
            descendants(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "保存" }
        )

        saveButton.performClick(nil)
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertTrue(
            statusMessages.contains(where: { $0.hasPrefix("已保存：") }),
            "save status: \(statusMessages)"
        )

        let destination = selectedDirectory
            .appendingPathComponent("Display Monitor Screenshot.png")
        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
        let savedArtifact = try await store.artifact(id: artifact.id)
        XCTAssertEqual(savedArtifact.desktopExportURL, destination)
    }

    func testWindowCaptureGeometryConvertsQuartzTopLeftToAppKitBottomLeft() {
        XCTAssertEqual(
            WindowCaptureGeometry.appKitFrame(
                quartzFrame: CGRect(x: 120, y: 80, width: 800, height: 600),
                mainDisplayMaxY: 1080
            ),
            CGRect(x: 120, y: 400, width: 800, height: 600)
        )
    }

    @MainActor
    func testScreenshotEditorStartsWithPersistedToolAndPublishesNextSelection() throws {
        let imageURL = try makePNG(width: 320, height: 180)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )
        let controller = ScreenshotEditorWindowController(
            image: cgImage,
            fileURL: imageURL,
            preferredScreen: nil,
            initialTool: .spotlight
        )
        defer { controller.closeWithoutConfirmation() }

        XCTAssertEqual(controller.currentAnnotationTool, .spotlight)
        var publishedTool: ScreenshotAnnotationTool?
        controller.onToolSelected = { publishedTool = $0 }
        let rectangleButton = try XCTUnwrap(
            controller.window?.contentView
                .map(descendants(of:))?
                .compactMap { $0 as? NSButton }
                .first { $0.toolTip == "矩形" }
        )
        rectangleButton.performClick(nil)

        XCTAssertEqual(controller.currentAnnotationTool, .rectangle)
        XCTAssertEqual(publishedTool, .rectangle)
    }

    @MainActor
    private func makePNG(width: Int, height: Int) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data: Data = try XCTUnwrap(
            bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorQuickAccess-\(UUID().uuidString).png")
        try data.write(to: url, options: Data.WritingOptions.atomic)
        return url
    }

    private func makeArtifact(imageURL: URL, width: Int, height: Int) -> ArtifactManifest {
        ArtifactManifest(
            id: UUID(),
            kind: .still,
            status: .completed,
            canonicalURL: imageURL,
            temporaryURL: imageURL,
            previewURL: imageURL,
            dimensions: PixelSize(width: width, height: height),
            originOperationID: UUID(),
            activeOperationID: UUID()
        )
    }

    @MainActor
    private func renderPNG(of view: NSView) throws -> Data {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
