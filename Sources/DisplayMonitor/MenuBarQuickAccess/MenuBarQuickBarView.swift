import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Side-effect-free sizing rules shared by the quick-bar content and panel.
/// Snapshot dimensions are AppKit points from the real status item, so they
/// stay at 1:1 unless an unusually large item must be reduced to fit.
enum MenuBarQuickBarLayoutPolicy {
    struct ItemMetrics: Equatable {
        let iconSize: CGSize
        let itemWidth: CGFloat
    }

    static let panelHeight: CGFloat = 40
    static let itemHeight: CGFloat = 32
    static let fallbackIconSize = CGSize(width: 22, height: 22)
    static let minimumItemWidth: CGFloat = 24
    static let maximumSnapshotWidth: CGFloat = 180
    static let maximumSnapshotHeight: CGFloat = 28
    static let itemHorizontalInset: CGFloat = 8
    static let itemSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 6
    static let maximumVisibleItemCount = 8
    static let emptyPanelWidth: CGFloat = 220
    static let searchButtonWidth: CGFloat = 28
    static let searchFieldWidth: CGFloat = 168
    static let searchControlsWidth: CGFloat = 194
    static let reorderDraftControlsWidth: CGFloat = 112

    static func itemMetrics(snapshotPointSize: CGSize?) -> ItemMetrics {
        guard let snapshotPointSize,
              snapshotPointSize.width.isFinite,
              snapshotPointSize.height.isFinite,
              snapshotPointSize.width > 0,
              snapshotPointSize.height > 0 else {
            return ItemMetrics(
                iconSize: fallbackIconSize,
                itemWidth: max(
                    minimumItemWidth,
                    fallbackIconSize.width + itemHorizontalInset
                )
            )
        }

        let scale = min(
            1,
            maximumSnapshotWidth / snapshotPointSize.width,
            maximumSnapshotHeight / snapshotPointSize.height
        )
        let iconSize = CGSize(
            width: snapshotPointSize.width * scale,
            height: snapshotPointSize.height * scale
        )
        return ItemMetrics(
            iconSize: iconSize,
            itemWidth: max(minimumItemWidth, iconSize.width + itemHorizontalInset)
        )
    }

    static func panelWidth(
        snapshotPointSizes: [CGSize?],
        maximumWidth: CGFloat,
        isSearchVisible: Bool = false,
        hasReorderDraft: Bool = false
    ) -> CGFloat {
        let safeMaximum = max(1, maximumWidth)
        guard !snapshotPointSizes.isEmpty else {
            return min(emptyPanelWidth, safeMaximum)
        }
        let visibleMetrics = snapshotPointSizes
            .prefix(maximumVisibleItemCount)
            .map { itemMetrics(snapshotPointSize: $0) }
        let gaps = CGFloat(max(0, visibleMetrics.count - 1)) * itemSpacing
        let itemsWidth = visibleMetrics.reduce(CGFloat.zero) { partial, metrics in
            partial + metrics.itemWidth
        } + gaps
        let leadingControlsWidth = isSearchVisible
            ? searchControlsWidth
            : searchButtonWidth
        let draftControlsWidth = hasReorderDraft
            ? itemSpacing + reorderDraftControlsWidth
            : 0
        let naturalWidth = itemsWidth
            + leadingControlsWidth
            + itemSpacing
            + draftControlsWidth
            + horizontalPadding * 2
        return min(naturalWidth, safeMaximum)
    }
}

@MainActor
final class MenuBarQuickBarModel: ObservableObject {
    @Published private(set) var items: [MenuBarQuickBarItem] = []
    @Published private(set) var isSearchVisible = false
    @Published private(set) var searchQuery = ""
    @Published private(set) var selectedItemID: String?
    @Published private(set) var originalItemIDs: [String] = []

    var onPresentationChanged: (() -> Void)?
    var onDismissRequested: (() -> Void)?
    var onReorder: (([String]) -> Void)?
    var onApplyReorder: (([String]) -> Void)?
    var onCancelReorder: (() -> Void)?

    private var onSelect: (MenuBarQuickBarItem) -> Void = { _ in }
    private var reorderBaselineIDs: [String]?
    private var activeDragToken: String?

    var visibleItems: [MenuBarQuickBarItem] {
        guard isSearchVisible else { return items }
        return MenuBarQuickBarSearchPolicy.filteredItems(items, query: searchQuery)
    }

    var hasReorderDraft: Bool {
        guard let reorderBaselineIDs else { return false }
        return reorderBaselineIDs != items.map(\.id)
    }

