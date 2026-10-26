import Foundation

/// The only point at which a caller is allowed to invoke the native visibility bridge.
/// A `.beginNative` decision is produced only after the collapse plan was persisted.
public enum PersistentHideNativeBeginDecision: Equatable, Sendable {
    case doNotBegin
    case beginNative(token: UUID)
}

/// Cleanup required after a session is invalidated.
/// Releasing an absent native assertion is intentionally safe for the caller.
public enum PersistentHideEndAction: Equatable, Sendable {
    case none
    case cancelPendingPlan
    case releaseNativeAssertion
}

/// Pure state for one long-lived collapse request.
///
/// This type has no timer or deadline. The owner keeps the native assertion alive until
/// an explicit end, a topology change, or a current native request failure invalidates it.
public struct PersistentHideSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case expanded
        case preparing
        case collapsing
        case collapsed
        case expandedWithReason(String)
    }

    public private(set) var token: UUID?
    public private(set) var topologyRevision: String?
    public private(set) var phase: Phase = .expanded

    public init() {}

    public var isActive: Bool {
        token != nil
    }

    /// Starts plan preparation. A second begin cannot replace a live session because doing
    /// so could orphan its native assertion. The caller must end the current token first.
    @discardableResult
    public mutating func begin(
        topologyRevision: String,
        token newToken: UUID = UUID()
    ) -> UUID? {
        guard token == nil else { return nil }
        let revision = topologyRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            phase = .expandedWithReason("菜单栏布局版本无效，已保持展开。")
            return nil
        }

        token = newToken
        self.topologyRevision = revision
        phase = .preparing
        return newToken
    }

    /// Records the durable-plan result and decides whether the native begin is allowed.
    /// Calling this again, or with an old token, never emits another begin decision.
    @discardableResult
    public mutating func planPersistenceCompleted(
        token callbackToken: UUID,
        succeeded: Bool,
        failureReason: String = "收起计划保存失败，已保持展开。"
    ) -> PersistentHideNativeBeginDecision {
        guard isCurrent(callbackToken), phase == .preparing else { return .doNotBegin }
        guard succeeded else {
            invalidate(withReason: failureReason)
            return .doNotBegin
        }

        phase = .collapsing
        return .beginNative(token: callbackToken)
    }

    /// Accepts only the first success callback for the current collapsing request.
    @discardableResult
    public mutating func confirm(token callbackToken: UUID) -> Bool {
        guard isCurrent(callbackToken), phase == .collapsing else { return false }
        phase = .collapsed
        return true
    }

    /// Accepts only a failure for the current in-flight native request. A late failure after
    /// confirmation, or any callback from an invalidated token, cannot expand a newer session.
    @discardableResult
    public mutating func fail(
        token callbackToken: UUID,
        reason: String = "原生收起请求失败，已恢复展开。"
    ) -> PersistentHideEndAction {
        guard isCurrent(callbackToken), phase == .collapsing else { return .none }
        invalidate(withReason: reason)
        return .releaseNativeAssertion
    }

    /// Ends exactly the session identified by `endingToken`. Repeating the call is a no-op.
    @discardableResult
    public mutating func end(token endingToken: UUID) -> PersistentHideEndAction {
        guard isCurrent(endingToken) else { return .none }
        let action = endActionForCurrentPhase
        invalidate()
        return action
    }

    /// Convenience for owner shutdown, when it already owns the state serially.
    @discardableResult
    public mutating func endCurrent() -> PersistentHideEndAction {
        guard let token else { return .none }
        return end(token: token)
    }

    /// A changed inventory revision makes the captured left/right grouping unsafe. The session
    /// is invalidated before the caller performs cleanup, so late callbacks cannot recreate it.
    @discardableResult
    public mutating func topologyDidChange(
        to newRevision: String,
        reason: String = "菜单栏布局已变化，已展开，请重新读取。"
    ) -> PersistentHideEndAction {
        guard token != nil else { return .none }
        let revision = newRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision != topologyRevision else { return .none }

        let action = endActionForCurrentPhase
        invalidate(withReason: reason)
        return action
    }

    public func isCurrent(_ candidate: UUID) -> Bool {
        token == candidate
    }

    private var endActionForCurrentPhase: PersistentHideEndAction {
        switch phase {
        case .preparing:
            .cancelPendingPlan
        case .collapsing, .collapsed:
            .releaseNativeAssertion
        case .expanded, .expandedWithReason:
            .none
        }
    }

    private mutating func invalidate(withReason reason: String? = nil) {
        token = nil
        topologyRevision = nil
        if let reason {
            let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .expandedWithReason(text.isEmpty ? "收起已停止，菜单栏保持展开。" : text)
        } else {
            phase = .expanded
        }
    }
}
