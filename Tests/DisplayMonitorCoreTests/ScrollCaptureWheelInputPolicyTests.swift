import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class ScrollCaptureWheelInputPolicyTests: XCTestCase {
    func testMouseDebounceAndAnalysisMustFinishBeforeAutomaticCanStart() {
        XCTAssertFalse(ScrollCaptureWheelInputPolicy.canStartAutomatic(captureInFlight: false, hasPendingScrollBurst: true),
                       "The debounce window is pending work even before captureInFlight becomes true")
        XCTAssertFalse(ScrollCaptureWheelInputPolicy.canStartAutomatic(captureInFlight: true, hasPendingScrollBurst: false))
        XCTAssertFalse(ScrollCaptureWheelInputPolicy.canStartAutomatic(captureInFlight: true, hasPendingScrollBurst: true))
        XCTAssertTrue(ScrollCaptureWheelInputPolicy.canStartAutomatic(captureInFlight: false, hasPendingScrollBurst: false))
    }

    func testOwnInjectedEventsAreIgnoredBeforeDuringAndAfterAutomaticScrolling() {
        for automatic in [false, true] {
            for delta: CGFloat in [-12, 0, 12, .nan, .infinity] {
                XCTAssertEqual(decision(delta, ended: true, pending: true,
                    tag: ScrollCaptureWheelInputPolicy.injectedEventTag, automatic: automatic), .ignore)
            }
        }
    }

    func testRealMouseWheelAlwaysFollowsWhenAutomaticScrollingIsOff() {
        for tag: Int64? in [nil, 0, 42, ScrollCaptureWheelInputPolicy.injectedEventTag + 1] {
            for delta: CGFloat in [-120, -1, -0.001, .leastNonzeroMagnitude, 0.001, 1, 120] {
                XCTAssertEqual(decision(delta, tag: tag), .followMouse,
                    "Every finite nonzero real wheel event belongs to mouse-follow")
            }
        }
    }

    func testRealMouseWheelTakesOverAutomaticScrollingWithoutWaitingForGestureEnd() {
        for tag: Int64? in [nil, 0, 123] {
            for delta: CGFloat in [-12, -0.001, 0.001, 12] {
                XCTAssertEqual(decision(delta, tag: tag, automatic: true), .stopAutomaticAndFollowMouse)
                XCTAssertEqual(decision(delta, ended: true, pending: true, tag: tag, automatic: true), .stopAutomaticAndFollowMouse)
            }
        }
    }

    func testZeroDeltaOnlyFinishesAnExistingRealMouseGesture() {
        for ended in [false, true] {
            for pending in [false, true] {
                for automatic in [false, true] {
                    let expected: ScrollCaptureWheelInputPolicy.Decision = ended && pending && !automatic ? .followMouse : .ignore
                    XCTAssertEqual(decision(0, ended: ended, pending: pending, automatic: automatic), expected)
                    XCTAssertEqual(decision(-0.0, ended: ended, pending: pending, automatic: automatic), expected)
                }
            }
        }
    }

    func testNonFiniteInputCannotStopAutomaticScrollingOrCreateAPendingGesture() {
        for delta: CGFloat in [.nan, .infinity, -.infinity] {
            for automatic in [false, true] {
                XCTAssertEqual(decision(delta, automatic: automatic), .ignore)
                XCTAssertEqual(decision(delta, ended: true, pending: true, automatic: automatic), .ignore)
            }
        }
    }

    func testLateInjectedTailDoesNotReenterMouseFollowAfterPhysicalTakeover() {
        XCTAssertEqual(decision(-6, automatic: true), .stopAutomaticAndFollowMouse)
        // The controller has stopped its driver. Previously an asynchronously
        // delivered injected event could now look like an ordinary user wheel.
        XCTAssertEqual(decision(-12, pending: true, tag: ScrollCaptureWheelInputPolicy.injectedEventTag), .ignore)
        XCTAssertEqual(decision(0, ended: true, pending: true, tag: ScrollCaptureWheelInputPolicy.injectedEventTag), .ignore)
        XCTAssertEqual(decision(-4, pending: true), .followMouse)
        XCTAssertEqual(decision(0, ended: true, pending: true), .followMouse)
    }

    private func decision(
        _ delta: CGFloat,
        ended: Bool = false,
        pending: Bool = false,
        tag: Int64? = nil,
        automatic: Bool = false
    ) -> ScrollCaptureWheelInputPolicy.Decision {
        ScrollCaptureWheelInputPolicy.decision(deltaY: delta, gestureEnded: ended,
            hasPendingScrollBurst: pending, eventSourceUserData: tag, automaticScrollRunning: automatic)
    }
}
