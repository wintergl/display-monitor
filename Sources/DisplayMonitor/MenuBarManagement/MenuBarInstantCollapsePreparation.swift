import CoreGraphics
import Foundation

/// A fully validated collapse baseline that can authorize an instant native
/// request after one fresh physical-only guard. Any uncertain input returns
/// `nil`, allowing the caller to fall back to the existing full-safe path.
struct MenuBarInstantCollapsePreparation: Sendable {
    let inventory: AnchoredMenuBarInventory
    let topology: MenuBarTopologySnapshot

    private let contextRevision: UInt64
    private let anchorIdentity: MenuBarAnchorIdentity
    private let targetBundleIdentifiers: Set<String>
    private let targetProcessIdentifiers: [String: Set<Int32>]
    private let physicalGuardBaseline: Set<GuardItemIdentity>

    init?(
        discovery: AnchoredMenuBarDiscoveryResult,
        physicalGuard: AnchoredMenuBarDiscoveryResult,
        topology: MenuBarTopologySnapshot,
        applications: [RunningAppSnapshot],
        contextRevision: UInt64,
        protectionPolicy: MenuBarTargetProtectionPolicy
    ) {
        let inventory = discovery.inventory
        guard protectionPolicy.ownBundleIdentifier == inventory.anchorIdentity.bundleIdentifier,
              physicalGuard.inventory.anchorIdentity == inventory.anchorIdentity,
              let discoveryLayouts = try? inventory.validatedLayouts(),
              !discoveryLayouts.isEmpty,
              let guardLayouts = try? physicalGuard.inventory.validatedLayouts(),
              !guardLayouts.isEmpty,
              MenuBarCollapsePreparationValidation.isUnchanged(
                  before: inventory,
                  after: inventory,
                  initialTopology: topology,
                  finalTopology: topology
              ),
              let discoveryInventoryPhysical = Self.uniquePhysicalItems(inventory.items),
              let discoveryPhysical = Self.uniquePhysicalItems(discovery.physicalItems),
              let guardInventoryPhysical = Self.uniquePhysicalItems(
                  physicalGuard.inventory.items
              ),
              let guardPhysical = Self.uniquePhysicalItems(physicalGuard.physicalItems),
              discoveryInventoryPhysical == discoveryPhysical,
              discoveryInventoryPhysical == guardInventoryPhysical,
              guardInventoryPhysical == guardPhysical,
              let guardInventoryIdentities = Self.uniqueGuardIdentities(
                  physicalGuard.inventory.items
              ),
              let guardPhysicalIdentities = Self.uniqueGuardIdentities(
                  physicalGuard.physicalItems
              ),
              guardInventoryIdentities == guardPhysicalIdentities,
              let targets = try? inventory.collapseTargetBundleIdentifiers(
                  protectionPolicy: protectionPolicy
              ),
              !targets.isEmpty,
              let guardTargets = try? physicalGuard.inventory
                  .collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
              Set(targets) == Set(guardTargets),
              let targetProcesses = Self.targetProcessIdentifiers(
                  applications: applications,
                  targetBundleIdentifiers: Set(targets)
              ),
              Self.targetItemsBelongToRunningProcesses(
                  inventory.items,
                  targetProcessIdentifiers: targetProcesses
              ),
              (try? MenuBarCollapsePlan(
                  runningBundleIdentifiers: Set(applications.map(\.bundleIdentifier)),
                  targetBundleIdentifiers: Set(targets),
                  protectionPolicy: protectionPolicy
              )) != nil else { return nil }

        self.inventory = inventory
        self.topology = topology
        self.contextRevision = contextRevision
        anchorIdentity = inventory.anchorIdentity
        targetBundleIdentifiers = Set(targets)
        targetProcessIdentifiers = targetProcesses
        physicalGuardBaseline = guardInventoryIdentities
    }

