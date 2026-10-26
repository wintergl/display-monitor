import Foundation

/// A local preview owns at most one still-image request. It never starts a
/// sharing stream, queues missed ticks, or publishes a frame after stop/restart.
@MainActor
final class LocalPreviewFramePump<Frame> {
    typealias Capture = @MainActor () async throws -> Frame
    private let capture: Capture
    private let present: @MainActor (Frame) async -> Void
    private let failed: @MainActor (Error) -> Void
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var session: UUID?
    private(set) var frameCount = 0

    init(frameRate: Int, capture: @escaping Capture,
         present: @escaping @MainActor (Frame) async -> Void,
         failed: @escaping @MainActor (Error) -> Void) {
        self.capture = capture
        self.present = present
        self.failed = failed
        interval = .nanoseconds(Int64(1_000_000_000 / max(1, min(60, frameRate))))
    }

    func start() async throws {
        stop()
        let id = UUID()
        session = id
        frameCount = 0
        do {
            let first = try await capture()
            try Task.checkCancellation()
            guard session == id else { throw CancellationError() }
            frameCount += 1
            await present(first)
            try Task.checkCancellation()
            guard session == id else { throw CancellationError() }
        } catch {
            if session == id { session = nil }
            throw error
        }
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var next = clock.now + (self?.interval ?? .seconds(1))
            while let self, self.session == id, !Task.isCancelled {
                do {
                    try await clock.sleep(until: next)
                    guard self.session == id else { return }
                    let frame = try await self.capture()
                    try Task.checkCancellation()
                    guard self.session == id else { return }
                    self.frameCount += 1
                    await self.present(frame)
                    // When capture is slow, drop missed deadlines instead of
                    // scheduling a burst or overlapping native requests.
                    next = max(next + self.interval, clock.now)
                } catch {
                    guard self.session == id, !Task.isCancelled else { return }
                    self.session = nil
                    self.failed(error)
                    return
                }
            }
        }
    }

    func stop() {
        session = nil
        task?.cancel()
        task = nil
    }
}
