import ApplicationServices
import Foundation

/// Reads provider-owned AXExtrasMenuBar trees without clicking or moving items.
/// Only confirmed status items enter the structural topology: an unrelated
/// helper process starting or stopping therefore cannot invalidate a collapse.
enum MenuBarTopologyRevisionReader {
    static func read(applications: [RunningAppSnapshot]) -> MenuBarTopologySnapshot {
        let providers = applications
            .filter { $0.processIdentifier > 0 && !$0.bundleIdentifier.isEmpty }
            .map {
                MenuBarTopologyProvider(
                    bundleIdentifier: $0.bundleIdentifier,
                    applicationName: $0.name,
                    processIdentifier: $0.processIdentifier
                )
            }
        var items: [MenuBarTopologyItemSnapshot] = []
        var unreadableProviders: Set<MenuBarTopologyProvider> = []

        for provider in providers.sorted(by: providerOrder) {
            guard !Task.isCancelled else { break }
            let root = AXUIElementCreateApplication(provider.processIdentifier)
            _ = AXUIElementSetMessagingTimeout(root, 0.08)
            let (error, raw) = MenuBarAXAttributeBatch.copyAttributeValue(
                element: root, attribute: kAXExtrasMenuBarAttribute)
            guard error == .success else {
                // These two results are the normal shape of an application that
                // simply has no status item. Other errors are transient/unknown
                // and must not be mistaken for a confirmed removal.
                if error != .attributeUnsupported, error != .noValue {
                    unreadableProviders.insert(provider)
                }
                continue
            }
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                unreadableProviders.insert(provider)
                continue
            }
            let extras = unsafeDowncast(raw, to: AXUIElement.self)
            var visited: [CFHashCode: [AXUIElement]] = [:]
            var providerItems: [MenuBarTopologyItemSnapshot] = []
            var providerReadFailed = false
            collect(
                extras,
                provider: provider,
                depth: 0,
                path: [],
                visited: &visited,
                items: &providerItems,
                providerReadFailed: &providerReadFailed
            )
            if providerReadFailed {
                unreadableProviders.insert(provider)
            } else {
                items.append(contentsOf: providerItems)
            }
        }

        let normalized = normalizeDuplicateIdentifiers(items)

        return MenuBarTopologySnapshot(
            items: normalized.items,
            runningProviders: Set(providers),
            unreadableProviders: unreadableProviders,
            ambiguousProviders: normalized.ambiguousProviders
        )
    }

    /// Duplicate AX identifiers are not strong identity. Keep each item in its
    /// own structural slot for change counting, but mark the provider so the UI
    /// never promises an exact single-item activation.
    static func normalizeDuplicateIdentifiers(
        _ items: [MenuBarTopologyItemSnapshot]
    ) -> (
        items: [MenuBarTopologyItemSnapshot],
        ambiguousProviders: Set<MenuBarTopologyProvider>
    ) {
        var ambiguousProviders: Set<MenuBarTopologyProvider> = []
        let duplicateStrongKeys = Set(
            Dictionary(grouping: items.filter { $0.identityStrength == .strong }) {
                "\($0.provider.instanceKey)|\($0.identityKey)"
            }
            .filter { $0.value.count > 1 }
            .keys
        )
        let normalizedItems = items.map { item in
            let duplicateKey = "\(item.provider.instanceKey)|\(item.identityKey)"
            guard duplicateStrongKeys.contains(duplicateKey) else { return item }
            ambiguousProviders.insert(item.provider)
            return MenuBarTopologyItemSnapshot(
                provider: item.provider,
                identityKey: item.structuralIdentityKey,
                structuralIdentityKey: item.structuralIdentityKey,
                identityStrength: .weak,
                accessibilityIdentifier: nil,
                title: item.title,
                itemDescription: item.itemDescription,
                value: item.value
            )
        }
        return (normalizedItems, ambiguousProviders)
    }

    private static func collect(
        _ node: AXUIElement,
        provider: MenuBarTopologyProvider,
        depth: Int,
        path: [Int],
        visited: inout [CFHashCode: [AXUIElement]],
        items: inout [MenuBarTopologyItemSnapshot],
        providerReadFailed: inout Bool
    ) {
        guard !Task.isCancelled else {
            providerReadFailed = true
            return
        }
        guard depth <= 14 else {
            providerReadFailed = true
            return
        }
        let hash = CFHash(node)
        guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
        visited[hash, default: []].append(node)
        _ = AXUIElementSetMessagingTimeout(node, 0.05)
        let structuralBatch = MenuBarAXAttributeBatch.read(
            element: node,
            attributes: [kAXRoleAttribute, kAXChildrenAttribute]
        )
        let role: String?
        switch structuralBatch.string(kAXRoleAttribute) {
        case .value(let value): role = value
        case .absent: role = nil
        case .failed:
            providerReadFailed = true
            role = nil
        }
        if role == kAXMenuBarItemRole || role == "AXMenuExtra" {
            let metadataBatch = MenuBarAXAttributeBatch.read(
                element: node,
                attributes: [
                    kAXIdentifierAttribute,
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXValueAttribute,
                ]
            )
            let identifier: String?
            switch metadataBatch.string(kAXIdentifierAttribute) {
            case .value(let value): identifier = value
            case .absent: identifier = nil
            case .failed:
                providerReadFailed = true
                identifier = nil
            }
            let structural = MenuBarStatusItemIdentity.stableComponent(
                identifier: nil,
                structuralPath: path
            )
            let stable = MenuBarStatusItemIdentity.stableComponent(
                identifier: identifier,
                structuralPath: path
            )
            let title = valueOrMarkFailure(
                metadataBatch.string(kAXTitleAttribute),
                providerReadFailed: &providerReadFailed
            )
            let itemDescription = valueOrMarkFailure(
                metadataBatch.string(kAXDescriptionAttribute),
                providerReadFailed: &providerReadFailed
            )
            let value = valueOrMarkFailure(
                metadataBatch.scalarString(kAXValueAttribute),
                providerReadFailed: &providerReadFailed
            )
            items.append(MenuBarTopologyItemSnapshot(
                provider: provider,
                identityKey: stable,
                structuralIdentityKey: structural,
                identityStrength: identifier == nil ? .weak : .strong,
                accessibilityIdentifier: identifier,
                title: title,
                itemDescription: itemDescription,
                value: value
            ))
        }
        let children: [AXUIElement]
        switch structuralBatch.elements(kAXChildrenAttribute) {
        case .value(let value): children = value
        case .absent: children = []
        case .failed:
            providerReadFailed = true
            children = []
        }
        for (index, child) in children.enumerated() {
            collect(
                child,
                provider: provider,
                depth: depth + 1,
                path: path + [index],
                visited: &visited,
                items: &items,
                providerReadFailed: &providerReadFailed
            )
        }
    }

    private static func providerOrder(
        _ lhs: MenuBarTopologyProvider,
        _ rhs: MenuBarTopologyProvider
    ) -> Bool {
        if lhs.bundleIdentifier != rhs.bundleIdentifier {
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private static func valueOrMarkFailure<Value>(
        _ result: MenuBarAXAttributeRead<Value>,
        providerReadFailed: inout Bool
    ) -> Value? {
        switch result {
        case .value(let value):
            return value
        case .absent:
            return nil
        case .failed:
            providerReadFailed = true
            return nil
        }
    }
}
