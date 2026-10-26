import DisplayMonitorCore
import Foundation
import ScreenCaptureKit

/// Owns native requests independently of the UI session. Cancelling a wait does
/// not cancel ScreenCaptureKit: its eventual reply still owns a registry marker
/// until any late stream retirement completes.
@MainActor
final class CaptureSessionNativeOperations {
    private let requests = CaptureNativeRequestRegistry()
    private var startupWait: (id: UUID, cancel: () -> Void)?
    private var startupCancelled = false
    private var streamStops: [ObjectIdentifier: (id: UUID, task: Task<Void, Error>)] = [:]
    private let prefix: String
    private let startupTimeoutNanoseconds: UInt64
    private let stopTimeoutNanoseconds: UInt64

    init(
        prefix: String,
        startupTimeoutNanoseconds: UInt64 = 5_000_000_000,
        stopTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.prefix = prefix
        self.startupTimeoutNanoseconds = startupTimeoutNanoseconds
        self.stopTimeoutNanoseconds = stopTimeoutNanoseconds
    }

    var canStart: Bool { requests.canStart && startupWait == nil && streamStops.isEmpty }
    var pendingCount: Int { requests.pendingCount }
    var needsRecovery: Bool { requests.needsRecovery }

    func beginSession() throws {
        guard canStart else {
            throw CaptureError(
                code: "\(prefix)_native_operation_pending",
                message: needsRecovery
                    ? "系统采集服务停止失败，请重新启动应用"
                    : "系统采集服务仍在结束上次请求，请稍后重试"
            )
        }
        startupCancelled = false
    }

    func cancelStartupWait() {
        startupCancelled = true
        startupWait?.cancel()
    }

    func startupValue<Value>(
        stage: String,
        operation: @escaping @MainActor () async throws -> Value,
        onLateResult: @escaping @MainActor (Swift.Result<Value, Error>) async -> Void = { _ in }
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !startupCancelled else { throw CancellationError() }
        guard canStart else {
            throw CaptureError(
                code: "\(prefix)_native_operation_pending",
                message: "系统采集服务仍在结束上次请求，请稍后重试"
            )
        }
        let deadline = CaptureNativeCallDeadline<Value>()
        let waitID = UUID()
        startupWait = (waitID, { deadline.cancelWait() })
        defer {
            if startupWait?.id == waitID { startupWait = nil }
        }
        return try await value(
            deadline: deadline,
            timeoutNanoseconds: startupTimeoutNanoseconds,
            timeoutError: CaptureError(
                code: "\(prefix)_native_\(stage)_timeout",
                message: "系统采集准备超时，请重试"
            ),
            operation: operation,
            onLateResult: onLateResult
        )
    }

    func stop(_ stream: SCStream, afterLateStart: Bool = false) async throws {
        let key = ObjectIdentifier(stream)
        if let previous = streamStops[key] {
            let result = await previous.task.result
            if !afterLateStart { return try result.get() }
            // A stop issued before native start's reply may have observed an
            // unstarted stream. Once start replies, retire that stream again.
        }
        let stopID = UUID()
        let task = Task { @MainActor [self] in
            try await stop { try await stream.stopCapture() }
        }
        streamStops[key] = (stopID, task)
        defer {
            if streamStops[key]?.id == stopID { streamStops.removeValue(forKey: key) }
        }
        try await task.value
    }

    /// Also used by tests to model native APIs that never call back, or reply
    /// after the caller has already released its UI and artifact ownership.
    func stop(operation: @escaping @MainActor () async throws -> Void) async throws {
        do {
            try await value(
                deadline: CaptureNativeCallDeadline<Void>(),
                timeoutNanoseconds: stopTimeoutNanoseconds,
                timeoutError: CaptureError(
                    code: "\(prefix)_native_stop_timeout",
                    message: "系统采集停止超时，请稍后重试"
                ),
                operation: operation,
                onLateResult: { [self] result in
                    if case .failure(let error) = result, !isAlreadyStopped(error) {
                        requests.markStopFailure()
                    }
                }
            )
        } catch {
            if isAlreadyStopped(error) { return }
            // A timeout still has a pending marker; an actual failed callback
            // has settled, but cannot establish that the old stream is gone.
            let isTimeout = (error as? CaptureError)?.code == "\(prefix)_native_stop_timeout"
            if !isTimeout, !(error is CancellationError) { requests.markStopFailure() }
            throw error
        }
    }

    private func value<Value>(
        deadline: CaptureNativeCallDeadline<Value>,
        timeoutNanoseconds: UInt64,
        timeoutError: CaptureError,
        operation: @escaping @MainActor () async throws -> Value,
        onLateResult: @escaping @MainActor (Swift.Result<Value, Error>) async -> Void
    ) async throws -> Value {
        let requestID = requests.begin()
        return try await deadline.value(
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutError: timeoutError,
            operation: operation,
            onLateResult: onLateResult,
            onSettled: { [self] in requests.settle(requestID) }
        )
    }

    private func isAlreadyStopped(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == -3808
    }
}
