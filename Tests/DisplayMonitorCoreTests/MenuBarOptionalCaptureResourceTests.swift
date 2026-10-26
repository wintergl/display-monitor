import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarOptionalCaptureResourceTests: XCTestCase {
    func testOptionalCaptureSkipsAnExistingUserCapture() async {
        let resources = CaptureResourceCoordinator()
        let decision = await resources.acquire(.still, monitorActive: false)
        XCTAssertEqual(decision, .granted)
        XCTAssertNil(resources.acquireOptionalStill(monitorActive: false))
        XCTAssertEqual(resources.activeResources, [.still])
        resources.release(.still)
    }

    func testOptionalCaptureSkipsRecordingWithoutReadingCapabilities() async {
        let resources = CaptureResourceCoordinator()
        let decision = await resources.acquire(.recording, monitorActive: false)
        XCTAssertEqual(decision, .granted)
        XCTAssertNil(resources.acquireOptionalStill(monitorActive: false))
        XCTAssertEqual(resources.activeResources, [.recording])
        resources.release(.recording)
    }

    func testOldNativeCompletionCannotReleaseANewerOptionalSlot() throws {
        let resources = CaptureResourceCoordinator()
        let first = try XCTUnwrap(resources.acquireOptionalStill(monitorActive: false))
        resources.releaseOptionalStill(first)
        let second = try XCTUnwrap(resources.acquireOptionalStill(monitorActive: false))
        resources.releaseOptionalStill(first)
        XCTAssertEqual(resources.activeResources, [.still])
        resources.releaseOptionalStill(second)
        XCTAssertTrue(resources.activeResources.isEmpty)
    }

    func testUserCapturesWaitForOptionalNativeWorkToActuallySettle() async throws {
        let resources = CaptureResourceCoordinator()
        let token = try XCTUnwrap(resources.acquireOptionalStill(monitorActive: false))
        for kind in CaptureResourceKind.allCases {
            let decision = await resources.acquire(kind, monitorActive: false)
            guard case .rejected(let reason) = decision else {
                return XCTFail("Optional native capture must exclude \(kind)")
            }
            XCTAssertTrue(reason.contains("菜单栏图标采集"))
        }
        XCTAssertEqual(resources.activeResources, [.still])
        resources.releaseOptionalStill(token)
        let decision = await resources.acquire(.scroll, monitorActive: false)
        XCTAssertEqual(decision, .granted)
        resources.release(.scroll)
    }

    func testGenericReleaseAndWrongTokenCannotReleaseOptionalNativeWork() throws {
        let resources = CaptureResourceCoordinator()
        let token = try XCTUnwrap(resources.acquireOptionalStill(monitorActive: false))
        resources.release(.still)
        resources.releaseOptionalStill(UUID())
        XCTAssertEqual(resources.activeResources, [.still])
        XCTAssertNil(resources.acquireOptionalStill(monitorActive: false))
        resources.releaseOptionalStill(token)
        XCTAssertTrue(resources.activeResources.isEmpty)
    }

    func testTerminationInvalidatesOptionalSlotAndRejectsNewOnes() throws {
        let resources = CaptureResourceCoordinator()
        let token = try XCTUnwrap(resources.acquireOptionalStill(monitorActive: false))
        resources.releaseAllForTermination()
        resources.releaseOptionalStill(token)
        XCTAssertTrue(resources.activeResources.isEmpty)
        XCTAssertNil(resources.acquireOptionalStill(monitorActive: false))
    }
}
