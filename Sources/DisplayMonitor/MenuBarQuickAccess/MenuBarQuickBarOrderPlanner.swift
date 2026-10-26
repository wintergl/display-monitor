import Foundation

enum MenuBarQuickBarOrderError: LocalizedError {
    case staleCatalog
    case protectedItem
    case noChanges

    var errorDescription: String? {
        switch self {
        case .staleCatalog: return "图标条的项目或顺序已经变化，请重新打开后再排序。"
        case .protectedItem: return "系统项目的位置保持固定，请在它所在的区段内调整其他图标。"
        case .noChanges: return "当前没有需要应用的排序变化。"
        }
    }
}

enum MenuBarQuickBarOrderPlanner {
    /// Only the exact hidden slots are replaced. Protected items, the anchor,
    /// and the visible right-side items keep their original positions.
    static func desiredFullOrder(
        layout: AnchoredMenuBarLayout,
        originalQuickBarIDs: [String],
        proposedQuickBarIDs: [String],
        movableItemIDs: Set<String>
    ) throws -> [String] {
        let originals = Set(originalQuickBarIDs)
        guard !originalQuickBarIDs.isEmpty,
              originals.count == originalQuickBarIDs.count,
              proposedQuickBarIDs.count == originalQuickBarIDs.count,
              Set(proposedQuickBarIDs) == originals,
              layout.leftItems.filter({ originals.contains($0.id) }).map(\.id) == originalQuickBarIDs else {
            throw MenuBarQuickBarOrderError.staleCatalog
        }
        guard originalQuickBarIDs != proposedQuickBarIDs else { throw MenuBarQuickBarOrderError.noChanges }
        for (index, id) in originalQuickBarIDs.enumerated() where !movableItemIDs.contains(id) {
            guard proposedQuickBarIDs[index] == id else { throw MenuBarQuickBarOrderError.protectedItem }
        }
        // A system or visible item omitted from the quick bar is also a
        // boundary. Keeping its slot fixed alone would still let two hidden
        // icons cross over it, so validate against the complete real layout.
        var segment = 0
        var segmentByID: [String: Int] = [:]
        for item in layout.orderedItems {
            if originals.contains(item.id), movableItemIDs.contains(item.id) {
                segmentByID[item.id] = segment
            } else {
                segment += 1
            }
        }
        for (original, proposed) in zip(originalQuickBarIDs, proposedQuickBarIDs)
            where movableItemIDs.contains(original) {
            guard segmentByID[original] == segmentByID[proposed] else {
                throw MenuBarQuickBarOrderError.protectedItem
            }
        }
        var proposedIndex = 0
        return layout.orderedItems.map { item in
            guard originals.contains(item.id) else { return item.id }
            defer { proposedIndex += 1 }
            return proposedQuickBarIDs[proposedIndex]
        }
    }
}
