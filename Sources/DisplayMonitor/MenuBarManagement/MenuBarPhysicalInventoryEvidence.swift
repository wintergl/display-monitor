import CoreGraphics
import Foundation

/// Supplied by this app's actual status-item owners, not inferred from foreign
/// application titles or menus. Read before and after physical sampling.
struct MenuBarOwnedStatusItemEvidence: Equatable, Sendable {
    let processIdentifier: Int32
    let mainEntryVisible: Bool
    let visibleItemCount: Int
}

/// A semantic proof, deliberately distinct from the raw temporal revision.
/// No AX handles, labels, cached allow-lists or persisted evidence escape here.
struct MenuBarPhysicalInventoryEvidence: Sendable {
    /// Build a CURRENT inventory, not a comparison with old pixel positions.
    /// Ownership comes only from the exact PID in both fresh application maps;
    /// the same strict physical graph proof below must validate the result.
    static func currentInventory(
        snapshot: MenuBarRawPhysicalStructureSnapshot,
        applicationsBefore: [RunningAppSnapshot],
        applicationsAfter: [RunningAppSnapshot],
        anchor: MenuBarAnchorIdentity,
        ownedStatusItems: MenuBarOwnedStatusItemEvidence? = nil,
        protectionPolicy: MenuBarTargetProtectionPolicy? = nil,
        onReject: (String) -> Void = { _ in }
    ) -> AnchoredMenuBarInventory? {
        guard snapshot.isComplete, let anchorIdentifier = anchor.accessibilityIdentifier,
              !anchorIdentifier.isEmpty,
              case .value(let providerPID) = snapshot.model.providerProcessIdentifier,
              providerPID == MenuBarInstantStructureCollapsePreparation.providerPID(applicationsBefore),
              providerPID == MenuBarInstantStructureCollapsePreparation.providerPID(applicationsAfter)
        else { onReject("inputOrProvider"); return nil }
        let before = Dictionary(grouping: applicationsBefore, by: \.processIdentifier)
        let after = Dictionary(grouping: applicationsAfter, by: \.processIdentifier)
        guard let physical = physicalItems(snapshot: snapshot) else { onReject("physicalGraph"); return nil }
        var items: [MenuBarOrderItem] = []
        var ownProxyIDs: Set<String> = []
        for physicalItem in physical {
            let descriptor = physicalItem.descriptor
            let pid = descriptor.pid
            guard
                  let prior = before[pid], prior.count == 1,
                  let current = after[pid], current.count == 1,
                  let owner = current.first, let oldOwner = prior.first,
                  owner.bundleIdentifier == oldOwner.bundleIdentifier,
                  !owner.bundleIdentifier.isEmpty else { onReject("ownerMapping"); return nil }
            let frame = descriptor.frame
            let identifier = descriptor.identifier
            // Never fall back to an app-name/title match for the fixed boundary.
            let isAnchor = owner.bundleIdentifier == anchor.bundleIdentifier && identifier == anchorIdentifier
            let itemID = "physical:\(pid):\(physicalItem.path.map(String.init).joined(separator: "."))"
            if descriptor.isProxy, owner.bundleIdentifier == anchor.bundleIdentifier { ownProxyIDs.insert(itemID) }
            items.append(MenuBarOrderItem(
                id: itemID,
                bundleIdentifier: owner.bundleIdentifier, applicationName: owner.name,
                title: isAnchor ? anchor.title : "物理状态项",
                accessibilityIdentifier: identifier,
                processIdentifier: pid, displayID: physicalItem.key.display, frame: frame
            ))
        }
        let populatedDisplays = Set(items.map(\.displayID)).sorted()
        guard !populatedDisplays.isEmpty else { onReject("noPhysicalItems"); return nil }
        var choices: [UInt32: [String]] = [:]
        for display in populatedDisplays {
            let own = items.filter { $0.displayID == display && $0.bundleIdentifier == anchor.bundleIdentifier }
            let exact = own.filter { $0.accessibilityIdentifier == anchorIdentifier }
            if exact.count == 1 { choices[display] = [exact[0].id]; continue }
            guard exact.isEmpty, let evidence = ownedStatusItems,
                  evidence.mainEntryVisible, evidence.visibleItemCount > 0,
                  own.count == evidence.visibleItemCount,
                  own.allSatisfy({ $0.processIdentifier == evidence.processIdentifier && ownProxyIDs.contains($0.id) })
            else { onReject("boundaryOwnership"); return nil }
            choices[display] = own.map(\.id)
        }
        var selected = choices.mapValues { $0[0] }
        func inventory(_ selected: [UInt32: String]) -> AnchoredMenuBarInventory {
            let resolved = items.map { item in
                let isBoundary = selected[item.displayID] == item.id
                return MenuBarOrderItem(id: item.id, bundleIdentifier: item.bundleIdentifier,
                    applicationName: item.applicationName, title: isBoundary ? anchor.title : "物理状态项",
                    accessibilityIdentifier: isBoundary ? anchorIdentifier : item.accessibilityIdentifier,
                    processIdentifier: item.processIdentifier, displayID: item.displayID, frame: item.frame)
            }
            return AnchoredMenuBarInventory(items: resolved,
                coverage: .init(expectedDisplayIDs: populatedDisplays,
                    observedCandidateCount: resolved.count, resolvedItemCount: resolved.count), anchorIdentity: anchor)
        }
        let policy = protectionPolicy ?? .init(ownBundleIdentifier: anchor.bundleIdentifier)
        let baseline = inventory(selected)
        guard let targets = try? baseline.collapseTargetBundleIdentifiers(protectionPolicy: policy)
        else { onReject("boundaryOrPlacement"); return nil }
        guard MenuBarPhysicalInventoryEvidence(snapshot: snapshot, inventory: baseline) != nil
        else { onReject("physicalGraph"); return nil }
        // Multiple own entries may lose their AX IDs. Only accept if EVERY
        // possible boundary produces exactly the same safe target set. This
        // cannot confuse the activity entry with the main entry to hide more.
        for (display, ids) in choices {
            let original = selected[display]
            for id in ids {
                selected[display] = id
                guard let alternative = try? inventory(selected).collapseTargetBundleIdentifiers(protectionPolicy: policy),
                      Set(alternative) == Set(targets) else { onReject("ambiguousBoundary"); return nil }
            }
            selected[display] = original
        }
        return baseline
    }

