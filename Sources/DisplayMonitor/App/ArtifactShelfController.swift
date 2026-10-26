import AppKit
import DisplayMonitorCore
import ImageIO
import OSLog

private final class QuickAccessScreenObserverResources {
    var screenParametersObserver: NSObjectProtocol?
    var followTimer: Timer?

    deinit {
        followTimer?.invalidate()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }
}

/// A CleanShot-style, ephemeral Quick Access surface.
///
/// ArtifactStore remains the durable source of truth. This controller owns only
/// the small on-screen windows that help the user decide what to do with a
/// newly captured result. Editing opens an independent document window from
/// an individual card; this controller never turns into a history/editor page.
@MainActor
final class ArtifactShelfController {
    var onStatusMessage: ((String) -> Void)?

    // Editing remains unavailable while a capture session owns the input.
    var shouldRejectEditing: (() -> Bool)?
    var isGIFExportEnabled: () -> Bool = { false }
    var isGIFExporting: () -> Bool = { false }
    var onExportGIF: ((ArtifactManifest) -> Void)?
    var onCancelGIFExport: (() -> Void)?
    var onRetryRecording: (() -> Void)?

    private let artifactStore: ArtifactStore
    private let shouldAutoPresent: () -> Bool
    private let recentLimit: () -> Int
    private let shelfMargin: () -> CGFloat
    private let screenshotSaveDirectory: () -> URL
    private let initialAnnotationTool: () -> ScreenshotAnnotationTool
    private let onAnnotationToolSelected: (ScreenshotAnnotationTool) -> Void
    private let copyToPasteboard: @MainActor (ArtifactManifest, URL) throws -> Void
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "QuickAccess")

    private var overlays: [UUID: QuickAccessOverlay] = [:]
    /// Newer captures lead the list so they occupy the bottom-right slot.
    private var overlayOrder: [UUID] = []
    private var editorControllers: [UUID: ScreenshotEditorWindowController] = [:]
    private var playbackControllers: [UUID: RecordingPlaybackWindowController] = [:]
    private var isHidden = false
    private var lastInteractiveAnchor: ScreenshotShelfAnchor?
    private let screenObserverResources = QuickAccessScreenObserverResources()

    init(
        artifactStore: ArtifactStore,
        shouldAutoPresent: @escaping () -> Bool = { true },
        recentLimit: @escaping () -> Int = { 20 },
        shelfMargin: @escaping () -> CGFloat = { 16 },
        screenshotSaveDirectory: @escaping () -> URL = {
            ScreenshotOutputLocation.defaultDirectory()
        },
        initialAnnotationTool: @escaping () -> ScreenshotAnnotationTool = { .arrow },
        onAnnotationToolSelected: @escaping (ScreenshotAnnotationTool) -> Void = { _ in },
        copyToPasteboard: @MainActor @escaping (ArtifactManifest, URL) throws -> Void =
            ArtifactFileActions.writeToPasteboard
    ) {
        self.artifactStore = artifactStore
        self.shouldAutoPresent = shouldAutoPresent
        self.recentLimit = recentLimit
        self.shelfMargin = shelfMargin
        self.screenshotSaveDirectory = screenshotSaveDirectory
        self.initialAnnotationTool = initialAnnotationTool
        self.onAnnotationToolSelected = onAnnotationToolSelected
        self.copyToPasteboard = copyToPasteboard
    }

    var isVisible: Bool {
        overlays.values.contains { $0.panel.isVisible }
    }

    /// Recovery validates canonical artifacts, but Quick Access windows are
    /// intentionally process-local. Old captures must not reappear at launch.
    @discardableResult
    func start() async -> [ArtifactRecoveryResult] {
        do {
            let results = try await artifactStore.recoverAll()
            installScreenParametersObserver()
            return results
        } catch {
            report("恢复截图产物失败：\(error.localizedDescription)")
            return []
        }
    }

    /// Presents or updates exactly one capture window. It starts on the
    /// capture-completion pointer display, then interactive windows follow the
    /// pointer as a group while passive capture overlays stay fixed.
    func present(
        _ artifact: ArtifactManifest,
        passive: Bool = false,
        revealsWindow: Bool = true
    ) async {
        guard artifact.status != .discarded else {
            dismissOverlay(id: overlayID(displaying: artifact.id) ?? artifact.id)
            return
        }

        if let overlay = overlays[artifact.id] {
            // An existing capture slot may already be presenting a newer
            // editing revision. Do not let a late source-artifact update roll
            // its visible card back to the unedited image.
            guard overlay.artifact.id == artifact.id else {
                logger.info(
                    "quickAccess.present.ignoredStaleSource slot=\(overlay.id.uuidString, privacy: .public) source=\(artifact.id.uuidString, privacy: .public) visible=\(overlay.artifact.id.uuidString, privacy: .public)"
                )
                return
            }
            overlay.artifact = artifact
            overlay.isPassive = passive
            installContent(in: overlay)
        } else if let existingID = overlayID(displaying: artifact.id),
                  let overlay = overlays[existingID] {
            overlay.artifact = artifact
            overlay.isPassive = passive
            installContent(in: overlay)
        } else {
            let pointer = NSEvent.mouseLocation
            let screen = Self.screen(at: pointer) ?? NSScreen.main
            let anchor = screen.map(Self.anchor(for:)) ?? Self.fallbackAnchor
            let overlay = QuickAccessOverlay(
                id: artifact.id,
                artifact: artifact,
                anchor: anchor,
                isPassive: passive,
                panel: makePanel()
            )
            overlays[artifact.id] = overlay
            overlayOrder.removeAll { $0 == artifact.id }
            overlayOrder.insert(artifact.id, at: 0)
            installContent(in: overlay)
            logger.info(
                "quickAccess.presented artifact=\(artifact.id.uuidString, privacy: .public) sourceDisplay=\(artifact.displayID ?? 0, privacy: .public) pointerX=\(pointer.x, privacy: .public) pointerY=\(pointer.y, privacy: .public) anchorDisplay=\(anchor.displayID ?? 0, privacy: .public) passive=\(passive, privacy: .public)"
            )
        }

        trimExcessOverlays()
        reflowAllOverlays()

        if shouldAutoPresent(), revealsWindow, editorControllers.isEmpty {
            isHidden = false
            reanchorInteractiveOverlaysIfNeeded(force: true)
            showAllOverlays()
        }
    }

    func show() {
        guard !overlays.isEmpty else {
            report("当前没有待处理的截图浮窗")
            return
        }
        isHidden = false
        reanchorInteractiveOverlaysIfNeeded(force: true)
        reflowAllOverlays()
        showAllOverlays()
    }

    func hide() {
        isHidden = true
        stopFollowingPointer()
        overlays.values.filter { $0.activeFileDrag == nil }.forEach { $0.panel.orderOut(nil) }
    }

    func hideForCaptureSelection() {
        hide()
    }

    func toggleVisibility() {
        isVisible ? hide() : show()
    }

    /// Kept for the existing preferences contract. Quick Access no longer
    /// depends on the old single-panel setting; active action windows follow
    /// the pointer while click-through capture overlays remain fixed.
    func refreshFollowActiveDisplayPolicy() {
        reanchorInteractiveOverlaysIfNeeded(force: true)
        if isVisible {
            startFollowingPointer()
        }
    }

    func refresh() async {
        for id in overlayOrder {
            guard let overlay = overlays[id] else { continue }
            let artifactID = overlay.artifact.id
            do {
                let artifact = try await artifactStore.artifact(id: artifactID)
                if artifact.status == .discarded {
                    dismissOverlay(id: id)
                    continue
                }
                guard let currentOverlay = overlays[id],
                      currentOverlay.artifact.id == artifactID else {
                    continue
                }
                currentOverlay.artifact = artifact
                installContent(in: currentOverlay)
            } catch {
                dismissOverlay(id: id)
            }
        }
        reflowAllOverlays()
    }

    private func trimExcessOverlays(protecting protectedID: UUID? = nil) {
        // A new capture must not evict the drag source or be silently removed
        // itself. Defer the limit for the whole gesture; a cancelled drag keeps
        // both cards until the next ordinary presentation/action reapplies it.
        guard !hasFileDragInFlight, protectedID == nil else { return }
        let limit = max(1, recentLimit())
        while overlayOrder.count > limit,
              let oldestID = overlayOrder.reversed().first(where: {
                  $0 != protectedID && overlays[$0]?.activeFileDrag == nil
              }) {
            dismissOverlay(id: oldestID)
        }
    }

    private func installContent(in overlay: QuickAccessOverlay) {
        guard overlay.activeFileDrag == nil else {
            overlay.needsContentRefresh = true
            return
        }
        overlay.needsContentRefresh = false
        if overlay.artifact.kind == .recording {
            installRecordingContent(in: overlay)
            return
        }
        let canActOnArtifact = !overlay.isPassive && isActionable(overlay.artifact)
        let canEditArtifact = canActOnArtifact && isEditable(overlay.artifact)
        let content = QuickAccessContentView(
            artifact: overlay.artifact,
            allowsFileActions: canActOnArtifact,
            allowsEditing: canEditArtifact,
            onCopy: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.copyArtifact(in: overlay)
            },
            onEdit: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.editArtifact(in: overlay)
            },
            onSave: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.saveArtifact(in: overlay)
            },
            onClose: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.dismissOverlay(id: overlay.id)
            },
            onBeginFileDrag: canActOnArtifact ? { [weak self, weak overlay] in
                guard let self, let overlay else { return nil }
                return self.beginFileDrag(in: overlay)
            } : nil,
            onEndFileDrag: { [weak self, weak overlay] snapshot, operation in
                guard let self, let overlay else { return }
                self.finishFileDrag(in: overlay, snapshot: snapshot, operation: operation)
            }
        )
        content.frame = CGRect(
            origin: .zero,
            size: overlay.panel.contentView?.bounds.size ?? QuickAccessContentView.preferredSize
        )
        // The panel owns its bounds. The content view must resize with those
        // bounds instead of deriving a new width from its preview image.
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        overlay.panel.contentView = content
        overlay.panel.contentMinSize = .zero
        overlay.panel.contentMaxSize = CGSize(width: 10_000, height: 10_000)
        overlay.panel.minSize = .zero
        overlay.panel.maxSize = CGSize(width: 10_000, height: 10_000)
    }

    private func installRecordingContent(in overlay: QuickAccessOverlay) {
        let artifact = overlay.artifact
        let playableURL = recordingPlayableURL(for: artifact)
        let content = RecordingResultContentView(
            artifact: artifact,
            isPlayable: playableURL != nil,
            showsGIFExport: artifact.status == .completed &&
                isGIFExportEnabled() && !isGIFExporting(),
            onPlay: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.playRecording(in: overlay)
            },
            onSaveCopy: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.saveRecordingCopy(in: overlay)
            },
            onCopyFile: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.copyRecordingFile(in: overlay)
            },
            onReveal: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.revealRecording(in: overlay)
            },
            onDelete: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.deleteRecording(in: overlay)
            },
            onExportGIF: { [weak self] in
                self?.onExportGIF?(artifact)
            },
            onRetry: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.dismissOverlay(id: overlay.id)
                self.onRetryRecording?()
            },
            onClose: { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.dismissOverlay(id: overlay.id)
            },
            onBeginFileDrag: playableURL != nil && !overlay.isPassive ? { [weak self, weak overlay] in
                guard let self, let overlay else { return nil }
                return self.beginFileDrag(in: overlay)
            } : nil,
            onEndFileDrag: { [weak self, weak overlay] snapshot, operation in
                guard let self, let overlay else { return }
                self.finishFileDrag(in: overlay, snapshot: snapshot, operation: operation)
            }
        )
        content.frame = CGRect(
            origin: .zero,
            size: overlay.panel.contentView?.bounds.size ?? RecordingResultContentView.preferredSize
        )
        content.autoresizingMask = [.width, .height]
        overlay.panel.contentView = content
    }

    private func playRecording(in overlay: QuickAccessOverlay) {
        let artifact = overlay.artifact
        guard let url = recordingPlayableURL(for: artifact) else {
            report("当前录屏没有可播放的视频文件")
            return
        }
        if let existing = playbackControllers[artifact.id] {
            existing.show()
            return
        }
        let controller = RecordingPlaybackWindowController(url: url, title: "录屏")
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller,
                  self.playbackControllers[artifact.id] === controller else { return }
            self.playbackControllers.removeValue(forKey: artifact.id)
        }
        playbackControllers[artifact.id] = controller
        controller.show()
    }

    private func copyRecordingFile(in overlay: QuickAccessOverlay) {
        let artifact = overlay.artifact
        guard let url = recordingPlayableURL(for: artifact) else {
            report("当前录屏没有可复制的视频文件")
            return
        }
        do {
            try copyToPasteboard(artifact, url)
            report("已复制录屏文件")
        } catch {
            report("复制录屏文件失败：\(error.localizedDescription)")
        }
    }

    private func saveRecordingCopy(in overlay: QuickAccessOverlay) {
        let artifact = overlay.artifact
        guard let url = recordingPlayableURL(for: artifact) else {
            report("当前录屏没有可保存的视频文件")
            return
        }
        do {
            let destination = try ArtifactFileActions.saveCopy(
                artifact,
                sourceURL: url,
                directory: screenshotSaveDirectory()
            )
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.artifactStore.setDesktopExportURL(destination, for: artifact.id)
            }
            report("已保存录屏副本：\(destination.lastPathComponent)")
        } catch {
            report("保存录屏副本失败：\(error.localizedDescription)")
        }
    }

    private func revealRecording(in overlay: QuickAccessOverlay) {
        guard let url = recordingPlayableURL(for: overlay.artifact) else {
            report("当前录屏没有可显示的文件")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteRecording(in overlay: QuickAccessOverlay) {
        guard overlay.activeFileDrag == nil, !overlay.isDeleting else {
            report("正在拖出文件，结束拖放后可删除")
            return
        }
        overlay.isDeleting = true
        let artifactID = overlay.artifact.id
        let overlayID = overlay.id
        Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay else { return }
            defer { overlay.isDeleting = false }
            do {
                _ = try await self.artifactStore.discard(id: artifactID)
                self.playbackControllers.removeValue(forKey: artifactID)?.close()
                self.dismissOverlay(id: overlayID)
                self.report("录屏已移入可恢复回收区")
            } catch {
                self.report("删除录屏失败：\(error.localizedDescription)")
            }
        }
    }

    private func recordingPlayableURL(for artifact: ArtifactManifest) -> URL? {
        guard artifact.kind == .recording,
              artifact.status == .completed || artifact.status == .partial ||
                artifact.status == .recoveredPartial,
              FileManager.default.fileExists(atPath: artifact.canonicalURL.path) else {
            return nil
        }
        return artifact.canonicalURL
    }

    private func showAllOverlays() {
        guard !isHidden, editorControllers.isEmpty, !hasFileDragInFlight else { return }
        for id in overlayOrder.reversed() {
            guard let overlay = overlays[id], !overlay.isEditing else { continue }
            overlay.panel.ignoresMouseEvents = overlay.isPassive
            overlay.panel.level = overlay.isPassive ? .screenSaver : .statusBar
            overlay.panel.orderFrontRegardless()
        }
        startFollowingPointer()
    }

    private func dismissOverlay(id: UUID) {
        guard overlays[id]?.activeFileDrag == nil else {
            report("正在拖出文件，浮窗会保留到拖放结束")
            return
        }
        if let editor = editorControllers.removeValue(forKey: id) {
            editor.onClose = nil
            editor.closeWithoutConfirmation()
        }
        guard let overlay = overlays.removeValue(forKey: id) else { return }
        overlayOrder.removeAll { $0 == id }
        overlay.panel.orderOut(nil)
        overlay.panel.contentView = nil
        overlay.panel.close()
        reflowAllOverlays()
        logger.info(
            "quickAccess.dismissed artifact=\(id.uuidString, privacy: .public) remaining=\(self.overlayOrder.count, privacy: .public)"
        )
        if !isHidden, editorControllers.isEmpty {
            // Closing the key utility panel can order out sibling panels as a
            // group. Re-front only the overlays still tracked by their own ID.
            showAllOverlays()
        } else {
            startFollowingPointer()
        }
    }

    private func copyArtifact(in overlay: QuickAccessOverlay) {
        guard overlay.activeFileDrag == nil else { return }
        let artifact = overlay.artifact
        guard isActionable(artifact), let sourceURL = usableURL(for: artifact) else {
            report("当前截图尚未完成，浮窗会保留")
            return
        }

        do {
            try copyToPasteboard(artifact, sourceURL)
            dismissOverlay(id: overlay.id)
            report("已复制\(artifact.kind.label)，已从截图浮窗移除")
        } catch {
            report("复制失败，截图浮窗已保留：\(error.localizedDescription)")
        }
    }

    private func editArtifact(in overlay: QuickAccessOverlay) {
        guard overlay.activeFileDrag == nil else { return }
        let artifact = overlay.artifact
        let overlayID = overlay.id
        guard isEditable(artifact),
              isActionable(artifact),
              let sourceURL = usableURL(for: artifact) else {
            report("当前产物不支持编辑")
            return
        }
        guard !(shouldRejectEditing?() ?? false) else {
            report("当前有采集任务，暂时无法编辑")
            return
        }
        if let existing = editorControllers[overlayID] {
            existing.showEditor()
            return
        }

        do {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw QuickAccessActionError.imageDecodingFailed
            }
            let controller = ScreenshotEditorWindowController(
                image: image,
                fileURL: sourceURL,
                preferredScreen: Self.screen(matching: overlay.anchor),
                initialTool: initialAnnotationTool()
            )
            controller.onToolSelected = { [onAnnotationToolSelected] tool in
                onAnnotationToolSelected(tool)
            }
            let revisionService = ArtifactRevisionService(store: artifactStore, source: artifact)
            controller.onSaveRevision = { [weak self] data in
                let revision = try await revisionService.save(data)
                self?.replaceVisibleArtifact(in: overlayID, with: revision)
                self?.report("已保存编辑版本，截图浮窗已更新")
                return revision
            }
            controller.onExportRevision = { [weak self] revision, destinationURL in
                try await revisionService.export(revision, to: destinationURL)
                self?.report("已创建编辑版本并导出：\(destinationURL.lastPathComponent)")
            }
            controller.onClose = { [weak self, weak controller] _ in
                guard let self,
                      let controller,
                      self.editorControllers[overlayID] === controller else {
                    return
                }
                self.editorControllers.removeValue(forKey: overlayID)
                self.overlays[overlayID]?.isEditing = false
                guard !self.isHidden, self.editorControllers.isEmpty else { return }
                self.reflowAllOverlays()
                self.showAllOverlays()
            }

            editorControllers[overlayID] = controller
            overlay.isEditing = true
            overlay.panel.orderOut(nil)
            controller.showEditor()
            logger.info(
                "quickAccess.editor.opened artifact=\(artifact.id.uuidString, privacy: .public) sourceDisplay=\(artifact.displayID ?? 0, privacy: .public)"
            )
        } catch {
            report("打开编辑器失败：\(error.localizedDescription)")
            logger.error("quickAccess.editor.open.failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private func saveArtifact(in overlay: QuickAccessOverlay) {
        guard overlay.activeFileDrag == nil else { return }
        let artifact = overlay.artifact
        guard isActionable(artifact), let sourceURL = usableURL(for: artifact) else {
            report("当前截图尚未完成，浮窗会保留")
            return
        }

        Task { @MainActor [weak self] in
            await self?.saveArtifact(
                artifact,
                sourceURL: sourceURL,
                overlayID: overlay.id
            )
        }
    }

    private func saveArtifact(
        _ artifact: ArtifactManifest,
        sourceURL: URL,
        overlayID: UUID
    ) async {
        do {
            let destination = try ArtifactFileActions.saveCopy(
                artifact,
                sourceURL: sourceURL,
                directory: screenshotSaveDirectory()
            )
            _ = try await artifactStore.setDesktopExportURL(destination, for: artifact.id)
            dismissOverlay(id: overlayID)
            report("已保存：\(destination.lastPathComponent)，已从截图浮窗移除")
        } catch {
            report("保存失败，截图浮窗已保留：\(error.localizedDescription)")
        }
    }

    private func usableURL(for artifact: ArtifactManifest) -> URL? {
        ArtifactFileActions.usableURL(for: artifact)
    }

    func replaceVisibleArtifact(in overlayID: UUID, with artifact: ArtifactManifest) {
        guard let overlay = overlays[overlayID] else { return }
        overlay.artifact = artifact
        installContent(in: overlay)
        logger.info(
            "quickAccess.editor.revision.presented slot=\(overlayID.uuidString, privacy: .public) artifact=\(artifact.id.uuidString, privacy: .public)"
        )
    }

    private func overlayID(displaying artifactID: UUID) -> UUID? {
        overlays.first { $0.value.artifact.id == artifactID }?.key
    }

    private func isActionable(_ artifact: ArtifactManifest) -> Bool {
        artifact.status.isTerminal && artifact.status != .failed && artifact.status != .discarded
            && usableURL(for: artifact) != nil
    }

    private func isEditable(_ artifact: ArtifactManifest) -> Bool {
        switch artifact.kind {
        case .still, .scrollStill, .revision:
            return true
        case .recording, .gif:
            return false
        }
    }

    private var hasFileDragInFlight: Bool {
        overlays.values.contains { $0.activeFileDrag != nil }
    }

    private func beginFileDrag(in overlay: QuickAccessOverlay) -> ArtifactFileDragSnapshot? {
        guard !hasFileDragInFlight, !overlay.isPassive, !overlay.isEditing, !overlay.isDeleting else { return nil }
        do {
            let snapshot = try ArtifactFileDragSnapshot(artifact: overlay.artifact)
            overlay.activeFileDrag = snapshot
            stopFollowingPointer()
            return snapshot
        } catch {
            report("无法拖出文件：\(error.localizedDescription)")
            return nil
        }
    }

    private func finishFileDrag(
        in overlay: QuickAccessOverlay,
        snapshot: ArtifactFileDragSnapshot,
        operation: NSDragOperation
    ) {
        guard overlay.activeFileDrag?.token == snapshot.token else { return }
        overlay.activeFileDrag = nil
        // Only AppKit's completed copy receipt may dismiss this exact version.
        // A late receipt cannot remove a card that now presents a newer edit.
        var accepted = operation == .copy && snapshot.matches(overlay.artifact)
        if accepted {
            do { try snapshot.validateFileIdentity() }
            catch { accepted = false; report(error.localizedDescription) }
        }
        if accepted {
            dismissOverlay(id: overlay.id)
            report("目标应用已接受文件，已关闭对应浮窗")
        } else {
            if overlay.needsContentRefresh { installContent(in: overlay) }
            report(operation == .copy ? "文件版本已更新，当前浮窗已保留" : "拖放已取消或未被接受，浮窗已保留")
        }
        trimExcessOverlays(protecting: accepted ? nil : overlay.id)
        reflowAllOverlays()
        if isHidden { overlays.values.forEach { $0.panel.orderOut(nil) } }
        else { showAllOverlays() }
    }

    private func reflowAllOverlays() {
        guard !overlays.isEmpty, !hasFileDragInFlight else { return }

        let groupedIDs = Dictionary(grouping: overlayOrder) { id in
            QuickAccessLayoutGroup(
                displayID: overlays[id]?.anchor.displayID,
                isPassive: overlays[id]?.isPassive ?? false
            )
        }
        for ids in groupedIDs.values {
            guard let firstID = ids.first, let firstOverlay = overlays[firstID] else { continue }
            let resolvedAnchor = Self.currentAnchor(matching: firstOverlay.anchor) ?? firstOverlay.anchor
            let frames = ScreenshotQuickAccessPlacement.frames(
                in: resolvedAnchor.visibleFrame,
                preferredSize: QuickAccessContentView.preferredSize,
                count: ids.count,
                margin: effectiveShelfMargin(),
                spacing: 12
            )
            for (id, frame) in zip(ids, frames) {
                guard let overlay = overlays[id], frame != .zero else { continue }
                overlay.anchor = resolvedAnchor
                overlay.panel.setContentSize(frame.size)
                overlay.panel.setFrame(frame, display: true, animate: false)
                overlay.panel.contentView?.layoutSubtreeIfNeeded()
                let actualFrame = overlay.panel.frame
                logger.info(
                    "quickAccess.layout displayID=\(resolvedAnchor.displayID ?? 0, privacy: .public) expectedX=\(frame.minX, privacy: .public) expectedY=\(frame.minY, privacy: .public) expectedWidth=\(frame.width, privacy: .public) expectedHeight=\(frame.height, privacy: .public) actualX=\(actualFrame.minX, privacy: .public) actualY=\(actualFrame.minY, privacy: .public) actualWidth=\(actualFrame.width, privacy: .public) actualHeight=\(actualFrame.height, privacy: .public)"
                )
            }
        }
    }

    private func effectiveShelfMargin() -> CGFloat {
        max(16, shelfMargin())
    }

    private func installScreenParametersObserver() {
        guard screenObserverResources.screenParametersObserver == nil else { return }
        screenObserverResources.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reanchorInteractiveOverlaysIfNeeded(force: true)
                self?.reflowAllOverlays()
            }
        }
    }

    private func startFollowingPointer() {
        guard !isHidden, !interactiveOverlayIDs.isEmpty, !hasFileDragInFlight else {
            stopFollowingPointer()
            return
        }
        if screenObserverResources.followTimer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reanchorInteractiveOverlaysIfNeeded()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            screenObserverResources.followTimer = timer
            logger.info("quickAccess.follow.started")
        }
        reanchorInteractiveOverlaysIfNeeded(force: true)
    }

    private func stopFollowingPointer() {
        guard screenObserverResources.followTimer != nil || lastInteractiveAnchor != nil else { return }
        screenObserverResources.followTimer?.invalidate()
        screenObserverResources.followTimer = nil
        lastInteractiveAnchor = nil
        logger.info("quickAccess.follow.stopped")
    }

    private var interactiveOverlayIDs: [UUID] {
        overlayOrder.filter { id in
            guard let overlay = overlays[id] else { return false }
            return !overlay.isPassive
        }
    }

    private func reanchorInteractiveOverlaysIfNeeded(force: Bool = false) {
        guard !isHidden, !hasFileDragInFlight,
              !interactiveOverlayIDs.isEmpty,
              let screen = Self.screen(at: NSEvent.mouseLocation) else {
            return
        }
        let anchor = Self.anchor(for: screen)
        guard force || ScreenshotShelfFollowPolicy.needsReanchor(
            previous: lastInteractiveAnchor,
            current: anchor
        ) else {
            return
        }

        for id in interactiveOverlayIDs {
            overlays[id]?.anchor = anchor
        }
        lastInteractiveAnchor = anchor
        reflowAllOverlays()
        logger.info("quickAccess.follow.reanchored displayID=\(anchor.displayID ?? 0, privacy: .public)")
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: CGRect(origin: .zero, size: QuickAccessContentView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图浮窗"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func report(_ message: String) {
        logger.info("quickAccess.message \(message, privacy: .public)")
        onStatusMessage?(message)
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return containingScreen
        }
        return NSScreen.screens.min {
            distanceSquared(from: point, to: $0.frame) < distanceSquared(from: point, to: $1.frame)
        } ?? NSScreen.main
    }

    private static func currentAnchor(matching anchor: ScreenshotShelfAnchor) -> ScreenshotShelfAnchor? {
        screen(matching: anchor).map(Self.anchor(for:))
    }

    private static func screen(matching anchor: ScreenshotShelfAnchor) -> NSScreen? {
        NSScreen.screens.first { screen in
            let candidate = self.anchor(for: screen)
            if let displayID = anchor.displayID {
                return candidate.displayID == displayID
            }
            return candidate.frame == anchor.frame
        }
    }

    private static func anchor(for screen: NSScreen) -> ScreenshotShelfAnchor {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
        return ScreenshotShelfAnchor(
            displayID: displayID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private static var fallbackAnchor: ScreenshotShelfAnchor {
        ScreenshotShelfAnchor(
            displayID: nil,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private struct QuickAccessLayoutGroup: Hashable {
    let displayID: UInt32?
    let isPassive: Bool
}

@MainActor
private final class QuickAccessOverlay {
    let id: UUID
    var artifact: ArtifactManifest
    var anchor: ScreenshotShelfAnchor
    var isPassive: Bool
    var isEditing = false
    var isDeleting = false
    var activeFileDrag: ArtifactFileDragSnapshot?
    var needsContentRefresh = false
    let panel: QuickAccessPanel

    init(
        id: UUID,
        artifact: ArtifactManifest,
        anchor: ScreenshotShelfAnchor,
        isPassive: Bool,
        panel: QuickAccessPanel
    ) {
        self.id = id
        self.artifact = artifact
        self.anchor = anchor
        self.isPassive = isPassive
        self.panel = panel
    }
}

private enum QuickAccessActionError: LocalizedError {
    case imageDecodingFailed

    var errorDescription: String? {
        switch self {
        case .imageDecodingFailed:
            return "无法读取截图图片"
        }
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !ignoresMouseEvents {
            // Borrow keyboard focus within this nonactivating panel. Activating
            // the application here can also bring its settings window forward.
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }
}

final class RecordingResultContentView: NSVisualEffectView {
    static let preferredSize = CGSize(width: 260, height: 228)

    init(
        artifact: ArtifactManifest,
        isPlayable: Bool,
        showsGIFExport: Bool,
        onPlay: @escaping () -> Void,
        onSaveCopy: @escaping () -> Void,
        onCopyFile: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onExportGIF: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onBeginFileDrag: (() -> ArtifactFileDragSnapshot?)? = nil,
        onEndFileDrag: ((ArtifactFileDragSnapshot, NSDragOperation) -> Void)? = nil
    ) {
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.38).cgColor
        layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "录屏")
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let badge = QuickAccessStatusBadge(status: artifact.status)
        let close = QuickAccessIconButton(symbol: "xmark", toolTip: "关闭录屏结果", action: onClose)
        let header = NSStackView(views: [title, badge, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let status = NSTextField(labelWithString: Self.primaryText(for: artifact))
        status.font = .systemFont(ofSize: 18, weight: .semibold)
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail

        let detail = Self.detailText(for: artifact) + (onBeginFileDrag == nil ? "" : " · 可拖出文件")
        let details = NSTextField(labelWithString: detail)
        details.font = .systemFont(ofSize: 10.5, weight: .medium)
        details.textColor = .secondaryLabelColor
        details.alignment = .center
        details.lineBreakMode = .byTruncatingMiddle

        let mainAction: NSButton
        if isPlayable {
            mainAction = Self.button(title: "播放", prominent: true, action: onPlay)
        } else {
            mainAction = Self.button(title: "重新录制", prominent: true, action: onRetry)
        }

        let save = Self.button(title: "保存副本", action: onSaveCopy)
        let copy = Self.button(title: "复制文件", action: onCopyFile)
        let reveal = Self.button(title: "Finder", action: onReveal)
        let delete = Self.button(title: isPlayable ? "删除" : "丢弃诊断", action: onDelete)
        [save, copy, reveal].forEach { $0.isEnabled = isPlayable }
        let actionRow = NSStackView(views: [save, copy, reveal, delete])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually
        actionRow.spacing = 4

        let dragArea = ArtifactFileDragView()
        dragArea.onBeginFileDrag = onBeginFileDrag
        dragArea.onEndFileDrag = onEndFileDrag
        dragArea.toolTip = onBeginFileDrag == nil ? nil : "拖出录屏文件到 Finder 或其他应用"
        dragArea.setAccessibilityLabel("录屏文件拖出区域")
        let summary = NSStackView(views: [status, details])
        summary.orientation = .vertical
        summary.alignment = .centerX
        summary.spacing = 7
        dragArea.addSubview(summary)
        summary.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: dragArea.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: dragArea.trailingAnchor),
            summary.topAnchor.constraint(equalTo: dragArea.topAnchor),
            summary.bottomAnchor.constraint(equalTo: dragArea.bottomAnchor),
            status.widthAnchor.constraint(equalTo: summary.widthAnchor),
            details.widthAnchor.constraint(equalTo: summary.widthAnchor)
        ])
        let stack = NSStackView(views: [header, dragArea, mainAction, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(11, after: header)
        [header, dragArea, mainAction, actionRow].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        mainAction.heightAnchor.constraint(equalToConstant: 31).isActive = true
        actionRow.heightAnchor.constraint(equalToConstant: 27).isActive = true

        if showsGIFExport {
            let gif = Self.button(title: "导出 GIF", action: onExportGIF)
            gif.heightAnchor.constraint(equalToConstant: 25).isActive = true
            stack.addArrangedSubview(gif)
            gif.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    private static func primaryText(for artifact: ArtifactManifest) -> String {
        if artifact.status == .failed {
            return RecordingErrorPresentation.message(
                errorCode: artifact.errorCode,
                storedMessage: artifact.errorMessage
            )
        }
        let duration = artifact.durationSeconds ?? 0
        return String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
    }

    private static func detailText(for artifact: ArtifactManifest) -> String {
        var values: [String] = []
        if let dimensions = artifact.dimensions {
            values.append("\(dimensions.width) × \(dimensions.height)")
        }
        if let bytes = artifact.contentByteCount ?? fileByteCount(at: artifact.canonicalURL) {
            values.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        values.append("无音频")
        return values.joined(separator: " · ")
    }

    private static func fileByteCount(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func button(
        title: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = RecordingResultButton(title: title, action: action)
        button.bezelStyle = prominent ? .rounded : .recessed
        button.font = .systemFont(ofSize: prominent ? 12 : 10.5, weight: .semibold)
        button.setAccessibilityLabel(title)
        return button
    }
}

private final class RecordingResultButton: NSButton {
    private let actionBlock: () -> Void

    init(title: String, action: @escaping () -> Void) {
        actionBlock = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed() {
        actionBlock()
    }
}

final class QuickAccessContentView: NSVisualEffectView {
    static let preferredSize = CGSize(width: 260, height: 228)

    private static let mediaPreviewHeight: CGFloat = 139

    private let previewContainer = QuickAccessHoverView()
    private var previewTask: Task<Void, Never>?
    private(set) var previewDidLoad = false
    private(set) var previewFailure: String?

    init(
        artifact: ArtifactManifest,
        allowsFileActions: Bool,
        allowsEditing: Bool,
        onCopy: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onBeginFileDrag: (() -> ArtifactFileDragSnapshot?)? = nil,
        onEndFileDrag: ((ArtifactFileDragSnapshot, NSDragOperation) -> Void)? = nil
    ) {
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.38).cgColor
        layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: artifact.kind.label)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor

        let statusBadge = QuickAccessStatusBadge(status: artifact.status)

        let closeButton = QuickAccessIconButton(
            symbol: "xmark",
            toolTip: "关闭截图浮窗",
            action: onClose
        )
        let titleStack = NSStackView(views: [titleLabel, statusBadge])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6

        let header = NSStackView(views: [titleStack, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        previewContainer.onBeginFileDrag = onBeginFileDrag
        previewContainer.onEndFileDrag = onEndFileDrag
        if onBeginFileDrag != nil {
            previewContainer.toolTip = "拖出文件到 Finder 或其他应用"
            previewContainer.setAccessibilityLabel("可拖出文件的预览")
        }
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        previewContainer.layer?.cornerRadius = 10
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor
        previewContainer.layer?.masksToBounds = true
        addPreview(for: artifact)

        let detail = Self.detailText(for: artifact) + (onBeginFileDrag == nil ? "" : " · 可拖出文件")
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .center

        [header, previewContainer, detailLabel].forEach { view in
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        var constraints = [
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 18),

            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            previewContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            detailLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 4),
            detailLabel.heightAnchor.constraint(equalToConstant: 14)
        ]

        previewContainer.onSave = allowsFileActions ? onSave : nil
        let copyButton = QuickAccessActionButton(title: "复制", symbol: "doc.on.doc", isPrimary: false, action: onCopy)
        let editButton = QuickAccessActionButton(title: "编辑", symbol: "square.and.pencil", isPrimary: true, action: onEdit)
        let saveButton = QuickAccessActionButton(title: "保存", symbol: "square.and.arrow.down", isPrimary: false, action: onSave)
        copyButton.isEnabled = allowsFileActions
        saveButton.isEnabled = allowsFileActions
        editButton.isEnabled = allowsEditing
        [copyButton, editButton, saveButton].forEach { $0.heightAnchor.constraint(equalToConstant: 27).isActive = true }
        let actionStack = NSStackView(views: [copyButton, editButton, saveButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .fillEqually
        actionStack.spacing = 5
        addSubview(actionStack)
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        constraints.append(contentsOf: [
            previewContainer.heightAnchor.constraint(equalToConstant: Self.mediaPreviewHeight),
            actionStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            actionStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 5),
            actionStack.heightAnchor.constraint(equalToConstant: 27),
            actionStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        Self.preferredSize
    }

    /// Kept for callers exercising older hover behavior. Primary actions are
    /// now always visible, including while the pointer is outside the card.
    func setHoverActionsVisible(_ visible: Bool, animated: Bool = true) {}

    func waitUntilPreviewIsReady() async {
        if let previewTask { await previewTask.value }
    }

    deinit { previewTask?.cancel() }

    private func addPreview(for artifact: ArtifactManifest) {
        guard artifact.kind != .recording else { addFallbackPreview(for: artifact); return }
        let isLong = artifact.dimensions.map { $0.height > $0.width * 2 } ?? (artifact.kind == .scrollStill)
        let mainPreview = QuickAccessPreviewImageView()
        mainPreview.identifier = NSUserInterfaceItemIdentifier("QuickAccessMainPreview")
        mainPreview.imageScaling = .scaleProportionallyUpOrDown
        mainPreview.imageAlignment = isLong ? .alignTop : .alignCenter
        mainPreview.setAccessibilityElement(false)
        mainPreview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(mainPreview)
        var overview: QuickAccessPreviewImageView?
        if isLong {
            let strip = QuickAccessPreviewImageView()
            strip.identifier = NSUserInterfaceItemIdentifier("QuickAccessLongOverview")
            strip.imageScaling = .scaleProportionallyUpOrDown
            strip.imageAlignment = .alignTop
            strip.setAccessibilityElement(false)
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.wantsLayer = true
            strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
            strip.layer?.cornerRadius = 3
            previewContainer.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -4),
                strip.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 4),
                strip.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -4),
                strip.widthAnchor.constraint(equalToConstant: 24),
                mainPreview.trailingAnchor.constraint(equalTo: strip.leadingAnchor, constant: -5)
            ])
            overview = strip
            let caption = NSTextField(labelWithString: "顶部预览")
            caption.font = .systemFont(ofSize: 9, weight: .medium)
            caption.textColor = .white
            caption.backgroundColor = NSColor.black.withAlphaComponent(0.72)
            caption.drawsBackground = true
            caption.setAccessibilityElement(false)
            caption.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(caption)
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 7),
                caption.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6)
            ])
            previewContainer.setAccessibilityLabel("长图顶部预览与全长概览，可拖出完整文件")
        } else {
            mainPreview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -3).isActive = true
        }
        NSLayoutConstraint.activate([
            mainPreview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 3),
            mainPreview.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 3),
            mainPreview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -3)
        ])
        let loadStatus = NSTextField(labelWithString: "正在准备预览…")
        loadStatus.font = .systemFont(ofSize: 10)
        loadStatus.textColor = .secondaryLabelColor
        loadStatus.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(loadStatus)
        NSLayoutConstraint.activate([
            loadStatus.centerXAnchor.constraint(equalTo: mainPreview.centerXAnchor),
            loadStatus.centerYAnchor.constraint(equalTo: mainPreview.centerYAnchor, constant: -30)
        ])
        let canonicalURL = artifact.canonicalURL
        let fallbackURL = Self.previewURL(for: artifact)
        let worker = Task.detached(priority: .utility) {
            try? QuickAccessThumbnailRenderer.render(canonicalURL: canonicalURL, boundedPreviewURL: fallbackURL, isLong: isLong)
        }
        previewTask = Task { [weak self, weak mainPreview, weak overview, weak loadStatus] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            if let result {
                mainPreview?.image = NSImage(cgImage: result.main, size: CGSize(width: result.main.width, height: result.main.height))
                if let image = result.overview {
                    overview?.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                }
                self.previewDidLoad = true
                loadStatus?.isHidden = true
            } else {
                self.previewFailure = "预览暂不可用，仍可编辑、保存或拖出原文件"
                loadStatus?.stringValue = "预览暂不可用"
                self.addFallbackPreview(for: artifact)
            }
            self.previewTask = nil
        }
    }

    private func addFallbackPreview(for artifact: ArtifactManifest) {
        let symbol: String
        switch artifact.kind {
        case .recording:
            symbol = artifact.status.isTerminal ? "play.rectangle.fill" : "record.circle"
        case .gif:
            symbol = "sparkles.rectangle.stack"
        case .scrollStill:
            symbol = "rectangle.portrait.on.rectangle.portrait"
        case .still, .revision:
            symbol = "photo"
        }
        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: artifact.kind.label
        ) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 34, weight: .medium)
        previewContainer.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
        ])
    }

    private static func previewURL(for artifact: ArtifactManifest) -> URL? {
        let fileManager = FileManager.default
        return [artifact.previewURL, artifact.canonicalURL, artifact.temporaryURL]
            .compactMap { $0 }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func detailText(for artifact: ArtifactManifest) -> String {
        if let errorMessage = artifact.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let dimensions = artifact.dimensions {
            return "\(dimensions.width) × \(dimensions.height)" + (dimensions.height > dimensions.width * 2 ? " · 长图" : "")
        }
        if let duration = artifact.durationSeconds {
            return String(format: "%.1f 秒", duration)
        }
        return "复制或存储后自动从这里移除"
    }
}

