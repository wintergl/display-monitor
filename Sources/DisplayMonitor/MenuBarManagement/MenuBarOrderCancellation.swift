import Foundation

/// Cancellation and human interference stay latched until this operation ends.
public final class MenuBarOrderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var humanInput = false
    private var reason: String?
    public init() {}
    public func cancel(humanInput: Bool = false, reason: String? = nil) {
        lock.withLock {
            cancelled = true
            self.humanInput = self.humanInput || humanInput
            if self.reason == nil,
               let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                self.reason = reason
            }
        }
    }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public var wasHumanInput: Bool { lock.withLock { humanInput } }
    public var cancellationReason: String? { lock.withLock { reason } }
}
