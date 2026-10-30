import XCTest
@testable import DisplayMonitor

final class MenuBarAutomaticCollapseRecoveryTests: XCTestCase {
    func testActiveCycleEmitsOnlyOneTwoAndFourSecondRetries() {
        var recovery = MenuBarAutomaticCollapseRecovery()
        recovery.begin()

        XCTAssertTrue(recovery.isActive)
        XCTAssertEqual(recovery.retryCount, 0)
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(1))
        XCTAssertEqual(recovery.retryCount, 1)
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(2))
        XCTAssertEqual(recovery.retryCount, 2)
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(4))
        XCTAssertEqual(recovery.retryCount, 3)
        XCTAssertNil(recovery.nextRetryDelay())
        XCTAssertFalse(recovery.isActive)
        XCTAssertEqual(recovery.retryCount, 3)
        XCTAssertNil(recovery.nextRetryDelay())
    }

    func testSuccessAndCancellationStopFurtherRetries() {
        var succeeded = MenuBarAutomaticCollapseRecovery()
        succeeded.begin()
        XCTAssertEqual(succeeded.nextRetryDelay(), .seconds(1))
        succeeded.succeeded()
        XCTAssertFalse(succeeded.isActive)
        XCTAssertNil(succeeded.nextRetryDelay())

        var cancelled = MenuBarAutomaticCollapseRecovery()
        cancelled.begin()
        XCTAssertEqual(cancelled.nextRetryDelay(), .seconds(1))
        cancelled.cancel()
        XCTAssertFalse(cancelled.isActive)
        XCTAssertNil(cancelled.nextRetryDelay())
    }

    func testUnavailableLayoutContinuesWithCappedSlowChecksAfterFastRetries() {
        var recovery = MenuBarAutomaticCollapseRecovery()
        recovery.begin()
        for delay: Duration in [.seconds(1), .seconds(2), .seconds(4)] {
            XCTAssertEqual(recovery.nextRetryDelay(waitForStability: true), delay)
            XCTAssertFalse(recovery.isWaitingForStability)
        }
        for delay: Duration in [.seconds(15), .seconds(30), .seconds(60), .seconds(60)] {
            XCTAssertEqual(recovery.nextRetryDelay(waitForStability: true), delay)
            XCTAssertTrue(recovery.isWaitingForStability)
        }
        XCTAssertEqual(recovery.retryCount, 3)
        XCTAssertEqual(recovery.stabilityWaitCount, 3)
    }

    func testSlowChecksStopOnCancellationSuccessOrNativeFailure() {
        for stop in 0..<3 {
            var recovery = MenuBarAutomaticCollapseRecovery()
            recovery.begin()
            for _ in 0..<4 { _ = recovery.nextRetryDelay(waitForStability: true) }
            if stop == 0 { recovery.cancel() }
            if stop == 1 { recovery.succeeded() }
            if stop == 2 { XCTAssertNil(recovery.nextRetryDelay(waitForStability: false)) }
            XCTAssertFalse(recovery.isWaitingForStability)
            XCTAssertNil(recovery.nextRetryDelay(waitForStability: true))
        }
    }

    func testNewIntentRestartsFastBudgetAfterSlowWaiting() {
        var recovery = MenuBarAutomaticCollapseRecovery()
        recovery.begin()
        for _ in 0..<5 { _ = recovery.nextRetryDelay(waitForStability: true) }
        recovery.begin()
        XCTAssertFalse(recovery.isWaitingForStability)
        XCTAssertEqual(recovery.stabilityWaitCount, 0)
        XCTAssertEqual(recovery.nextRetryDelay(waitForStability: true), .seconds(1))
    }

    func testBeginningNewCycleResetsRetryBudget() {
        var recovery = MenuBarAutomaticCollapseRecovery()
        recovery.begin()
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(1))
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(2))
        recovery.cancel()

        recovery.begin()

        XCTAssertTrue(recovery.isActive)
        XCTAssertEqual(recovery.retryCount, 0)
        XCTAssertEqual(recovery.nextRetryDelay(), .seconds(1))
    }

    func testPermissionRecoveryRequiresEveryGate() {
        XCTAssertTrue(MenuBarAutomaticCollapseRecovery.shouldResumeAfterPermissionChange(
            previouslyGranted: false,
            nowGranted: true,
            wantsPersistentCollapse: true,
            isEnabled: true,
            isExpanded: true,
            hasInteraction: false,
            isTerminating: false
        ))

        let blockedInputs: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (true, true, true, true, true, false, false),
            (false, false, true, true, true, false, false),
            (false, true, false, true, true, false, false),
            (false, true, true, false, true, false, false),
            (false, true, true, true, false, false, false),
            (false, true, true, true, true, true, false),
            (false, true, true, true, true, false, true),
        ]
        for input in blockedInputs {
            XCTAssertFalse(MenuBarAutomaticCollapseRecovery.shouldResumeAfterPermissionChange(
                previouslyGranted: input.0,
                nowGranted: input.1,
                wantsPersistentCollapse: input.2,
                isEnabled: input.3,
                isExpanded: input.4,
                hasInteraction: input.5,
                isTerminating: input.6
            ))
        }
    }
}
