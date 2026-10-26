import Foundation

/// Pure retry state for one automatic menu-bar collapse cycle.
///
/// The coordinator owns scheduling and failure classification. This value only
/// bounds transient retries and decides whether a newly granted Accessibility
/// permission is sufficient to resume an expanded persistent-collapse intent.
struct MenuBarAutomaticCollapseRecovery: Equatable, Sendable {
    private(set) var isActive = false
    private(set) var retryCount = 0

    mutating func begin() {
        isActive = true
        retryCount = 0
    }

    mutating func cancel() {
        isActive = false
    }

    mutating func succeeded() {
        isActive = false
    }

    mutating func nextRetryDelay() -> Duration? {
        guard isActive else { return nil }
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        guard retryCount < delays.count else {
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