    func planIfUnchanged(
        physicalGuard: AnchoredMenuBarDiscoveryResult,
        applications: [RunningAppSnapshot],
        contextRevision: UInt64,
        protectionPolicy: MenuBarTargetProtectionPolicy
    ) -> MenuBarCollapsePlan? {
        guard contextRevision == self.contextRevision,
              protectionPolicy.ownBundleIdentifier == anchorIdentity.bundleIdentifier,
              physicalGuard.inventory.anchorIdentity == anchorIdentity,
              let layouts = try? physicalGuard.inventory.validatedLayouts(),
              !layouts.isEmpty,
              let inventoryPhysical = Self.uniquePhysicalItems(
                  physicalGuard.inventory.items
              ),
              let physical = Self.uniquePhysicalItems(physicalGuard.physicalItems),
              inventoryPhysical == physical,
              let inventoryIdentities = Self.uniqueGuardIdentities(
                  physicalGuard.inventory.items
              ),
              let physicalIdentities = Self.uniqueGuardIdentities(
                  physicalGuard.physicalItems
              ),
              inventoryIdentities == physicalIdentities,
              inventoryIdentities == physicalGuardBaseline,
              let currentTargets = try? physicalGuard.inventory
                  .collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
              Set(currentTargets) == targetBundleIdentifiers,
              let currentTargetProcesses = Self.targetProcessIdentifiers(
                  applications: applications,
                  targetBundleIdentifiers: targetBundleIdentifiers
              ),
              currentTargetProcesses == targetProcessIdentifiers,
              Self.targetItemsBelongToRunningProcesses(
                  physicalGuard.inventory.items,
                  targetProcessIdentifiers: currentTargetProcesses
              ) else { return nil }

        return try? MenuBarCollapsePlan(
            runningBundleIdentifiers: Set(applications.map(\.bundleIdentifier)),
            targetBundleIdentifiers: targetBundleIdentifiers,
            protectionPolicy: protectionPolicy
        )
    }

    static func uniquePhysicalItems(
        _ items: [MenuBarOrderItem]
    ) -> Set<PhysicalItemIdentity>? {
        var identities: Set<PhysicalItemIdentity> = []
        identities.reserveCapacity(items.count)
        for item in items {
            guard identities.insert(PhysicalItemIdentity(item: item)).inserted else {
                return nil
            }
        }
        return identities
    }

    private static func uniqueGuardIdentities(
        _ items: [MenuBarOrderItem]
    ) -> Set<GuardItemIdentity>? {
        var identities: Set<GuardItemIdentity> = []
        identities.reserveCapacity(items.count)
        for item in items {
            guard identities.insert(GuardItemIdentity(item: item)).inserted else {
                return nil
            }
        }
        return identities
    }

    static func targetProcessIdentifiers(
        applications: [RunningAppSnapshot],
        targetBundleIdentifiers: Set<String>
    ) -> [String: Set<Int32>]? {
        var result = Dictionary(
            uniqueKeysWithValues: targetBundleIdentifiers.map { ($0, Set<Int32>()) }
        )
        for application in applications
        where targetBundleIdentifiers.contains(application.bundleIdentifier) {
            guard application.processIdentifier > 0 else { return nil }
            result[application.bundleIdentifier, default: []].insert(
                application.processIdentifier
            )
        }
        guard result.values.allSatisfy({ !$0.isEmpty }) else { return nil }
        return result
    }

    static func targetItemsBelongToRunningProcesses(
        _ items: [MenuBarOrderItem],
        targetProcessIdentifiers: [String: Set<Int32>]
    ) -> Bool {
        items.allSatisfy { item in
            guard let processes = targetProcessIdentifiers[item.bundleIdentifier] else {
                return true
            }
            return processes.contains(item.processIdentifier)
        }
    }

    struct PhysicalItemIdentity: Hashable, Sendable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let displayID: UInt32
        let frame: CGRect

        init(item: MenuBarOrderItem) {
            bundleIdentifier = item.bundleIdentifier
            processIdentifier = item.processIdentifier
            displayID = item.displayID
            frame = item.frame
        }
    }

    private struct GuardItemIdentity: Hashable, Sendable {
        let id: String
        let accessibilityIdentifier: String?
        let bundleIdentifier: String
        let processIdentifier: Int32
        let displayID: UInt32
        let frame: CGRect

        init(item: MenuBarOrderItem) {
            id = item.id
            accessibilityIdentifier = item.accessibilityIdentifier
            bundleIdentifier = item.bundleIdentifier
            processIdentifier = item.processIdentifier
            displayID = item.displayID
            frame = item.frame
        }
    }
}