    private struct Key: Hashable {
        let pid: Int32
        let display: UInt32
        let x: UInt64
        let y: UInt64
        let width: UInt64
        let height: UInt64

        init(pid: Int32, display: UInt32, frame: CGRect) {
            self.pid = pid
            self.display = display
            x = Double(frame.origin.x).bitPattern
            y = Double(frame.origin.y).bitPattern
            width = Double(frame.width).bitPattern
            height = Double(frame.height).bitPattern
        }
    }

    init?(snapshot: MenuBarRawPhysicalStructureSnapshot, inventory: AnchoredMenuBarInventory) {
        guard let items = Self.physicalItems(snapshot: snapshot),
              items.count == inventory.items.count, !items.isEmpty else { return nil }
        let physical = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.descriptor) })
        var matched: Set<Key> = []
        for item in inventory.items {
            let key = Key(pid: item.processIdentifier, display: item.displayID, frame: item.frame)
            guard let raw = physical[key], matched.insert(key).inserted else { return nil }
            if let rawIdentifier = raw.identifier, let identifier = item.accessibilityIdentifier,
               rawIdentifier != identifier { return nil }
        }
        guard matched.count == physical.count else { return nil }
    }

    private struct PhysicalItem {
        let path: [Int]
        let key: Key
        let descriptor: Descriptor
    }

    private struct ItemSemantics: Equatable {
        let identifier: String?
        let isProxy: Bool
    }

    /// Prove every root and node before collapsing equivalent window replicas.
    /// A repeated AXWindow may describe the same physical bar; only an exact
    /// semantic set match permits counting its items once. Shared opaque owner
    /// references remain part of every root's proof, including across displays.
    private static func physicalItems(snapshot: MenuBarRawPhysicalStructureSnapshot) -> [PhysicalItem]? {
        guard snapshot.isComplete,
              case .value(let provider) = snapshot.model.providerProcessIdentifier,
              provider > 0 else { return nil }
        let model = snapshot.model
        var displays: [(UInt32, CGRect)] = []
        for display in model.displays {
            guard case .value(let value) = display.bounds, let bounds = rect(value),
                  !displays.contains(where: { $0.0 == display.id }) else { return nil }
            displays.append((display.id, bounds))
        }
        var nodes: [[Int]: MenuBarRawPhysicalNode] = [:]
        for node in model.nodes {
            guard nodes.updateValue(node, forKey: node.path) == nil else { return nil }
        }
        guard let application = nodes[[]], application.role == .value("AXApplication"),
              application.processIdentifier == .value(provider),
              let rootEdges = edges(application), !rootEdges.isEmpty,
              Set(rootEdges).count == rootEdges.count else { return nil }
        var roots: [(path: [Int], display: UInt32, frame: CGRect)] = []
        for path in rootEdges {
            guard let node = nodes[path] else { return nil }
            guard node.role == .value("AXWindow") else { continue }
            guard node.processIdentifier == .value(provider), let frame = frame(node) else { return nil }
            let matches = displays.filter {
                abs(frame.minY - $0.1.minY) <= 1 && frame.height <= 80
                    && frame.width >= $0.1.width / 2
                    && frame.minX >= $0.1.minX - 2 && frame.maxX <= $0.1.maxX + 2
            }
            guard matches.count == 1 else { return nil }
            roots.append((path, matches[0].0, frame))
        }
        guard Set(roots.map(\.display)) == Set(displays.map(\.0)) else { return nil }
        var covered: Set<[Int]> = []
        var active: Set<[Int]> = []
        func visit(_ path: [Int]) -> Bool {
            guard !active.contains(path), let node = nodes[path], let children = edges(node) else { return false }
            if covered.contains(path) { return true }
            active.insert(path)
            for child in children where !visit(child) { return false }
            active.remove(path)
            covered.insert(path)
            return true
        }
        guard visit([]), covered.count == nodes.count else { return nil }

        var physicalCovered: Set<[Int]> = []
        var canonical: [UInt32: [PhysicalItem]] = [:]
        var canonicalSemantics: [UInt32: [Key: ItemSemantics]] = [:]
        var canonicalFrames: [UInt32: CGRect] = [:]
        for root in roots {
            var seen: Set<[Int]> = []
            var items: [PhysicalItem] = []
            var semantics: [Key: ItemSemantics] = [:]
            func collect(_ path: [Int], representedProxy: Bool = false) -> Bool {
                guard let node = nodes[path], let children = edges(node) else { return false }
                physicalCovered.insert(path)
                if node.isOpaqueApplicationProxy {
                    return representedProxy && !path.isEmpty && children.isEmpty
                }
                // Reusing a physical item/container inside one root is not a
                // second window replica and must never silently disappear.
                guard seen.insert(path).inserted else { return false }
                if let item = descriptor(node, nodes: nodes, providerPID: provider) {
                    let matches = displays.filter {
                        item.frame.minY >= $0.1.minY - 2 && item.frame.maxY <= $0.1.minY + 80
                            && item.frame.minX >= $0.1.minX - 2 && item.frame.maxX <= $0.1.maxX + 2
                    }
                    guard matches.count == 1, matches[0].0 == root.display else { return false }
                    let key = Key(pid: item.pid, display: root.display, frame: item.frame)
                    guard semantics[key] == nil else { return false }
                    semantics[key] = ItemSemantics(identifier: item.identifier, isProxy: item.isProxy)
                    items.append(PhysicalItem(path: path, key: key, descriptor: item))
                    for child in children where !collect(child, representedProxy: item.isProxy) { return false }
                    return true
                }
                guard node.role != .value("AXButton"), node.role != .value("AXMenuBarItem"),
                      node.role != .value("AXMenuExtra"),
                      !children.isEmpty || path == root.path else { return false }
                for child in children where !collect(child) { return false }
                return true
            }
            guard collect(root.path) else { return nil }
            if let previous = canonicalSemantics[root.display] {
                guard previous == semantics, canonicalFrames[root.display] == root.frame else { return nil }
            } else {
                canonical[root.display] = items
                canonicalSemantics[root.display] = semantics
                canonicalFrames[root.display] = root.frame
            }
        }
        // MenuBarAgent may additionally expose AXMenuBar/AXGroup aliases of
        // already-proven window items. They add no physical items of their own.
        // Global reachability alone is insufficient: every descriptor and opaque
        // owner must have been represented underneath a qualified window root.
        var aliasCovered: Set<[Int]> = []
        func isProvenAlias(_ path: [Int]) -> Bool {
            if physicalCovered.contains(path) || aliasCovered.contains(path) { return true }
            guard let node = nodes[path], !node.isOpaqueApplicationProxy,
                  node.processIdentifier == .value(provider),
                  node.role == .value("AXMenuBar") || node.role == .value("AXGroup"),
                  descriptor(node, nodes: nodes, providerPID: provider) == nil,
                  let children = edges(node), !children.isEmpty else { return false }
            for child in children where !isProvenAlias(child) { return false }
            aliasCovered.insert(path)
            return true
        }
        for path in nodes.keys where !path.isEmpty && !physicalCovered.contains(path) {
            guard isProvenAlias(path) else { return nil }
        }
        return canonical.keys.sorted().flatMap { canonical[$0] ?? [] }
    }

    private struct Descriptor {
        let pid: Int32
        let frame: CGRect
        let identifier: String?
        let isProxy: Bool
    }

    private static func descriptor(_ node: MenuBarRawPhysicalNode,
        nodes: [[Int]: MenuBarRawPhysicalNode], providerPID: Int32) -> Descriptor? {
        guard !node.isOpaqueApplicationProxy, let children = edges(node), let frame = frame(node) else { return nil }
        let known = node.role == .value("AXButton") || node.role == .value("AXMenuBarItem") || node.role == .value("AXMenuExtra")
        let identifier: String?
        switch node.identifier {
        case .value(let value): identifier = value
        case .absent: identifier = nil
        case .failed: return nil
        }
        if known, children.isEmpty, case .value(let pid) = node.processIdentifier, pid > 0 {
            return Descriptor(pid: pid, frame: frame, identifier: identifier, isProxy: false)
        }
        guard known || node.role == .absent,
              node.processIdentifier == .value(providerPID), children.count == 1,
              let proxy = nodes[children[0]], proxy.isOpaqueApplicationProxy,
              case .value(let owner) = proxy.processIdentifier, owner > 0, owner != providerPID,
              edges(proxy)?.isEmpty == true else { return nil }
        return Descriptor(pid: owner, frame: frame, identifier: identifier, isProxy: true)
    }

    private static func edges(_ node: MenuBarRawPhysicalNode) -> [[Int]]? {
        switch node.children {
        case .absent: return []
        case .failed: return nil
        case .value(let children):
            return children.map {
                switch $0 {
                case .node(let path), .reference(let path): return path
                }
            }
        }
    }

    private static func rect(_ value: MenuBarRawPhysicalRect) -> CGRect? {
        guard [value.x, value.y, value.width, value.height].allSatisfy(\.isFinite),
              value.width > 0, value.height > 0 else { return nil }
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private static func frame(_ node: MenuBarRawPhysicalNode) -> CGRect? {
        switch node.frame {
        case .value(let value): return rect(value)
        case .failed: return nil
        case .absent:
            guard case .value(let position) = node.position,
                  case .value(let size) = node.size else { return nil }
            return rect(.init(x: position.x, y: position.y, width: size.width, height: size.height))
        }
    }
}