/// Tracks the preview slot instead of the whole utility panel. Header and
/// close-button movement therefore does not flash the quick actions.
private final class QuickAccessHoverView: ArtifactFileDragView {
    var onHoverChanged: ((Bool) -> Void)?
    var onSave: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        super.mouseExited(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onSave != nil else { return nil }
        let menu = NSMenu(title: "截图操作")
        let saveItem = NSMenuItem(
            title: "存储到设定位置",
            action: #selector(saveFromContextMenu),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)
        return menu
    }

    @objc private func saveFromContextMenu() {
        onSave?()
    }
}

/// A preview is drawn into a fixed card slot, not laid out at the captured
/// image's native pixel width. NSImageView otherwise exposes that width as an
/// intrinsic size and can expand an NSPanel beyond its requested frame.
private final class QuickAccessPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private final class QuickAccessStatusBadge: NSView {
    private let statusLabel: NSTextField

    init(status: ArtifactStatus) {
        let accentColor: NSColor
        switch status {
        case .completed:
            accentColor = .systemGreen
        case .failed:
            accentColor = .systemRed
        case .partial, .recoveredPartial:
            accentColor = .systemOrange
        case .discarded:
            accentColor = .secondaryLabelColor
        case .preparing, .capturing, .finalizing:
            accentColor = .systemBlue
        }

        statusLabel = NSTextField(labelWithString: status.label)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = accentColor.withAlphaComponent(0.13).cgColor
        layer?.borderColor = accentColor.withAlphaComponent(0.24).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 8

        statusLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        statusLabel.textColor = accentColor
        statusLabel.alignment = .center
        addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: statusLabel.intrinsicContentSize.width + 12, height: 17)
    }
}

