import AppKit

/// Unwinds the first terminate() call before asking MainActor work to finish.
/// Returning terminateLater from a Swift task can strand that task inside
/// AppKit's nested event loop, preventing the cleanup and its timer from running.
@MainActor
final class ApplicationTerminationCoordinator {
    enum State: Equatable {
        case running
        case cleaning
        case ready
    }

    private(set) var state: State = .running
    private(set) var didTimeOut = false
    private let timeoutSeconds: TimeInterval
    private let cleanup: @MainActor () async -> Void
    private let requestTermination: @MainActor () -> Void
    private let onCompletion: @MainActor (Bool) -> Void
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(
        timeoutSeconds: TimeInterval = 8,
        cleanup: @escaping @MainActor () async -> Void,
        requestTermination: @escaping @MainActor () -> Void,
        onCompletion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.timeoutSeconds = max(0, timeoutSeconds)
        self.cleanup = cleanup
        self.requestTermination = requestTermination
        self.onCompletion = onCompletion
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        switch state {
        case .ready:
            return .terminateNow
        case .cleaning:
            return .terminateCancel
        case .running:
            state = .cleaning
            cleanupTask = Task { @MainActor [weak self, cleanup] in
                guard !Task.isCancelled else { return }
                await cleanup()
                self?.complete(timedOut: false)
            }
            let delay = UInt64(timeoutSeconds * 1_000_000_000)
            deadlineTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                self?.complete(timedOut: true)
            }
            return .terminateCancel
        }
    }

    private func complete(timedOut: Bool) {
        guard state == .cleaning else { return }
        state = .ready
        didTimeOut = timedOut
        cleanupTask?.cancel()
        deadlineTask?.cancel()
        cleanupTask = nil
        deadlineTask = nil
        onCompletion(timedOut)
        // AppKit termination must start from a Cocoa/main-queue callback,
        // outside the Swift task that completed the cleanup.
        DispatchQueue.main.async { [requestTermination] in
            requestTermination()
        }
    }
}
