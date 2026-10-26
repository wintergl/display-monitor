import CoreGraphics
import Foundation

struct RunningAppSnapshot: Sendable {
    let bundleIdentifier: String
    let name: String
    let processIdentifier: Int32
}

/// Every exclusion is supplied by the owning app. This keeps the low-level menu-bar
/// implementation independent from prototype identities and product UI state.
struct MenuBarTargetProtectionPolicy: Sendable {
    static let textInputMenuAgentBundleIdentifier = "com.apple.TextInputMenuAgent"

    let ownBundleIdentifier: String
    let protectedBundleIdentifiers: Set<String>
    private let collapsibleSystemBundleIdentifiers: Set<String>
    private let additionalReason: @Sendable (_ bundleIdentifier: String, _ applicationName: String?) -> String?

    init(
        ownBundleIdentifier: String,
        protectedBundleIdentifiers: Set<String> = [],
        collapsibleSystemBundleIdentifiers: Set<String> = [],
        additionalReason: @escaping @Sendable (String, String?) -> String? = { _, _ in nil }
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
        self.collapsibleSystemBundleIdentifiers = Set(
            collapsibleSystemBundleIdentifiers.map { $0.lowercased() }
        )
        self.additionalReason = additionalReason
    }

    func reason(bundleIdentifier: String, applicationName: String? = nil) -> String? {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedIdentifier = identifier.lowercased()
        let own = ownBundleIdentifier.lowercased()
        if lowercasedIdentifier == own || lowercasedIdentifier.hasPrefix(own + ".") {
            return "保留 Display Monitor 的展开入口"
        }
        if lowercasedIdentifier.hasPrefix("com.apple."),
           !collapsibleSystemBundleIdentifiers.contains(lowercasedIdentifier) {
            return "系统项目保持可见"
        }
        if protectedBundleIdentifiers.contains(identifier) {
            return "该应用已由产品策略设为保持可见"
        }
        if Self.isKnownManager(bundleIdentifier: identifier, name: applicationName) {
            return "请先自行退出其他菜单栏管理器"
        }
        return additionalReason(identifier, applicationName)
    }

    static func isKnownManager(bundleIdentifier: String?, name: String?) -> Bool {
        let knownNames: Set<String> = [
            "bartender", "ice", "thaw", "dimble", "pelmet", "tuck", "hiddenbar",
            "dozer", "vanilla", "barbee", "icemelt",
        ]
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func isKnownName(_ value: String) -> Bool {
            if knownNames.contains(value) { return true }
            guard value.hasPrefix("bartender") else { return false }
            let version = value.dropFirst("bartender".count)
            return !version.isEmpty && version.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
        if let name {
            let withoutExtension = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
            if isKnownName(normalized(withoutExtension)) { return true }
        }
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.split(separator: ".").contains {
            isKnownName(normalized(String($0)))
        }
    }
}

struct MenuBarOrderItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bundleIdentifier: String
    let applicationName: String
    let title: String
    let accessibilityIdentifier: String?
    let processIdentifier: Int32
    let displayID: UInt32
    let frame: CGRect

    init(
        id: String,
        bundleIdentifier: String,
        applicationName: String,
        title: String,
        accessibilityIdentifier: String? = nil,
        processIdentifier: Int32,
        displayID: UInt32,
        frame: CGRect
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.processIdentifier = processIdentifier
        self.displayID = displayID
        self.frame = frame
    }
}

struct MenuBarInventoryCoverage: Codable, Equatable, Sendable {
    let expectedDisplayIDs: [UInt32]
    let observedCandidateCount: Int
    let resolvedItemCount: Int
    let unknownOwnershipCount: Int
    let ambiguousIdentityCount: Int
    let unexplainedSkippedItemCount: Int
    let unreadableDisplayIDs: [UInt32]
    let didTimeOut: Bool

