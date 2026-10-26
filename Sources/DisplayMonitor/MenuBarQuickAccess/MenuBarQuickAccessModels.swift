import CoreGraphics
import Foundation

enum MenuBarPrimaryPresentationMode: String, Codable, CaseIterable, Sendable {
    case nativeMenuBar
    case quickBar
}

struct MenuBarQuickBarItem: Identifiable, Equatable, Sendable {
    let id: String
    let bundleIdentifier: String
    let applicationName: String
    let itemTitle: String
    let processIdentifier: Int32
    let accessibilityIdentifier: String?
    let isReorderable: Bool
    /// Change-only presentations are a proxy layer below the menu bar. They do
    /// not claim that a single third-party status item was made visible above.
    let isChangeProxy: Bool
    /// Weak/ambiguous items remain visible as information, but selecting them
    /// must not release the entire hidden group or guess a real AX target.
    let activationBlockReason: String?
    /// A memory-only crop of the real status item immediately before it was
    /// hidden. PNG data keeps AppKit image objects out of the Sendable model.
    let iconSnapshot: MenuBarQuickBarIconSnapshot?

    init(
        id: String,
        bundleIdentifier: String,
        applicationName: String,
        itemTitle: String,
        processIdentifier: Int32,
        accessibilityIdentifier: String? = nil,
        iconSnapshot: MenuBarQuickBarIconSnapshot? = nil,
        isReorderable: Bool = true,
        isChangeProxy: Bool = false,
        activationBlockReason: String? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.itemTitle = itemTitle
        self.processIdentifier = processIdentifier
        self.accessibilityIdentifier = accessibilityIdentifier
        self.iconSnapshot = iconSnapshot
        self.isReorderable = isReorderable
        self.isChangeProxy = isChangeProxy
        self.activationBlockReason = activationBlockReason
    }

    var displayName: String {
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if bundleIdentifier.caseInsensitiveCompare(
            MenuBarTargetProtectionPolicy.textInputMenuAgentBundleIdentifier
        ) == .orderedSame, !title.isEmpty {
            return title
        }
        if !name.isEmpty { return name }
        return title.isEmpty ? bundleIdentifier : title
    }

    var accessibilityLabel: String {
        let title = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty || title == displayName
            ? displayName
            : "\(displayName)，\(title)"
        return isChangeProxy ? "状态变化代理，\(base)" : base
    }

    /// Change-only items are informational by contract. Fail closed even if a
    /// future construction path forgets to supply its own explanatory text.
    var selectionBlockReason: String? {
        if isChangeProxy {
            return activationBlockReason
                ?? "该项目是状态变化代理，不会释放整组隐藏图标；请单击入口显示全部后再操作。"
        }
        return activationBlockReason
    }
}

struct MenuBarQuickBarIconSnapshot: Equatable, Sendable {
    let pngData: Data
    let pointSize: CGSize
}

enum MenuBarQuickBarCatalog {
    static func makeItems(
        from menuBarItems: [MenuBarOrderItem],
        hiddenBundleIdentifiers: Set<String>,
        iconSnapshots: [String: MenuBarQuickBarIconSnapshot] = [:],
        movableItemIDs: Set<String>? = nil
    ) -> [MenuBarQuickBarItem] {
        menuBarItems.compactMap { item in
            guard hiddenBundleIdentifiers.contains(item.bundleIdentifier) else { return nil }
            return MenuBarQuickBarItem(
                id: item.id,
                bundleIdentifier: item.bundleIdentifier,
                applicationName: item.applicationName,
                itemTitle: item.title,
                processIdentifier: item.processIdentifier,
                accessibilityIdentifier: item.accessibilityIdentifier,
                iconSnapshot: iconSnapshots[item.id],
                isReorderable: movableItemIDs?.contains(item.id) ?? true
            )
        }
    }
}

/// Pure filtering rules for the explicit quick-bar search field. The source
/// array is filtered in place so matching never changes the menu-bar order.
enum MenuBarQuickBarSearchPolicy {
    static func filteredItems(
        _ items: [MenuBarQuickBarItem],
        query: String
    ) -> [MenuBarQuickBarItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }

        return items.filter { item in
            [item.applicationName, item.itemTitle, item.bundleIdentifier].contains { value in
                value.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                ) != nil
            }
        }
    }
}

enum MenuBarQuickBarDropPlacement: Equatable, Sendable {
    case before
    case after
}

/// Reorders only an already-complete identifier list. Callers can therefore
/// pass the result through protection and screen checks before applying it to
/// the real menu bar.
enum MenuBarQuickBarReorderPolicy {
    static func moving(
        itemID: String,
        relativeTo destinationID: String,
        placement: MenuBarQuickBarDropPlacement,
        in itemIDs: [String],
        reorderableItemIDs: Set<String>? = nil
    ) -> [String]? {
        let reorderableItemIDs = reorderableItemIDs ?? Set(itemIDs)
        guard itemIDs.count == Set(itemIDs).count,
              itemID != destinationID,
              reorderableItemIDs.contains(itemID),
              reorderableItemIDs.isSubset(of: Set(itemIDs)),
              itemIDs.contains(itemID),
              itemIDs.contains(destinationID) else {
            return nil
        }

        var reordered = itemIDs
        reordered.removeAll { $0 == itemID }
        guard let destinationIndex = reordered.firstIndex(of: destinationID) else {
            return nil
        }
        let insertionIndex = placement == .before
            ? destinationIndex
            : reordered.index(after: destinationIndex)
        reordered.insert(itemID, at: insertionIndex)
        guard reordered != itemIDs else { return nil }

        // Protected entries are fixed slots. A movable item may be reordered
        // only inside the segment bounded by those slots.
        for (index, originalID) in itemIDs.enumerated()
        where !reorderableItemIDs.contains(originalID) {
            guard reordered[index] == originalID else { return nil }
        }
        return reordered
    }
}

/// The drag payload is accepted only inside this process launch. The view also
/// registers its item provider with `.ownProcess`, so an unrelated app cannot
/// construct a reorder request for the quick bar.
enum MenuBarQuickBarDragToken {
    static let typeIdentifier = "com.hanshuai.displaymonitor.quick-bar-item"
    private static let processNonce = UUID().uuidString

    static func make(itemID: String) -> String {
        let encodedID = Data(itemID.utf8).base64EncodedString()
        return "\(processNonce):\(encodedID)"
    }

    static func itemID(from token: String) -> String? {
        let components = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == Substring(processNonce),
              let data = Data(base64Encoded: String(components[1])),
              let itemID = String(data: data, encoding: .utf8),
              !itemID.isEmpty else {
            return nil
        }
        return itemID
    }
}

enum MenuBarStatusItemPointerButton: Equatable, Sendable {
    case primary
    case secondary
}

enum MenuBarStatusItemAction: Equatable, Sendable {
    case revealNativeMenuBar
    case presentQuickBar
    case dismissQuickBar
    case presentContextMenu
}

enum MenuBarStatusItemActionRouter {
    static func action(
        for button: MenuBarStatusItemPointerButton,
        presentationMode: MenuBarPrimaryPresentationMode,
        quickBarIsVisible: Bool
    ) -> MenuBarStatusItemAction {
        switch button {
        case .secondary:
            return .presentContextMenu
        case .primary:
            switch presentationMode {
            case .nativeMenuBar:
                return .revealNativeMenuBar
            case .quickBar:
                return quickBarIsVisible ? .dismissQuickBar : .presentQuickBar
            }
        }
    }
}