/// Raw AX structure is a change detector, not a semantic completeness proof.
/// Only an independently complete, fully validated physical inventory enclosed
/// by two equal raw reads can create this short-lived in-memory preparation.
struct MenuBarInstantStructureCollapsePreparation: Sendable {
    let inventory: AnchoredMenuBarInventory
    let topology: MenuBarTopologySnapshot
    private let revision: String
    private let contextRevision: UInt64
    private let targetBundleIdentifiers: Set<String>
    private let targetProcesses: [String: Set<Int32>]
    private let providerPID: Int32
    private let requiresPhysicalEvidence: Bool
    let hasIndependentPhysicalBaseline: Bool
    private let physicalDisplays: [MenuBarRawPhysicalDisplay]

    init?(
        discovery: AnchoredMenuBarDiscoveryResult,
        before: MenuBarRawPhysicalStructureSnapshot,
        after: MenuBarRawPhysicalStructureSnapshot,
        topology: MenuBarTopologySnapshot,
        applicationsBefore: [RunningAppSnapshot],
        applicationsDuring: [RunningAppSnapshot],
        applicationsAfter: [RunningAppSnapshot],
        contextRevision: UInt64,
        protectionPolicy: MenuBarTargetProtectionPolicy
    ) {
        let inventory = discovery.inventory
        guard before.isComplete, after.isComplete,
              !before.revision.isEmpty, before.revision == after.revision,
              protectionPolicy.ownBundleIdentifier == inventory.anchorIdentity.bundleIdentifier,
              let layouts = try? inventory.validatedLayouts(), !layouts.isEmpty,
              MenuBarCollapsePreparationValidation.isUnchanged(
                before: inventory, after: inventory,
                initialTopology: topology, finalTopology: topology
              ),
              let inventoryPhysical = MenuBarInstantCollapsePreparation.uniquePhysicalItems(inventory.items),
              let physical = MenuBarInstantCollapsePreparation.uniquePhysicalItems(discovery.physicalItems),
              (inventoryPhysical == physical || MenuBarPhysicalInventoryEvidence(
                snapshot: before, inventory: inventory
              ) != nil),
              let targets = try? inventory.collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
              !targets.isEmpty,
              let processes = MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applicationsBefore, targetBundleIdentifiers: Set(targets)
              ),
              processes == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applicationsDuring, targetBundleIdentifiers: Set(targets)
              ),
              processes == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applicationsAfter, targetBundleIdentifiers: Set(targets)
              ),
              MenuBarInstantCollapsePreparation.targetItemsBelongToRunningProcesses(
                inventory.items, targetProcessIdentifiers: processes
              ),
              let providerPID = Self.providerPID(applicationsBefore),
              providerPID == Self.providerPID(applicationsDuring),
              providerPID == Self.providerPID(applicationsAfter),
              (try? MenuBarCollapsePlan(
                runningBundleIdentifiers: Set(applicationsAfter.map(\.bundleIdentifier)),
                targetBundleIdentifiers: Set(targets), protectionPolicy: protectionPolicy
              )) != nil else { return nil }
        self.inventory = inventory
        self.topology = topology
        revision = after.revision
        self.contextRevision = contextRevision
        targetBundleIdentifiers = Set(targets)
        targetProcesses = processes
        self.providerPID = providerPID
        requiresPhysicalEvidence = inventoryPhysical != physical
        hasIndependentPhysicalBaseline = MenuBarPhysicalInventoryEvidence(
            snapshot: before, inventory: inventory
        ) != nil
        physicalDisplays = before.model.displays
    }

    func planIfUnchanged(
        structure: MenuBarRawPhysicalStructureSnapshot,
        applicationsBeforeRead: [RunningAppSnapshot],
        applications: [RunningAppSnapshot],
        contextRevision: UInt64,
        protectionPolicy: MenuBarTargetProtectionPolicy
    ) -> MenuBarCollapsePlan? {
        // A temporal hash is not a physical proof. When an independent typed
        // physical baseline exists, renew that proof from the entire fresh
        // graph just like the physical-guard path, rather than demanding the
        // same incidental container ordering after reveal. Unknown leaves,
        // missing/extra items, PID/frame/identifier or display changes reject.
        let physicalRenewal = hasIndependentPhysicalBaseline
            && structure.model.displays == physicalDisplays
            && MenuBarPhysicalInventoryEvidence(snapshot: structure, inventory: inventory) != nil
        guard structure.isComplete,
              (structure.revision == revision || physicalRenewal),
              (!requiresPhysicalEvidence || physicalRenewal),
              contextRevision == self.contextRevision,
              protectionPolicy.ownBundleIdentifier == inventory.anchorIdentity.bundleIdentifier,
              providerPID == Self.providerPID(applicationsBeforeRead),
              providerPID == Self.providerPID(applications),
              targetProcesses == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applicationsBeforeRead, targetBundleIdentifiers: targetBundleIdentifiers
              ),
              targetProcesses == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applications, targetBundleIdentifiers: targetBundleIdentifiers
              ),
              let currentTargets = try? inventory.collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
              Set(currentTargets) == targetBundleIdentifiers else { return nil }
        // Never cache an allow-list: new non-target applications remain allowed.
        return try? MenuBarCollapsePlan(
            runningBundleIdentifiers: Set(applications.map(\.bundleIdentifier)),
            targetBundleIdentifiers: targetBundleIdentifiers, protectionPolicy: protectionPolicy
        )
    }

    static func providerPID(_ applications: [RunningAppSnapshot]) -> Int32? {
        let providers = applications.filter { $0.bundleIdentifier == "com.apple.MenuBarAgent" }
        guard providers.count == 1, let provider = providers.first,
              provider.processIdentifier > 0 else { return nil }
        return provider.processIdentifier
    }

    /// Recompute placement from the complete CURRENT physical tree. Protected
    /// system items may appear/disappear and shift every x-coordinate; that is
    /// not a reason to compare against stale pixels or launch timed retries.
    /// The previously validated target set and process instances cannot change.
    func currentPhysicalPlan(
        structure: MenuBarRawPhysicalStructureSnapshot,
        applicationsBeforeRead: [RunningAppSnapshot],
        applications: [RunningAppSnapshot],
        contextRevision: UInt64,
        protectionPolicy: MenuBarTargetProtectionPolicy,
        ownedStatusItems: MenuBarOwnedStatusItemEvidence? = nil,
        onReject: (String) -> Void = { _ in }
    ) -> (inventory: AnchoredMenuBarInventory, plan: MenuBarCollapsePlan)? {
        guard hasIndependentPhysicalBaseline,
              contextRevision == self.contextRevision,
              structure.model.displays == physicalDisplays,
              protectionPolicy.ownBundleIdentifier == inventory.anchorIdentity.bundleIdentifier,
              providerPID == Self.providerPID(applicationsBeforeRead),
              providerPID == Self.providerPID(applications),
              targetProcesses == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applicationsBeforeRead, targetBundleIdentifiers: targetBundleIdentifiers),
              targetProcesses == MenuBarInstantCollapsePreparation.targetProcessIdentifiers(
                applications: applications, targetBundleIdentifiers: targetBundleIdentifiers)
        else { onReject("baselineContextOrProcess"); return nil }
        guard let current = MenuBarPhysicalInventoryEvidence.currentInventory(
                snapshot: structure, applicationsBefore: applicationsBeforeRead,
                applicationsAfter: applications, anchor: inventory.anchorIdentity,
                ownedStatusItems: ownedStatusItems, protectionPolicy: protectionPolicy)
        else { onReject("currentPhysicalInventoryInvalid"); return nil }
        guard let targets = try? current.collapseTargetBundleIdentifiers(protectionPolicy: protectionPolicy),
              Set(targets) == targetBundleIdentifiers
        else { onReject("currentTargetsChanged"); return nil }
        guard let plan = try? MenuBarCollapsePlan(
                runningBundleIdentifiers: Set(applications.map(\.bundleIdentifier)),
                targetBundleIdentifiers: Set(targets), protectionPolicy: protectionPolicy)
        else { onReject("currentPlanInvalid"); return nil }
        return (current, plan)
    }
}