    init(
        expectedDisplayIDs: [UInt32],
        observedCandidateCount: Int,
        resolvedItemCount: Int,
        unknownOwnershipCount: Int = 0,
        ambiguousIdentityCount: Int = 0,
        unexplainedSkippedItemCount: Int = 0,
        unreadableDisplayIDs: [UInt32] = [],
        didTimeOut: Bool = false
    ) {
        self.expectedDisplayIDs = expectedDisplayIDs
        self.observedCandidateCount = observedCandidateCount
        self.resolvedItemCount = resolvedItemCount
        self.unknownOwnershipCount = unknownOwnershipCount
        self.ambiguousIdentityCount = ambiguousIdentityCount
        self.unexplainedSkippedItemCount = unexplainedSkippedItemCount
        self.unreadableDisplayIDs = unreadableDisplayIDs
        self.didTimeOut = didTimeOut
    }

    var isComplete: Bool {
        let displayIDs = Set(expectedDisplayIDs)
        return !displayIDs.isEmpty
            && displayIDs.count == expectedDisplayIDs.count
            && observedCandidateCount >= 0
            && resolvedItemCount >= 0
            && observedCandidateCount == resolvedItemCount
            && unknownOwnershipCount == 0
            && ambiguousIdentityCount == 0
            && unexplainedSkippedItemCount == 0
            && unreadableDisplayIDs.isEmpty
            && !didTimeOut
    }
}

struct MenuBarAnchorIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let title: String
    let accessibilityIdentifier: String?

    init(bundleIdentifier: String, title: String, accessibilityIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func matches(_ item: MenuBarOrderItem) -> Bool {
        guard item.bundleIdentifier == bundleIdentifier else { return false }
        if let accessibilityIdentifier,
           item.accessibilityIdentifier == accessibilityIdentifier {
            return true
        }
        if item.title == title { return true }
        return false
    }
}

enum MenuBarBundlePlacement: String, Codable, Equatable, Sendable {
    case left
    case right
    case crossBoundary
}

struct AnchoredMenuBarLayout: Codable, Equatable, Sendable {
    let displayID: UInt32
    let leftItems: [MenuBarOrderItem]
    let anchor: MenuBarOrderItem
    let rightItems: [MenuBarOrderItem]

    var orderedItems: [MenuBarOrderItem] { leftItems + [anchor] + rightItems }
    var leftIDs: [String] { leftItems.map(\.id) }
    var anchorID: String { anchor.id }
    var rightIDs: [String] { rightItems.map(\.id) }
}

enum AnchoredMenuBarValidationError: LocalizedError, Equatable {
    case incompleteCoverage
    case invalidCoverageCounts
    case duplicateDisplayIdentifiers
    case unexpectedDisplay(UInt32)
    case duplicateItemIdentifiers
    case invalidIdentity(String)
    case invalidGeometry(String)
    case missingAnchor(UInt32)
    case multipleAnchors(UInt32)
    case crossBoundaryBundles([String])
    case invalidDesiredOrder

    var errorDescription: String? {
        switch self {
        case .incompleteCoverage: "菜单栏读取不完整，已保持展开。"
        case .invalidCoverageCounts: "菜单栏覆盖统计与读取结果不一致。"
        case .duplicateDisplayIdentifiers: "显示器身份有重复，无法确认菜单栏布局。"
        case .unexpectedDisplay(let displayID): "读取到了未声明的显示器：\(displayID)。"
        case .duplicateItemIdentifiers: "图标身份有重复，请重新读取。"
        case .invalidIdentity(let title): "无法确认图标身份：\(title)。"
        case .invalidGeometry(let title): "无法确认图标位置：\(title)。"
        case .missingAnchor(let displayID): "显示器 \(displayID) 上没有找到固定分界。"
        case .multipleAnchors(let displayID): "显示器 \(displayID) 上找到了多个固定分界。"
        case .crossBoundaryBundles(let bundles): "这些应用的图标分布在分界两侧：\(bundles.joined(separator: ", "))。"
        case .invalidDesiredOrder: "目标排序与当前菜单栏不一致，请重新读取。"
        }
    }
}

struct AnchoredMenuBarInventory: Codable, Equatable, Sendable {
    let items: [MenuBarOrderItem]
    let coverage: MenuBarInventoryCoverage
    let anchorIdentity: MenuBarAnchorIdentity

