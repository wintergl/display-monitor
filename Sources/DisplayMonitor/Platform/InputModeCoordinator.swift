import Combine
import DisplayMonitorCore
import Foundation
import OSLog

@MainActor
final class InputModeCoordinator: ObservableObject {
    @Published private(set) var lease: InputLease?
    @Published private(set) var globalShortcutSafetyPaused = false

    private var registry = InputLeaseRegistry()
    private var isTerminating = false
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "InputLease")

    var directPointerSuspended: Bool {
        globalShortcutSafetyPaused || lease != nil && lease?.owner != .directPointer
    }

    @discardableResult
    func acquire(
        _ owner: InputLeaseOwner,
        operationID: UUID = UUID()
    ) -> InputLeaseToken? {
        guard !isTerminating else { return nil }
        let token = registry.acquire(owner: owner, operationID: operationID)
        if token == nil {
            logger.error("input_lease_acquire_rejected owner=\(owner.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public)")
        }
        lease = registry.activeLease
        return token
    }

    @discardableResult
    func transfer(
        _ token: InputLeaseToken,
        to owner: InputLeaseOwner
    ) -> InputLeaseToken? {
        guard !isTerminating else { return nil }
        let replacement = registry.transfer(token, to: owner)
        if replacement == nil {
            logger.error("input_lease_transfer_rejected from=\(token.owner.rawValue, privacy: .public) to=\(owner.rawValue, privacy: .public) operation=\(token.operationID.uuidString, privacy: .public)")
        }
        lease = registry.activeLease
        return replacement
    }

    @discardableResult
    func release(
        _ token: InputLeaseToken,
        reason: InputLeaseReleaseReason = .completed
    ) -> Bool {
        let didRelease = registry.release(token, reason: reason)
        if !didRelease {
            logger.error("input_lease_token_mismatch owner=\(token.owner.rawValue, privacy: .public) operation=\(token.operationID.uuidString, privacy: .public)")
        }
        lease = registry.activeLease
        return didRelease
    }

    @discardableResult
    func releaseAll(reason: InputLeaseReleaseReason) -> InputLease? {
        let previous = registry.releaseAll(reason: reason)
        lease = registry.activeLease
        return previous
    }

    func setGlobalShortcutSafetyPaused(_ paused: Bool) {
        guard !isTerminating else { return }
        globalShortcutSafetyPaused = paused
    }

    func beginTermination() {
        isTerminating = true
        globalShortcutSafetyPaused = true
    }
}
