import Combine
import DisplayMonitorCore
import OSLog

struct SafeVisibilityInventoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let classification: ShelfItemClassification
    let detail: String
}

@MainActor
final class ShelfSafeVisibilityController: ObservableObject {
    @Published private(set) var state: ShelfState = .safeVisibility(.shelfNoGo)
    @Published private(set) var lastActionMessage: String?

    let policy = ShelfSafeVisibilityPolicy()
    let inventory: [SafeVisibilityInventoryItem] = ShelfSpikeFixtureCatalog.fixtures.map {
        SafeVisibilityInventoryItem(
            id: $0.id,
            title: $0.id,
            classification: $0.expectedClassification,
            detail: $0.shape
        )
    }

    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ShelfSafeVisibility")

    func restoreAllReadOnly() {
        state = .safeVisibility(.shelfNoGo)
        lastActionMessage = "恢复入口可用，但 Shelf No-Go 下不执行第三方移动、隐藏或 Always Hidden"
        logger.info("shelf.restore.readOnly noWrite=true")
    }
}
