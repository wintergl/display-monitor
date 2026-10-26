import XCTest
@testable import DisplayMonitor

@MainActor
final class LocalPreviewFramePumpTests: XCTestCase {
    func testStopDiscardsLateFrameAndDoesNotStartAnotherRequest() async throws {
        var captures = 0
        var presented: [Int] = []
        var late: CheckedContinuation<Int, Error>?
        let pump = LocalPreviewFramePump<Int>(frameRate: 60, capture: {
            captures += 1
            if captures == 1 { return 1 }
            return try await withCheckedThrowingContinuation { late = $0 }
        }, present: { presented.append($0) }, failed: { _ in XCTFail("Stopped work must not report an error") })
        try await pump.start()
        await eventually { late != nil }
        pump.stop()
        late?.resume(returning: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(presented, [1])
        XCTAssertEqual(captures, 2)
    }

    func testRestartDuringFirstFrameRejectsOldSessionWithoutClearingNewOne() async throws {
        var pending: CheckedContinuation<Int, Error>?
        var captures = 0
        var presented: [Int] = []
        let pump = LocalPreviewFramePump<Int>(frameRate: 1, capture: {
            captures += 1
            if captures == 1 {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return captures
        }, present: { presented.append($0) }, failed: { _ in XCTFail("Unexpected capture failure") })
        let first = Task { try await pump.start() }
        await eventually { pending != nil }
        try await pump.start()
        pending?.resume(returning: 1)
        do { try await first.value; XCTFail("Old start must be cancelled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(presented, [2])
        XCTAssertEqual(pump.frameCount, 1)
        pump.stop()
    }

    func testSlowCaptureNeverOverlapsOrBuildsBacklog() async throws {
        var active = 0
        var maximumActive = 0
        var presented = 0
        let pump = LocalPreviewFramePump<Int>(frameRate: 60, capture: {
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(45))
            return 1
        }, present: { _ in presented += 1 }, failed: { _ in XCTFail("Unexpected capture failure") })
        try await pump.start()
        await eventually { presented >= 3 }
        pump.stop()
        XCTAssertEqual(maximumActive, 1)
    }

    func testSlowWriterAdmissionPreventsCaptureBacklog() async throws {
        var captures = 0
        var completed = 0
        var sink: CheckedContinuation<Void, Never>?
        let pump = LocalPreviewFramePump<Int>(frameRate: 60, capture: {
            captures += 1
            return captures
        }, present: { _ in
            await withCheckedContinuation { sink = $0 }
            completed += 1
        }, failed: { _ in XCTFail("Unexpected error") })
        let start = Task { try await pump.start() }
        await eventually { sink != nil }
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(captures, 1, "An occupied writer must prevent another capture")
        pump.stop()
        sink?.resume()
        do { try await start.value; XCTFail("Stopped first-frame delivery must be cancelled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(completed, 1)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for the capture state")
    }
}
