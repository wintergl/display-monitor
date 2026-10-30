import Foundation

/// Retry state for one automatic menu-bar collapse intent.
///
/// The coordinator owns scheduling and failure classification. This value only
/// bounds fast retries, backs off while a layout is unavailable, and decides
/// whether newly granted Accessibility permission can resume a collapse intent.
struct MenuBarAutomaticCollapseRecovery: Equatable, Sendable {
    private(set) var isActive = false
    private(set) var retryCount = 0
    private(set) var stabilityWaitCount = 0

    var isWaitingForStability: Bool { isActive && stabilityWaitCount > 0 }

    mutating func begin() {
        isActive = true
        retryCount = 0
        stabilityWaitCount = 0
    }

    mutating func cancel() {
        isActive = false
    }

    mutating func succeeded() {
        isActive = false
    }

    mutating func nextRetryDelay(waitForStability: Bool = false) -> Duration? {
        guard isActive else { return nil }
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        guard retryCount < delays.count else {
            if waitForStability {
                let waits: [Duration] = [.seconds(15), .seconds(30), .seconds(60)]
                let delay = waits[min(stabilityWaitCount, waits.count - 1)]
                stabilityWaitCount = min(stabilityWaitCount + 1, waits.count)
                return delay
            }
            isActive = false
            return nil
        }
        let delay = delays[retryCount]
        retryCount += 1
        return delay
    }

    static func shouldResumeAfterPermissionChange(
        previouslyGranted: Bool,
        nowGranted: Bool,
        wantsPersistentCollapse: Bool,
        isEnabled: Bool,
        isExpanded: Bool,
        hasInteraction: Bool,
        isTerminating: Bool
    ) -> Bool {
        !previouslyGranted
            && nowGranted
            && wantsPersistentCollapse
            && isEnabled
            && isExpanded
            && !hasInteraction
            && !isTerminating
    }
}