    var isChangeOnlyPresentation: Bool {
        !items.isEmpty && items.allSatisfy(\.isChangeProxy)
    }

    func update(
        items incomingItems: [MenuBarQuickBarItem],
        onSelect: @escaping (MenuBarQuickBarItem) -> Void
    ) {
        let incomingIDs = incomingItems.map(\.id)
        let currentIDs = items.map(\.id)
        if hasReorderDraft,
           incomingIDs.count == currentIDs.count,
           Set(incomingIDs) == Set(currentIDs) {
            let incomingByID = Dictionary(uniqueKeysWithValues: incomingItems.map { ($0.id, $0) })
            items = currentIDs.compactMap { incomingByID[$0] }
        } else {
            items = incomingItems
            originalItemIDs = incomingIDs
            reorderBaselineIDs = nil
        }
        self.onSelect = onSelect
        repairSelection()
    }

    func select(_ item: MenuBarQuickBarItem) {
        selectedItemID = item.id
        onSelect(item)
    }

    func openSearch() {
        guard !isSearchVisible else { return }
        isSearchVisible = true
        selectedItemID = visibleItems.first?.id
        onPresentationChanged?()
    }

    func closeSearch() {
        guard isSearchVisible else { return }
        isSearchVisible = false
        searchQuery = ""
        selectedItemID = nil
        onPresentationChanged?()
    }

    func setSearchQuery(_ query: String) {
        guard isSearchVisible else { return }
        searchQuery = query
        repairSelection()
    }

    /// Returns true when the key belongs to the quick bar and must not reach
    /// the app underneath it. Arrow keys are scoped to explicit search only.
    @discardableResult
    func handleKeyDown(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 53: // Escape
            if isSearchVisible {
                closeSearch()
            } else {
                onDismissRequested?()
            }
            return true
        case 125 where isSearchVisible: // Down arrow
            moveSelection(by: 1)
            return true
        case 126 where isSearchVisible: // Up arrow
            moveSelection(by: -1)
            return true
        case 36, 76: // Return / keypad Enter
            guard isSearchVisible else { return false }
            activateSelection()
            return true
        default:
            return false
        }
    }

    func beginDragging(itemID: String) -> String? {
        guard !isSearchVisible,
              items.contains(where: { $0.id == itemID && $0.isReorderable }) else {
            return nil
        }
        let token = MenuBarQuickBarDragToken.make(itemID: itemID)
        activeDragToken = token
        return token
    }

    @discardableResult
    func acceptDrop(
        token: String,
        relativeTo destinationID: String,
        placement: MenuBarQuickBarDropPlacement
    ) -> Bool {
        defer { activeDragToken = nil }
        let reorderableIDs = Set(items.lazy.filter(\.isReorderable).map(\.id))
        guard !isSearchVisible,
              token == activeDragToken,
              let sourceID = MenuBarQuickBarDragToken.itemID(from: token),
              let reorderedIDs = MenuBarQuickBarReorderPolicy.moving(
                itemID: sourceID,
                relativeTo: destinationID,
                placement: placement,
                in: items.map(\.id),
                reorderableItemIDs: reorderableIDs
              ) else {
            return false
        }

        let originalIDs = items.map(\.id)
        if reorderBaselineIDs == nil {
            reorderBaselineIDs = originalIDs
            originalItemIDs = originalIDs
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = reorderedIDs.compactMap { itemsByID[$0] }
        if reorderedIDs == reorderBaselineIDs {
            reorderBaselineIDs = nil
        }
        selectedItemID = sourceID
        onReorder?(reorderedIDs)
        onPresentationChanged?()
        return true
    }

    func applyReorderDraft() {
        guard hasReorderDraft else { return }
        let order = items.map(\.id)
        objectWillChange.send()
        reorderBaselineIDs = nil
        onApplyReorder?(order)
        onPresentationChanged?()
    }

    func cancelReorderDraft() {
        guard let reorderBaselineIDs, hasReorderDraft else { return }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = reorderBaselineIDs.compactMap { itemsByID[$0] }
        self.reorderBaselineIDs = nil
        onCancelReorder?()
        onPresentationChanged?()
    }

    /// Ends one panel presentation. In particular, this invalidates a drag
    /// provider that may finish loading after the panel has already closed.
    func resetPresentation() {
        activeDragToken = nil
        let hadSearch = isSearchVisible
        let hadDraft = hasReorderDraft

        if let reorderBaselineIDs, hadDraft {
            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            items = reorderBaselineIDs.compactMap { itemsByID[$0] }
            onCancelReorder?()
        }
        reorderBaselineIDs = nil
        isSearchVisible = false
        searchQuery = ""
        selectedItemID = nil

        if hadSearch || hadDraft {
            onPresentationChanged?()
        }
    }

    private func moveSelection(by offset: Int) {
        let candidates = visibleItems
        guard !candidates.isEmpty else {
            selectedItemID = nil
            return
        }
        guard let selectedItemID,
              let currentIndex = candidates.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = candidates.first?.id
            return
        }
        let nextIndex = (currentIndex + offset + candidates.count) % candidates.count
        self.selectedItemID = candidates[nextIndex].id
    }

    private func activateSelection() {
        guard let selectedItemID,
              let item = visibleItems.first(where: { $0.id == selectedItemID }) else {
            return
        }
        select(item)
    }

    private func repairSelection() {
        let candidates = visibleItems
        if let selectedItemID,
           candidates.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = isSearchVisible ? candidates.first?.id : nil
    }
}

