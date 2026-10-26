import XCTest
@testable import DisplayMonitor

final class ScreenshotFocusSessionTests: XCTestCase {
    @MainActor
    func testCleanupRestoresOriginalSnapshotOnlyOnce() {
        var captures = 0
        var restored: [Int] = []
        let session = ScreenshotFocusSession {
            captures += 1
            let snapshot = captures
            return { restored.append(snapshot) }
        }
        session.restore()
        session.begin()
        session.begin()
        session.restore()
        session.restore()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(restored, [1])
        session.begin()
        session.restore()
        XCTAssertEqual(restored, [1, 2])
    }
}