private final class QuickAccessIconButton: NSButton {
    private let actionBlock: () -> Void

    init(symbol: String, toolTip: String, action: @escaping () -> Void) {
        actionBlock = action
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .regularSquare
        controlSize = .small
        contentTintColor = .secondaryLabelColor
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        focusRingType = .none
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 10
        target = self
        self.action = #selector(pressed)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed() {
        actionBlock()
    }
}

private final class QuickAccessButtonContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class QuickAccessActionButton: NSButton {
    private let actionBlock: () -> Void
    private let isPrimary: Bool
    private var iconView: NSImageView?
    private var labelView: NSTextField?

    override var allowsVibrancy: Bool { false }
    override var isEnabled: Bool { didSet { applyVisualState() } }
    override var isHighlighted: Bool { didSet { applyVisualState() } }

    init(title: String, symbol: String, isPrimary: Bool, action: @escaping () -> Void) {
        actionBlock = action
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        self.title = title
        toolTip = title
        setAccessibilityLabel(title)
        focusRingType = .exterior
        let content = QuickAccessButtonContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.setAccessibilityElement(false)
        iconView = icon
        labelView = label
        [icon, label].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: 16)
        ])
        target = self
        self.action = #selector(pressed)
        applyVisualState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {}
    override func updateLayer() { super.updateLayer(); applyVisualState() }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    private func applyVisualState() {
        let background = isPrimary && isEnabled
            ? NSColor(srgbRed: 0.12, green: 0.32, blue: 0.68, alpha: 1) : NSColor.white
        let foreground: NSColor = isEnabled ? (isPrimary ? .white : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
            : NSColor(srgbRed: 0.48, green: 0.48, blue: 0.5, alpha: 1)
        layer?.backgroundColor = (isHighlighted && isEnabled
            ? background.blended(withFraction: 0.12, of: .black) ?? background : background).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(isEnabled ? 0.18 : 0.09).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 6
        iconView?.contentTintColor = foreground
        labelView?.textColor = foreground
    }

    @objc private func pressed() { guard isEnabled else { return }; actionBlock() }
}
