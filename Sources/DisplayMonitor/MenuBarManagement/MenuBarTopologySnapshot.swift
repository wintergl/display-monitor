import Foundation

/// Value-only identity for one running process that can own menu-bar items.
/// Processes with no confirmed status item may appear in `runningProviders`, but
/// they do not contribute to a topology change on their own.
struct MenuBarTopologyProvider: Hashable, Sendable {
    let bundleIdentifier: String
    let applicationName: String
    let processIdentifier: Int32

    var instanceKey: String {
        Self.join([
            String(processIdentifier),
            bundleIdentifier,
        ])
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum MenuBarTopologyIdentityStrength: String, Sendable {
    case strong
    case weak
}

/// One provider-owned AX menu-bar item. Title, description, and value are
/// deliberately content, never identity. An AX identifier is strong identity;
/// the structural path is only a conservative, process-local fallback.
struct MenuBarTopologyItemSnapshot: Equatable, Sendable {
    let provider: MenuBarTopologyProvider
    let identityKey: String
    /// Process-local tree position retained even when an AX identifier exists.
    /// It is only used as a conservative fallback when a provider publishes the
    /// same identifier for more than one physical status item.
    let structuralIdentityKey: String
    let identityStrength: MenuBarTopologyIdentityStrength
    let accessibilityIdentifier: String?
    let title: String?
    let itemDescription: String?
    let value: String?

    init(
        provider: MenuBarTopologyProvider,
        identityKey: String,
        structuralIdentityKey: String? = nil,
        identityStrength: MenuBarTopologyIdentityStrength,
        accessibilityIdentifier: String?,
        title: String?,
        itemDescription: String?,
        value: String?
    ) {
        self.provider = provider
        self.identityKey = identityKey
        self.structuralIdentityKey = structuralIdentityKey ?? identityKey
        self.identityStrength = identityStrength
        self.accessibilityIdentifier = accessibilityIdentifier
        self.title = title
        self.itemDescription = itemDescription
        self.value = value
    }

    var key: String {
        Self.join([provider.instanceKey, identityKey])
    }

    var displayLabel: String {
        for candidate in [title, itemDescription, accessibilityIdentifier, provider.applicationName] {
            if let candidate {
                let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return provider.bundleIdentifier
    }

    var contentRevision: String {
        Self.join([title ?? "", itemDescription ?? "", value ?? ""])
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct MenuBarTopologySnapshot: Equatable, Sendable {
    var items: [MenuBarTopologyItemSnapshot]
    var runningProviders: Set<MenuBarTopologyProvider>
    var unreadableProviders: Set<MenuBarTopologyProvider>
    var ambiguousProviders: Set<MenuBarTopologyProvider>

    init(
        items: [MenuBarTopologyItemSnapshot],
        runningProviders: Set<MenuBarTopologyProvider> = [],
        unreadableProviders: Set<MenuBarTopologyProvider> = [],
        ambiguousProviders: Set<MenuBarTopologyProvider> = []
    ) {
        self.items = items.sorted { $0.key < $1.key }
        self.runningProviders = runningProviders
        self.unreadableProviders = unreadableProviders
        let duplicateProviders = Dictionary(grouping: items, by: \.key).values
            .filter { $0.count > 1 }
            .compactMap(\.first?.provider)
        self.ambiguousProviders = ambiguousProviders.union(duplicateProviders)
    }

    var structuralRevision: String {
        items.map(\.key).joined(separator: "\n")
    }

    var hasUnreadableProviders: Bool { !unreadableProviders.isEmpty }

    /// Accepts readable providers from the current poll while retaining the
    /// last confirmed items for only the exact process instances that could
    /// not be read. A helper failure must not freeze a healthy sibling that
    /// happens to use the same bundle identifier.
    func preservingConfirmedItemsForUnreadableProviders(
        from previous: MenuBarTopologySnapshot
    ) -> MenuBarTopologySnapshot {
        let unreadableInstanceKeys = Set(unreadableProviders.map(\.instanceKey))
        guard !unreadableInstanceKeys.isEmpty else { return self }

        let readableCurrentItems = items.filter {
            !unreadableInstanceKeys.contains($0.provider.instanceKey)
        }
        let retainedPreviousItems = previous.items.filter {
            unreadableInstanceKeys.contains($0.provider.instanceKey)
        }
        let retainedAmbiguousProviders = previous.ambiguousProviders.filter {
            unreadableInstanceKeys.contains($0.instanceKey)
        }

        return MenuBarTopologySnapshot(
            items: readableCurrentItems + retainedPreviousItems,
            runningProviders: runningProviders,
            unreadableProviders: unreadableProviders,
            ambiguousProviders: ambiguousProviders.union(retainedAmbiguousProviders)
        )
    }
}

struct MenuBarTopologyDelta: Equatable, Sendable {
    let added: [MenuBarTopologyItemSnapshot]
    let removed: [MenuBarTopologyItemSnapshot]
    /// Content changes for an item with a unique AX identifier. These can be
    /// represented as a specific proxy without treating the item as replaced.
    let contentChanged: [MenuBarTopologyItemSnapshot]
    /// A weakly identified item's metadata changed while its structural slot
    /// stayed the same. Keep the assertion and baseline, but do not claim that
    /// an exact icon changed or automatically surface a possibly wrong item.
    let weakMetadataChanged: [MenuBarTopologyItemSnapshot]
    let restartedBundleIdentifiers: Set<String>
    let unreadableProviders: Set<MenuBarTopologyProvider>
    let ambiguousProviders: Set<MenuBarTopologyProvider>

    static func between(
        _ previous: MenuBarTopologySnapshot,
        _ current: MenuBarTopologySnapshot
    ) -> MenuBarTopologyDelta {
        // The live reader guarantees unique keys. Keep this defensive merge so
        // a malformed/test snapshot cannot terminate the whole application.
        let oldByKey = Dictionary(
            previous.items.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newByKey = Dictionary(
            current.items.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let oldKeys = Set(oldByKey.keys)
        let newKeys = Set(newByKey.keys)
        let added = newKeys.subtracting(oldKeys)
            .compactMap { newByKey[$0] }
            .sorted { $0.key < $1.key }
        let removed = oldKeys.subtracting(newKeys)
            .compactMap { oldByKey[$0] }
            .sorted { $0.key < $1.key }

        var contentChanged: [MenuBarTopologyItemSnapshot] = []
        var weakMetadataChanged: [MenuBarTopologyItemSnapshot] = []
        for key in oldKeys.intersection(newKeys).sorted() {
            guard let old = oldByKey[key], let new = newByKey[key],
                  old.contentRevision != new.contentRevision else { continue }
            if new.identityStrength == .strong {
                contentChanged.append(new)
            } else {
                weakMetadataChanged.append(new)
            }
        }

        let oldPIDsByBundle = Dictionary(grouping: previous.items, by: { $0.provider.bundleIdentifier })
            .mapValues { Set($0.map(\.provider.processIdentifier)) }
        let newPIDsByBundle = Dictionary(grouping: current.items, by: { $0.provider.bundleIdentifier })
            .mapValues { Set($0.map(\.provider.processIdentifier)) }
        let restarted = Set(oldPIDsByBundle.keys).intersection(newPIDsByBundle.keys).filter {
            oldPIDsByBundle[$0] != newPIDsByBundle[$0]
        }

        return MenuBarTopologyDelta(
            added: added,
            removed: removed,
            contentChanged: contentChanged,
            weakMetadataChanged: weakMetadataChanged,
            restartedBundleIdentifiers: restarted,
            unreadableProviders: current.unreadableProviders,
            ambiguousProviders: current.ambiguousProviders
        )
    }

    var isEmpty: Bool {
        added.isEmpty
            && removed.isEmpty
            && contentChanged.isEmpty
            && restartedBundleIdentifiers.isEmpty
    }

    var presentationCandidates: [MenuBarTopologyItemSnapshot] {
        var byKey: [String: MenuBarTopologyItemSnapshot] = [:]
        for item in added + contentChanged { byKey[item.key] = item }
        return byKey.values.sorted { $0.key < $1.key }
    }
}

/// Shared ID construction for full discovery and the lightweight topology
/// reader. Dynamic titles never enter the stable component.
enum MenuBarStatusItemIdentity {
    static func stableComponent(identifier: String?, structuralPath: [Int]) -> String {
        if let identifier {
            let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return "identifier:\(clean)" }
        }
        return "path:" + structuralPath.map(String.init).joined(separator: ".")
    }

    static func orderItemID(
        displayID: UInt32,
        processIdentifier: Int32,
        bundleIdentifier: String,
        stableComponent: String
    ) -> String {
        [String(displayID), String(processIdentifier), bundleIdentifier, stableComponent]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

enum MenuBarUserVisibilityIntent: Equatable, Sendable {
    case collapsed
    case revealed
}

struct MenuBarChangePresentation: Equatable, Sendable {
    let id: UUID
    let items: [MenuBarQuickBarItem]
}