struct MenuBarQuickBarView: View {
    @ObservedObject var model: MenuBarQuickBarModel

    var body: some View {
        Group {
            if model.items.isEmpty {
                Text("没有可显示的隐藏图标")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                HStack(spacing: MenuBarQuickBarLayoutPolicy.itemSpacing) {
                    leadingSearchControl
                    itemStrip
                        .layoutPriority(1)
                    if model.hasReorderDraft {
                        reorderDraftControls
                    }
                }
                .padding(.horizontal, MenuBarQuickBarLayoutPolicy.horizontalPadding)
                .padding(.vertical, 4)
            }
        }
        .frame(height: MenuBarQuickBarLayoutPolicy.panelHeight)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onExitCommand {
            _ = model.handleKeyDown(keyCode: 53)
        }
    }

    @ViewBuilder
    private var leadingSearchControl: some View {
        if model.isChangeOnlyPresentation {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .frame(
                    width: MenuBarQuickBarLayoutPolicy.searchButtonWidth,
                    height: 28
                )
                .help("本次变化项目的代理层；原有隐藏项目仍保持隐藏")
                .accessibilityLabel("本次变化项目代理层")
        } else if model.isSearchVisible {
            HStack(spacing: 2) {
                MenuBarQuickBarSearchField(
                    text: Binding(
                        get: { model.searchQuery },
                        set: { model.setSearchQuery($0) }
                    ),
                    onMoveSelection: { offset in
                        _ = model.handleKeyDown(keyCode: offset < 0 ? 126 : 125)
                    },
                    onActivate: {
                        _ = model.handleKeyDown(keyCode: 36)
                    },
                    onEscape: {
                        _ = model.handleKeyDown(keyCode: 53)
                    }
                )
                .frame(
                    width: MenuBarQuickBarLayoutPolicy.searchFieldWidth,
                    height: 24
                )

                Button {
                    model.closeSearch()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("退出搜索")
                .accessibilityLabel("退出搜索")
            }
            .frame(width: MenuBarQuickBarLayoutPolicy.searchControlsWidth)
        } else {
            Button {
                model.openSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(
                        width: MenuBarQuickBarLayoutPolicy.searchButtonWidth,
                        height: 28
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索隐藏图标")
            .accessibilityLabel("搜索隐藏图标")
        }
    }

    private var itemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(
                alignment: .center,
                spacing: MenuBarQuickBarLayoutPolicy.itemSpacing
            ) {
                if model.visibleItems.isEmpty {
                    Text("无匹配图标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: MenuBarQuickBarLayoutPolicy.itemHeight)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(model.visibleItems) { item in
                        let metrics = MenuBarQuickBarLayoutPolicy.itemMetrics(
                            snapshotPointSize: item.iconSnapshot?.pointSize
                        )
                        MenuBarQuickBarItemButton(
                            item: item,
                            metrics: metrics,
                            isSelected: model.isSearchVisible
                                && model.selectedItemID == item.id,
                            allowsReorder: !model.isSearchVisible && item.isReorderable,
                            model: model
                        ) {
                            model.select(item)
                        }
                    }
                }
            }
        }
    }

    private var reorderDraftControls: some View {
        HStack(spacing: 2) {
            Divider()
                .frame(height: 20)
            Text("顺序草稿")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button {
                model.cancelReorderDraft()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .help("取消顺序草稿")
            .accessibilityLabel("取消顺序草稿")
            Button {
                model.applyReorderDraft()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 24)
                    .background(
                        Color.accentColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help("应用图标顺序")
            .accessibilityLabel("应用图标顺序")
        }
        .frame(width: MenuBarQuickBarLayoutPolicy.reorderDraftControlsWidth)
    }
}

private struct MenuBarQuickBarItemButton: View {
    let item: MenuBarQuickBarItem
    let metrics: MenuBarQuickBarLayoutPolicy.ItemMetrics
    let isSelected: Bool
    let allowsReorder: Bool
    @ObservedObject var model: MenuBarQuickBarModel
    let onSelect: () -> Void

    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if allowsReorder {
            button
                .onDrag {
                    dragProvider()
                }
                .onDrop(
                    of: [MenuBarQuickBarDropDelegate.contentType],
                    delegate: MenuBarQuickBarDropDelegate(
                        destinationID: item.id,
                        destinationWidth: metrics.itemWidth,
                        model: model
                    )
                )
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: onSelect) {
            quickBarIconWithChangeBadge
                .frame(
                    width: metrics.itemWidth,
                    height: MenuBarQuickBarLayoutPolicy.itemHeight
                )
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(isSelected ? "已选择" : "")
        .onHover { isHovered = $0 }
    }

    private var helpText: String {
        var lines = [item.accessibilityLabel]
        if item.isChangeProxy {
            lines.append("这是入口下方的变化代理，不代表顶部真实单项已安全放出。")
        }
        if let reason = item.activationBlockReason {
            lines.append(reason)
        } else if item.iconSnapshot == nil {
            lines.append("未取得原菜单栏图标，暂用应用图标；下次重新收起时刷新。")
        }
        return lines.joined(separator: "\n")
    }

    private var quickBarIconWithChangeBadge: some View {
        quickBarIcon
            .resizable()
            .scaledToFit()
            .frame(
                width: metrics.iconSize.width,
                height: metrics.iconSize.height
            )
            .overlay(alignment: .topTrailing) {
                if item.isChangeProxy {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
            }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        if isHovered { return Color.primary.opacity(0.10) }
        return Color.clear
    }

    private func dragProvider() -> NSItemProvider {
        guard let token = model.beginDragging(itemID: item.id) else {
            return NSItemProvider()
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: MenuBarQuickBarDragToken.typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(token.utf8), nil)
            return nil
        }
        return provider
    }

    private var quickBarIcon: Image {
        if let snapshot = item.iconSnapshot,
           let image = NSImage(data: snapshot.pngData) {
            if snapshot.pointSize.width > 0, snapshot.pointSize.height > 0 {
                image.size = snapshot.pointSize
            }
            return Image(nsImage: image)
        }
        let runningApplication = NSRunningApplication(
            processIdentifier: pid_t(item.processIdentifier)
        )
        if let image = runningApplication?.icon {
            return Image(nsImage: image)
        }
        return Image(systemName: "app.dashed")
    }
}

private struct MenuBarQuickBarDropDelegate: DropDelegate {
    static let contentType = UTType(
        importedAs: MenuBarQuickBarDragToken.typeIdentifier
    )

    let destinationID: String
    let destinationWidth: CGFloat
    let model: MenuBarQuickBarModel

    func validateDrop(info: DropInfo) -> Bool {
        !model.isSearchVisible
            && info.hasItemsConforming(to: [Self.contentType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !model.isSearchVisible,
              let provider = info.itemProviders(for: [Self.contentType]).first else {
            return false
        }
        let placement: MenuBarQuickBarDropPlacement = info.location.x
            < destinationWidth / 2 ? .before : .after
        provider.loadDataRepresentation(
            forTypeIdentifier: MenuBarQuickBarDragToken.typeIdentifier
        ) { data, _ in
            guard let data, let token = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                _ = model.acceptDrop(
                    token: token,
                    relativeTo: destinationID,
                    placement: placement
                )
            }
        }
        return true
    }
}

/// NSSearchField is the smallest AppKit bridge needed here: it gives the
/// nonactivating panel deterministic arrow/Return/Escape routing on macOS 13.
private struct MenuBarQuickBarSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMoveSelection: (Int) -> Void
    let onActivate: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> QuickBarSearchField {
        let field = QuickBarSearchField()
        field.placeholderString = "搜索应用或图标"
        field.controlSize = .small
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchTextChanged(_:))
        configure(field)
        Task { @MainActor [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: QuickBarSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        configure(field)
    }

    private func configure(_ field: QuickBarSearchField) {
        field.onMoveSelection = onMoveSelection
        field.onActivate = onActivate
        field.onEscape = onEscape
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MenuBarQuickBarSearchField

        init(parent: MenuBarQuickBarSearchField) {
            self.parent = parent
        }

        @objc func searchTextChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }
    }
}

private final class QuickBarSearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveSelection?(1)
        case 126:
            onMoveSelection?(-1)
        case 36, 76:
            onActivate?()
        case 53:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}
