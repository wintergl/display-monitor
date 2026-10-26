import Foundation

enum MenuBarCollapsePlanError: LocalizedError, Equatable {
    case noTargets
    case targetIsNotRunning(String)
    case protectedTarget(String)
    case invalidControllerIdentity

    var errorDescription: String? {
        switch self {
        case .noTargets: "分界左侧没有可安全收起的第三方应用。"
        case .targetIsNotRunning(let bundleIdentifier):
            "目标应用已退出或身份发生变化：\(bundleIdentifier)。请重新读取。"
        case .protectedTarget(let bundleIdentifier):
            "该应用必须保持可见：\(bundleIdentifier)。"
        case .invalidControllerIdentity:
            "当前应用身份无效，已保持展开。"
        }
    }
}

/// Native visibility uses an allow-list. Constructing that list is deliberately
/// separate from the private bridge so it can be persisted before native work starts.
struct MenuBarCollapsePlan: Codable, Equatable, Sendable {
    let targetBundleIdentifiers: [String]
    let allowedBundleIdentifiers: [String]
    let allowedSystemItems: [Int]

    init(
        runningBundleIdentifiers: Set<String>,
        targetBundleIdentifiers: Set<String>,
        protectionPolicy: MenuBarTargetProtectionPolicy,
        requiredBundleIdentifiers: Set<String> = [
            "com.apple.MenuBarAgent",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
        ],
        allowedSystemItems: [Int] = Array(0...8)
    ) throws {
        let ownIdentifier = protectionPolicy.ownBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ownIdentifier.isEmpty else { throw MenuBarCollapsePlanError.invalidControllerIdentity }
        guard !targetBundleIdentifiers.isEmpty else { throw MenuBarCollapsePlanError.noTargets }

        for target in targetBundleIdentifiers.sorted() {
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  runningBundleIdentifiers.contains(target) else {
                throw MenuBarCollapsePlanError.targetIsNotRunning(target)
            }
            guard protectionPolicy.reason(bundleIdentifier: target, applicationName: nil) == nil else {
                throw MenuBarCollapsePlanError.protectedTarget(target)
            }
        }

        self.targetBundleIdentifiers = targetBundleIdentifiers.sorted()
        self.allowedBundleIdentifiers = runningBundleIdentifiers
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .union(requiredBundleIdentifiers)
            .union([ownIdentifier])
            .subtracting(targetBundleIdentifiers)
            .sorted()
        self.allowedSystemItems = allowedSystemItems
    }
}

struct PersistentMenuBarCollapseRecord: Codable, Equatable, Sendable {
    let savedAt: Date
    let topologyRevision: String
    let plan: MenuBarCollapsePlan
}

enum PersistentMenuBarCollapseJournal {
    static func save(_ record: PersistentMenuBarCollapseRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> PersistentMenuBarCollapseRecord {
        try JSONDecoder().decode(PersistentMenuBarCollapseRecord.self, from: Data(contentsOf: url))
    }

    static func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
