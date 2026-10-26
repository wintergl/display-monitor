import Foundation

/// Visual capture is optional, but its asynchronous work must never make an
/// old left/right plan executable. Both complete physical layouts and provider
/// topology must still match when capture finishes.
enum MenuBarCollapsePreparationValidation {
    static func isUnchanged(
        before: AnchoredMenuBarInventory,
        after: AnchoredMenuBarInventory,
        initialTopology: MenuBarTopologySnapshot,
        finalTopology: MenuBarTopologySnapshot
    ) -> Bool {
        guard !initialTopology.structuralRevision.isEmpty,
              initialTopology.structuralRevision == finalTopology.structuralRevision,
              before.anchorIdentity == after.anchorIdentity,
              let originalLayouts = try? before.validatedLayouts(),
              let currentLayouts = try? after.validatedLayouts() else { return false }
        let knownProviders = Set((originalLayouts + currentLayouts).flatMap { layout in
            layout.orderedItems.map {
                ProviderIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier
                )
            }
        })
        guard topologyHealthAllowsPreparation(initialTopology, knownProviders: knownProviders),
              topologyHealthAllowsPreparation(finalTopology, knownProviders: knownProviders)
        else { return false }
        return !currentLayouts.isEmpty
            && layoutSignatures(originalLayouts) == layoutSignatures(currentLayouts)
    }

    /// A helper that has never contributed a confirmed menu-bar item must not
    /// block preparation merely because its AX tree is temporarily unreadable.
    /// Known item providers and duplicate-identifier providers remain fail-closed.
    private static func topologyHealthAllowsPreparation(
        _ topology: MenuBarTopologySnapshot,
        knownProviders: Set<ProviderIdentity>
    ) -> Bool {
        let uncertain = topology.unreadableProviders.union(topology.ambiguousProviders)
        return uncertain.allSatisfy {
            !knownProviders.contains(ProviderIdentity(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentifier: $0.processIdentifier
            ))
        }
    }

    /// Titles and other status text are content. They must not turn one stable
    /// item into a removal plus an addition while optional icon capture runs.
    private static func layoutSignatures(
        _ layouts: [AnchoredMenuBarLayout]
    ) -> [LayoutSignature] {
        layouts
            .sorted { $0.displayID < $1.displayID }
            .map { layout in
                LayoutSignature(
                    displayID: layout.displayID,
                    anchorID: layout.anchorID,
                    items: layout.orderedItems.map {
                        ItemSignature(
                            id: $0.id,
                            bundleIdentifier: $0.bundleIdentifier,
                            processIdentifier: $0.processIdentifier,
                            displayID: $0.displayID,
                            frame: $0.frame
                        )
                    }
                )
            }
    }

    private struct LayoutSignature: Equatable {
        let displayID: UInt32
        let anchorID: String
        let items: [ItemSignature]
    }

    private struct ItemSignature: Equatable {
        let id: String
        let bundleIdentifier: String
        let processIdentifier: Int32
        let displayID: UInt32
        let frame: CGRect
    }

    private struct ProviderIdentity: Hashable {
        let bundleIdentifier: String
        let processIdentifier: Int32
    }
}
