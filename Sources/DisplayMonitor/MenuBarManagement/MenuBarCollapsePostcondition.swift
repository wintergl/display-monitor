import Foundation

/// A native completion is only an acknowledgement. Check the physical result
/// separately: all targets must disappear and every retained process/display
/// slot (especially our entry) must still be represented. Pixel shifts are OK.
enum MenuBarCollapsePostcondition {
    enum Sample { case verified, restricted, transient, unsafe }
    enum Decision: Equatable { case wait, verified, restricted, unsafe }
    struct SettlingCheck {
        private var good = 0
        private var restricted = 0
        mutating func record(_ sample: Sample) -> Decision {
            switch sample {
            case .unsafe: return .unsafe
            case .verified:
                good += 1; restricted = 0
                return good >= 2 ? .verified : .wait
            case .restricted:
                restricted += 1; good = 0
                return restricted >= 2 ? .restricted : .wait
            case .transient:
                good = 0; restricted = 0
                return .wait
            }
        }
    }
    private struct Slot: Hashable {
        let bundle: String
        let pid: Int32
        let display: UInt32
    }

    static func isSatisfied(
        before: AnchoredMenuBarInventory,
        after: AnchoredMenuBarInventory,
        plan: MenuBarCollapsePlan
    ) -> Bool {
        failureReason(before: before, after: after, plan: plan) == nil
    }

    static func failureReason(
        before: AnchoredMenuBarInventory,
        after: AnchoredMenuBarInventory,
        plan: MenuBarCollapsePlan
    ) -> String? {
        let own = before.anchorIdentity.bundleIdentifier
        let targets = Set(plan.targetBundleIdentifiers)
        guard before.coverage.isComplete, after.coverage.isComplete else { return "incompleteCoverage" }
        guard !targets.contains(own), plan.allowedBundleIdentifiers.contains(own) else { return "unsafeOwnPlan" }
        guard before.anchorIdentity == after.anchorIdentity else { return "anchorChanged" }
        guard Set(before.coverage.expectedDisplayIDs) == Set(after.coverage.expectedDisplayIDs) else { return "populatedDisplaysChanged" }
        guard !after.items.contains(where: { targets.contains($0.bundleIdentifier) }) else { return "targetsStillVisible" }
        func slots(_ items: [MenuBarOrderItem]) -> [Slot: Int] {
            Dictionary(grouping: items, by: {
                Slot(bundle: $0.bundleIdentifier, pid: $0.processIdentifier, display: $0.displayID)
            }).mapValues(\.count)
        }
        let retained = before.items.filter { !targets.contains($0.bundleIdentifier) }
        guard retained.contains(where: { $0.bundleIdentifier == own }) else { return "missingOwnBaseline" }
        guard slots(retained) == slots(after.items) else { return "retainedSlotsChanged" }
        return nil
    }
}