    func validatedLayouts() throws -> [AnchoredMenuBarLayout] {
        guard coverage.observedCandidateCount >= 0,
              coverage.resolvedItemCount >= 0,
              coverage.unknownOwnershipCount >= 0,
              coverage.ambiguousIdentityCount >= 0,
              coverage.unexplainedSkippedItemCount >= 0,
              coverage.resolvedItemCount == items.count else {
            throw AnchoredMenuBarValidationError.invalidCoverageCounts
        }
        guard coverage.isComplete else { throw AnchoredMenuBarValidationError.incompleteCoverage }
        let expectedDisplays = Set(coverage.expectedDisplayIDs)
        guard expectedDisplays.count == coverage.expectedDisplayIDs.count else {
            throw AnchoredMenuBarValidationError.duplicateDisplayIdentifiers
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw AnchoredMenuBarValidationError.duplicateItemIdentifiers
        }
        for item in items {
            guard expectedDisplays.contains(item.displayID) else {
                throw AnchoredMenuBarValidationError.unexpectedDisplay(item.displayID)
            }
            try validateMenuBarItem(item)
        }
        return try coverage.expectedDisplayIDs.sorted().map { displayID in
            let displayItems = items.filter { $0.displayID == displayID }.sorted(by: menuBarItemOrder)
            let anchors = displayItems.filter(anchorIdentity.matches)
            guard !anchors.isEmpty else { throw AnchoredMenuBarValidationError.missingAnchor(displayID) }
            guard anchors.count == 1, let anchor = anchors.first else {
                throw AnchoredMenuBarValidationError.multipleAnchors(displayID)
            }
            guard let anchorIndex = displayItems.firstIndex(where: { $0.id == anchor.id }) else {
                throw AnchoredMenuBarValidationError.missingAnchor(displayID)
            }
            return AnchoredMenuBarLayout(
                displayID: displayID,
                leftItems: Array(displayItems[..<anchorIndex]),
                anchor: anchor,
                rightItems: Array(displayItems[displayItems.index(after: anchorIndex)...])
            )
        }
    }

    func bundlePlacements(protectionPolicy: MenuBarTargetProtectionPolicy) throws -> [String: MenuBarBundlePlacement] {
        var sides: [String: Set<MenuBarBundlePlacement>] = [:]
        for layout in try validatedLayouts() {
            for item in layout.leftItems where protectionPolicy.reason(
                bundleIdentifier: item.bundleIdentifier,
                applicationName: item.applicationName
            ) == nil {
                sides[item.bundleIdentifier, default: []].insert(.left)
            }
            for item in layout.rightItems where protectionPolicy.reason(
                bundleIdentifier: item.bundleIdentifier,
                applicationName: item.applicationName
            ) == nil {
                sides[item.bundleIdentifier, default: []].insert(.right)
            }
        }
        return sides.mapValues { $0.count == 1 ? $0.first! : .crossBoundary }
    }

    func collapseTargetBundleIdentifiers(protectionPolicy: MenuBarTargetProtectionPolicy) throws -> [String] {
        let placements = try bundlePlacements(protectionPolicy: protectionPolicy)
        let conflicts = placements.filter { $0.value == .crossBoundary }.map(\.key).sorted()
        guard conflicts.isEmpty else { throw AnchoredMenuBarValidationError.crossBoundaryBundles(conflicts) }
        return placements.filter { $0.value == .left }.map(\.key).sorted()
    }
}

enum AnchoredMenuBarMovePlacement: String, Codable, Equatable, Sendable {
    case before
    case after
}

struct AnchoredMenuBarMove: Codable, Equatable, Sendable {
    let itemID: String
    let referenceItemID: String
    let placement: AnchoredMenuBarMovePlacement
}

enum AnchoredMenuBarDropGeometry {
    static func destination(relativeTo referenceFrame: CGRect, placement: AnchoredMenuBarMovePlacement) throws -> CGPoint {
        guard referenceFrame.origin.x.isFinite, referenceFrame.origin.y.isFinite,
              referenceFrame.width.isFinite, referenceFrame.height.isFinite,
              referenceFrame.width > 0, referenceFrame.height > 0 else {
            throw AnchoredMenuBarValidationError.invalidGeometry("拖动参照项")
        }
        let edgeInset = min(1, referenceFrame.width / 4)
        return CGPoint(
            x: placement == .before ? referenceFrame.minX + edgeInset : referenceFrame.maxX - edgeInset,
            y: referenceFrame.midY
        )
    }
}

