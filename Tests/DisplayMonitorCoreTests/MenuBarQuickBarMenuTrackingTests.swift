import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarMenuTrackingTests: XCTestCase {
    func testClassifierRequiresExactOwnerPopupLayerAndTopAdjacentWindow() {
        let popup = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let windows = [
            window(id: 1, pid: 42, layer: popup, x: 800, y: 24),
            window(id: 2, pid: 43, layer: popup, x: 800, y: 24),
            window(id: 3, pid: 42, layer: 0, x: 800, y: 24),
            window(id: 4, pid: 42, layer: popup, x: 800, y: 220),
        ]

        let result = MenuBarQuickBarMenuWindowClassifier.candidates(
            from: windows,
            ownerPID: 42,
            displayBounds: [display]
        )

        XCTAssertEqual(result.map(\.id), [1])
    }

    func testClassifierSupportsDisplayWithNegativeOrigin() {
        let popup = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let upperDisplay = CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080)
        let target = window(id: 7, pid: 42, layer: popup, x: -1_000, y: -1_052)

        let result = MenuBarQuickBarMenuWindowClassifier.candidates(
            from: [target],
            ownerPID: 42,
            displayBounds: [upperDisplay]
        )

        XCTAssertEqual(result, [target])
    }

    func testTrackerRequiresNewMenuWindowThenTwoClosedSamples() throws {
        let target = identity()
        var tracker = try XCTUnwrap(MenuBarQuickBarMenuTracker(
            baseline: .sample(target: target, menuWindowIDs: [10])
        ))

        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [10])),
            .continueWaiting
        )
        XCTAssertFalse(tracker.didObserveOpen)
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [10, 11])),
            .continueWaiting
        )
        XCTAssertTrue(tracker.didObserveOpen)
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [10])),
            .continueWaiting
        )
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [10])),
            .confirmedClosed
        )
    }

    func testVisibleMenuBetweenClosedSamplesResetsConfirmation() throws {
        let target = identity()
        var tracker = try XCTUnwrap(MenuBarQuickBarMenuTracker(
            baseline: .sample(target: target, menuWindowIDs: [])
        ))

        _ = tracker.ingest(.sample(target: target, menuWindowIDs: [21]))
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [])),
            .continueWaiting
        )
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [22])),
            .continueWaiting
        )
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [])),
            .continueWaiting
        )
        XCTAssertEqual(
            tracker.ingest(.sample(target: target, menuWindowIDs: [])),
            .confirmedClosed
        )
    }

    func testUnreadableOrTargetReplacementStopsWithoutConfirmingClose() throws {
        let target = identity()
        var unreadableTracker = try XCTUnwrap(MenuBarQuickBarMenuTracker(
            baseline: .sample(target: target, menuWindowIDs: [])
        ))
        _ = unreadableTracker.ingest(.sample(target: target, menuWindowIDs: [31]))
        XCTAssertEqual(unreadableTracker.ingest(.unreadable), .stopUnconfirmed)

        var replacedTracker = try XCTUnwrap(MenuBarQuickBarMenuTracker(
            baseline: .sample(target: target, menuWindowIDs: [])
        ))
        _ = replacedTracker.ingest(.sample(target: target, menuWindowIDs: [32]))
        let replacement = MenuBarQuickBarMenuTargetIdentity(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: target.bundleIdentifier,
            launchDate: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            replacedTracker.ingest(.sample(target: replacement, menuWindowIDs: [])),
            .stopUnconfirmed
        )
        XCTAssertEqual(replacedTracker.ingest(.targetUnavailable), .stopUnconfirmed)
    }

    @MainActor
    func testWaiterConfirmsOnlyAfterOpenAndTwoClosedSamples() async {
        let timeline = MenuTrackingTimeline(
            observations: [sample([41]), sample([]), sample([])],
            totalBudget: .seconds(2),
            openingBudget: .seconds(1)
        )

        let result = await wait(timeline: timeline)
        let observationCount = await timeline.observationCount()

        XCTAssertTrue(result)
        XCTAssertEqual(observationCount, 3)
    }

    @MainActor
    func testWaiterTimesOutWithoutAnOpeningSample() async {
        let timeline = MenuTrackingTimeline(
            observations: [sample([]), sample([]), sample([])],
            totalBudget: .seconds(2),
            openingBudget: .milliseconds(400),
            stepCost: .milliseconds(100)
        )

        let result = await wait(timeline: timeline)
        let observationCount = await timeline.observationCount()

        XCTAssertFalse(result)
        XCTAssertEqual(observationCount, 2)
    }

    @MainActor
    func testWaiterStopsWhenTargetExits() async {
        let timeline = MenuTrackingTimeline(
            observations: [sample([51]), .targetUnavailable, sample([]), sample([])],
            totalBudget: .seconds(2),
            openingBudget: .seconds(1)
        )

        let result = await wait(timeline: timeline)
        let observationCount = await timeline.observationCount()

        XCTAssertFalse(result)
        XCTAssertEqual(observationCount, 2)
    }

    @MainActor
    func testWaiterCancellationDuringPauseLeavesExpanded() async {
        let timeline = MenuTrackingTimeline(
            observations: [sample([61]), sample([]), sample([])],
            totalBudget: .seconds(30),
            openingBudget: .seconds(30),
            blocksDuringSleep: true
        )
        let task = Task { @MainActor in await wait(timeline: timeline) }
        for _ in 0..<1_000 {
            if await timeline.isSleeping() { break }
            await Task.yield()
        }
        let didStartSleeping = await timeline.isSleeping()
        XCTAssertTrue(didStartSleeping)
        task.cancel()

        let result = await task.value
        let observationCount = await timeline.observationCount()
        XCTAssertFalse(result)
        XCTAssertEqual(observationCount, 1)
    }

    @MainActor
    private func wait(timeline: MenuTrackingTimeline) async -> Bool {
        await MenuBarQuickBarMenuCloseWaiter.wait(
            baseline: sample([]),
            remainingBudget: { await timeline.remainingTotalBudget() },
            openingRemainingBudget: { await timeline.remainingOpeningBudget() },
            observe: { await timeline.observe() },
            sleep: { duration in try await timeline.sleep(duration: duration) }
        )
    }

    private func identity() -> MenuBarQuickBarMenuTargetIdentity {
        MenuBarQuickBarMenuTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "example.target",
            launchDate: Date(timeIntervalSince1970: 1)
        )
    }

    private func sample(_ ids: Set<CGWindowID>) -> MenuBarQuickBarMenuObservation {
        .sample(target: identity(), menuWindowIDs: ids)
    }

    private func window(
        id: CGWindowID,
        pid: Int32,
        layer: Int,
        x: CGFloat,
        y: CGFloat
    ) -> MenuBarQuickBarMenuWindow {
        MenuBarQuickBarMenuWindow(
            id: id,
            ownerPID: pid,
            layer: layer,
            bounds: CGRect(x: x, y: y, width: 220, height: 300)
        )
    }
}

