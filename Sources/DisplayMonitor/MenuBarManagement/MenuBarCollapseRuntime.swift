import Foundation
import MenuBarVisibilityBridge
import OSLog

@MainActor
protocol MenuBarCollapseAssertion: AnyObject {
    func invalidate()
}

extension DMMenuBarVisibilityAssertion: MenuBarCollapseAssertion {}

/// Value reads stay off the main actor in the live implementation. Tests can
/// replace the native assertion as well as the scans, so recovery tests never
/// hide or move the user's real menu-bar items.
@MainActor
struct MenuBarCollapseRuntime {
    var hidingLaunchIssue: @MainActor () -> String? = {
        MenuBarHidingLaunchPolicy.unavailableReason(applicationURL: Bundle.main.bundleURL)
    }

    nonisolated static func performDetachedRead<Value: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let readTask = Task.detached(priority: priority) {
            operation()
        }
        return await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    var applications: @MainActor () -> [RunningAppSnapshot] = {
        AnchoredMenuBarOrderExecutor.applicationSnapshot()
    }
    var discover: @MainActor (
        [RunningAppSnapshot], MenuBarAnchorIdentity, Int32, MenuBarTargetProtectionPolicy
    ) async -> AnchoredMenuBarDiscoveryResult = { applications, anchor, ownPID, policy in
        await MenuBarCollapseRuntime.performDetachedRead(priority: .userInitiated) {
            AnchoredMenuBarDiscovery.scan(
                applications: applications, anchorIdentity: anchor,
                ownPID: ownPID, protectionPolicy: policy
            )
        }
    }
    var topologySnapshot: @MainActor ([RunningAppSnapshot]) async -> MenuBarTopologySnapshot = { applications in
        await MenuBarCollapseRuntime.performDetachedRead(priority: .utility) {
            MenuBarTopologyRevisionReader.read(applications: applications)
        }
    }
    /// A fresh, complete physical-window guard for an already prepared plan.
    /// It deliberately does not rescan every application's logical AX tree.
    var physicalGuard: @MainActor (
        [RunningAppSnapshot], MenuBarAnchorIdentity, Int32, MenuBarTargetProtectionPolicy
    ) async -> AnchoredMenuBarDiscoveryResult = { applications, anchor, ownPID, policy in
        await MenuBarCollapseRuntime.performDetachedRead(priority: .userInitiated) {
            AnchoredMenuBarDiscovery.scanPhysicalGuard(
                applications: applications, anchorIdentity: anchor,
                ownPID: ownPID, protectionPolicy: policy
            )
        }
    }
    /// This is only a temporal fence around independent full-safe discovery;
    /// an equal raw graph never establishes ownership or layout on its own.
    var rawStructureGuardEnabled = true
    var rawPhysicalStructure: @MainActor (
        [RunningAppSnapshot]
    ) async -> MenuBarRawPhysicalStructureSnapshot = { applications in
        await MenuBarCollapseRuntime.performDetachedRead(priority: .userInitiated) {
            MenuBarRawPhysicalStructureReader.read(applications: applications)
        }
    }
    var revealActivity: @MainActor () async -> MenuBarAutomaticRecollapseActivitySnapshot = {
        await MenuBarAutomaticRecollapseActivity.read()
    }
    var revealSleep: @MainActor (Duration) async throws -> Void = { delay in
        try await Task.sleep(for: delay)
    }
    var revealActivityPollingDelay: Duration = .milliseconds(500)
    var instantPrewarmingEnabled = true
    var instantPreparationWarmupDelay: Duration = .milliseconds(120)
    var begin: @MainActor (
        MenuBarCollapsePlan, @escaping @MainActor (Error?) -> Void
    ) -> (any MenuBarCollapseAssertion)? = { plan, completion in
        DMMenuBarVisibility.begin(
            allowing: plan.allowedBundleIdentifiers,
            systemItems: plan.allowedSystemItems.map { NSNumber(value: $0) }
        ) { error in
            Task { @MainActor in completion(error) }
        }
    }
    var sleep: @MainActor (Duration) async throws -> Void = { delay in
        try await Task.sleep(for: delay)
    }
    var nativeConfirmationTimeout: Duration = .seconds(3)
    /// Diagnostic only. An AX subtree is not proof of on-screen visibility and
    /// must NOT control a live assertion's lifetime after native acceptance.
    var verifyPhysicalResult: @MainActor (
        AnchoredMenuBarInventory?, MenuBarCollapsePlan, MenuBarOwnedStatusItemEvidence?
    ) async -> Bool? = { before, plan, owned in
        guard let before, let owned, owned.mainEntryVisible else { return false }
        let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "MenuBarManagement")
        var check = MenuBarCollapsePostcondition.SettlingCheck()
        var context: MenuBarRawPhysicalStructureModel?
        for index in 0..<6 {
            if index > 0 {
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return false }
            }
            let appsBefore = AnchoredMenuBarOrderExecutor.applicationSnapshot()
            let snapshot = await MenuBarCollapseRuntime.performDetachedRead(priority: .userInitiated) {
                MenuBarRawPhysicalStructureReader.read(applications: appsBefore)
            }
            let appsAfter = AnchoredMenuBarOrderExecutor.applicationSnapshot()
            guard !Task.isCancelled else { return false }
            if let context {
                guard context.displays == snapshot.model.displays,
                      context.providerProcessIdentifier == snapshot.model.providerProcessIdentifier else { return false }
            } else { context = snapshot.model }
            let restricted = physicalTreeIsRestricted(snapshot)
            logger.info("menuBar.collapse.postSample index=\(index, privacy: .public) complete=\(snapshot.isComplete, privacy: .public) nodes=\(snapshot.nodeCount, privacy: .public) restricted=\(restricted, privacy: .public)")
            if !snapshot.isComplete {
                let decision = check.record(restricted ? .restricted : .transient)
                if decision == .restricted {
                    logger.notice("menuBar.collapse.postInventoryUnavailable reason=assessmentRestrictedAX")
                    return nil
                }
                continue
            }
            guard let after = MenuBarPhysicalInventoryEvidence.currentInventory(
                snapshot: snapshot, applicationsBefore: appsBefore, applicationsAfter: appsAfter,
                anchor: before.anchorIdentity, ownedStatusItems: owned,
                onReject: { reason in
                    logger.error("menuBar.collapse.postInventoryRejected stage=\(index, privacy: .public) reason=\(reason, privacy: .public) complete=\(snapshot.isComplete, privacy: .public) nodes=\(snapshot.nodeCount, privacy: .public) diagnostics=\(snapshot.diagnostics.summary, privacy: .public)")
                }
            ) else { return false }
            if let reason = MenuBarCollapsePostcondition.failureReason(before: before, after: after, plan: plan) {
                let ownCount = after.items.filter { $0.bundleIdentifier == before.anchorIdentity.bundleIdentifier }.count
                let remaining = after.items.filter { plan.targetBundleIdentifiers.contains($0.bundleIdentifier) }.count
                logger.error("menuBar.collapse.postInventoryMismatch stage=\(index, privacy: .public) reason=\(reason, privacy: .public) before=\(before.items.count, privacy: .public) after=\(after.items.count, privacy: .public) own=\(ownCount, privacy: .public) remainingTargets=\(remaining, privacy: .public)")
                if reason == "targetsStillVisible" {
                    _ = check.record(.transient)
                    continue
                }
                return false
            }
            if check.record(.verified) == .verified { return true }
        }
        logger.error("menuBar.collapse.postSamplesExhausted")
        return false
    }
    /// Assessment mode can deny every root attribute while PID remains valid.
    /// This means unavailable, NOT proof of hidden targets or a retained entry.
    nonisolated static func physicalTreeIsRestricted(_ snapshot: MenuBarRawPhysicalStructureSnapshot) -> Bool {
        guard !snapshot.isComplete, snapshot.model.nodes.count == 1,
              let root = snapshot.model.nodes.first, root.path.isEmpty,
              case .value(let pid) = snapshot.model.providerProcessIdentifier, pid > 0,
              root.processIdentifier == .value(pid), !root.isOpaqueApplicationProxy,
              root.role == .failed || root.role == .value("AXApplication"),
              root.children == .failed else { return false }
        return true
    }
    var topologyMonitoringInterval: TimeInterval = 2
}