enum AnchoredMenuBarPlanner {
    /// Replans exactly one move from a fresh inventory. The anchor and protected
    /// items may be references but can never be emitted as drag sources.
    static func nextMove(
        current: [MenuBarOrderItem],
        desiredIDs: [String],
        anchorID: String,
        movableItemIDs: Set<String>
    ) throws -> AnchoredMenuBarMove? {
        guard current.count >= 2,
              Set(current.map(\.id)).count == current.count,
              Set(desiredIDs).count == desiredIDs.count,
              Set(current.map(\.id)) == Set(desiredIDs),
              desiredIDs.count == current.count,
              current.contains(where: { $0.id == anchorID }),
              desiredIDs.filter({ $0 == anchorID }).count == 1,
              Set(current.map(\.displayID)).count == 1,
              !movableItemIDs.contains(anchorID),
              movableItemIDs.isSubset(of: Set(current.map(\.id))) else {
            throw AnchoredMenuBarValidationError.invalidDesiredOrder
        }
        try current.forEach(validateMenuBarItem)
        let actualIDs = current.sorted(by: menuBarItemOrder).map(\.id)
        guard actualIDs != desiredIDs else { return nil }
        for itemID in actualIDs where movableItemIDs.contains(itemID) {
            guard let actualIndex = actualIDs.firstIndex(of: itemID),
                  let desiredIndex = desiredIDs.firstIndex(of: itemID),
                  actualIndex != desiredIndex else { continue }
            let referenceID = actualIDs[desiredIndex]
            guard referenceID != itemID else { continue }
            return AnchoredMenuBarMove(
                itemID: itemID,
                referenceItemID: referenceID,
                placement: desiredIndex < actualIndex ? .before : .after
            )
        }
        throw AnchoredMenuBarValidationError.invalidDesiredOrder
    }
}

struct MenuBarOrderRecovery: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operationID: UUID
    let savedAt: Date
    let displayID: UInt32
    let anchorIdentity: MenuBarAnchorIdentity
    let originalItems: [MenuBarOrderItem]
    let desiredItemIDs: [String]

    init(
        operationID: UUID = UUID(),
        savedAt: Date,
        displayID: UInt32,
        anchorIdentity: MenuBarAnchorIdentity,
        originalItems: [MenuBarOrderItem],
        desiredItemIDs: [String]
    ) {
        schemaVersion = 1
        self.operationID = operationID
        self.savedAt = savedAt
        self.displayID = displayID
        self.anchorIdentity = anchorIdentity
        self.originalItems = originalItems
        self.desiredItemIDs = desiredItemIDs
    }

    var originalItemIDs: [String] { originalItems.map(\.id) }
}

enum MenuBarOrderJournal {
    static func save(_ recovery: MenuBarOrderRecovery, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recovery).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> MenuBarOrderRecovery {
        let recovery = try JSONDecoder().decode(
            MenuBarOrderRecovery.self,
            from: Data(contentsOf: url)
        )
        guard recovery.schemaVersion == 1 else {
            throw MenuBarOrderJournalError.unsupportedSchema(recovery.schemaVersion)
        }
        return recovery
    }

    static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum MenuBarOrderJournalError: LocalizedError, Equatable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "不支持的菜单栏恢复记录版本：\(version)。"
        }
    }
}

private func menuBarItemOrder(_ lhs: MenuBarOrderItem, _ rhs: MenuBarOrderItem) -> Bool {
    if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
    return lhs.id < rhs.id
}

private func validateMenuBarItem(_ item: MenuBarOrderItem) throws {
    guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !item.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          item.processIdentifier > 0,
          item.displayID != 0 else {
        throw AnchoredMenuBarValidationError.invalidIdentity(item.title)
    }
    let frame = item.frame
    guard frame.origin.x.isFinite, frame.origin.y.isFinite,
          frame.size.width.isFinite, frame.size.height.isFinite,
          frame.size.width > 0, frame.size.height > 0 else {
        throw AnchoredMenuBarValidationError.invalidGeometry(item.title)
    }
}