private actor MenuTrackingTimeline {
    private var observations: [MenuBarQuickBarMenuObservation]
    private var totalBudget: Duration
    private var openingBudget: Duration
    private let stepCost: Duration
    private let blocksDuringSleep: Bool
    private var observationsRead = 0
    private var sleeping = false

    init(
        observations: [MenuBarQuickBarMenuObservation],
        totalBudget: Duration,
        openingBudget: Duration,
        stepCost: Duration = .milliseconds(10),
        blocksDuringSleep: Bool = false
    ) {
        self.observations = observations
        self.totalBudget = totalBudget
        self.openingBudget = openingBudget
        self.stepCost = stepCost
        self.blocksDuringSleep = blocksDuringSleep
    }

    func remainingTotalBudget() -> Duration { totalBudget }

    func remainingOpeningBudget() -> Duration { openingBudget }

    func observe() -> MenuBarQuickBarMenuObservation {
        observationsRead += 1
        consume(stepCost)
        return observations.isEmpty ? .unreadable : observations.removeFirst()
    }

    func sleep(duration: Duration) async throws {
        sleeping = true
        defer { sleeping = false }
        if blocksDuringSleep {
            try await Task.sleep(for: .seconds(30))
        } else {
            consume(duration)
        }
    }

    func observationCount() -> Int { observationsRead }

    func isSleeping() -> Bool { sleeping }

    private func consume(_ duration: Duration) {
        totalBudget = duration >= totalBudget ? .zero : totalBudget - duration
        openingBudget = duration >= openingBudget ? .zero : openingBudget - duration
    }
}
