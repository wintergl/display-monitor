import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarQuickBarActivationWaitTests: XCTestCase {
    func testWaitContinuesUntilExactPhysicalItemAppearsAndReturnsFreshFrame() async {
        let proxy = makeProxy()
        let wrongIdentity = makeItem(id: proxy.id, pid: 41, x: 40)
        let fresh = makeItem(id: proxy.id, pid: proxy.processIdentifier, x: 320)
        let timeline = ScriptedPhysicalTimeline(
            budget: .seconds(1),
            scanCost: .milliseconds(100),
            results: [[wrongIdentity], [fresh]]
        )

        let result = await wait(for: proxy, timeline: timeline)

        XCTAssertEqual(result, .target(fresh))
        XCTAssertEqual(fresh.frame.minX, 320)
        let budgets = await timeline.receivedBudgets()
        XCTAssertEqual(budgets, [.seconds(1), .milliseconds(780)])
    }

    func testExactDuplicatePhysicalItemsFailClosedImmediately() async {
        let proxy = makeProxy()
        let item = makeItem(id: proxy.id, pid: proxy.processIdentifier, x: 100)
        let timeline = ScriptedPhysicalTimeline(
            budget: .seconds(1),
            scanCost: .milliseconds(10),
            results: [[item, item]]
        )

        let result = await wait(for: proxy, timeline: timeline)

        XCTAssertEqual(result, .ambiguous)
        let scanCount = await timeline.scanCount()
        XCTAssertEqual(scanCount, 1)
    }

    func testChangedIdentityNeverBecomesAnActivationTarget() async {
        let proxy = makeProxy()
        let restarted = makeItem(id: "restarted", pid: 99, x: 250)
        let timeline = ScriptedPhysicalTimeline(
            budget: .milliseconds(250),
            scanCost: .milliseconds(100),
            results: [[restarted], [restarted]]
        )

        let result = await wait(for: proxy, timeline: timeline)

        XCTAssertEqual(result, .timedOut)
        let scanCount = await timeline.scanCount()
        XCTAssertEqual(scanCount, 2)
    }

    func testEveryScanReceivesOnlyTheStrictlyRemainingTotalBudget() async {
        let proxy = makeProxy()
        let timeline = ScriptedPhysicalTimeline(
            budget: .milliseconds(250),
            scanCost: .milliseconds(100),
            results: [[], []]
        )

        let result = await wait(for: proxy, timeline: timeline)

        XCTAssertEqual(result, .timedOut)
        let budgets = await timeline.receivedBudgets()
        XCTAssertEqual(budgets, [.milliseconds(250), .milliseconds(30)])
        XCTAssertTrue(zip(budgets, budgets.dropFirst()).allSatisfy { pair in
            pair.0 > pair.1
        })
    }

    func testCancellationDuringPausePreventsAnotherScan() async {
        let proxy = makeProxy()
        let probe = CancellationProbe()
        let task = Task {
            await MenuBarQuickBarPhysicalScanWaiter.wait(
                for: proxy,
                pollInterval: .seconds(30),
                remainingBudget: { .seconds(30) },
                scan: { budget in await probe.scan(budget: budget) },
                sleep: { duration in try await probe.sleep(duration: duration) }
            )
        }

        for _ in 0..<1_000 {
            if await probe.isSleeping() { break }
            await Task.yield()
        }
        let didStartSleeping = await probe.isSleeping()
        XCTAssertTrue(didStartSleeping)
        task.cancel()

        let result = await task.value
        let scanCount = await probe.scanCount()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(scanCount, 1)
    }

    private func wait(
        for proxy: MenuBarQuickBarItem,
        timeline: ScriptedPhysicalTimeline
    ) async -> MenuBarQuickBarPhysicalWaitResult {
        await MenuBarQuickBarPhysicalScanWaiter.wait(
            for: proxy,
            remainingBudget: { await timeline.remainingBudget() },
            scan: { budget in await timeline.scan(budget: budget) },
            sleep: { duration in await timeline.sleep(duration: duration) }
        )
    }

    private func makeProxy() -> MenuBarQuickBarItem {
        MenuBarQuickBarItem(
            id: "stable-id",
            bundleIdentifier: "example.target",
            applicationName: "Target",
            itemTitle: "Upload",
            processIdentifier: 42
        )
    }

    private func makeItem(id: String, pid: Int32, x: CGFloat) -> MenuBarOrderItem {
        MenuBarOrderItem(
            id: id,
            bundleIdentifier: "example.target",
            applicationName: "Target",
            title: "Upload",
            processIdentifier: pid,
            displayID: 1,
            frame: CGRect(x: x, y: 0, width: 22, height: 22)
        )
    }
}

private actor ScriptedPhysicalTimeline {
    private var budget: Duration
    private let scanCost: Duration
    private var results: [[MenuBarOrderItem]]
    private var budgets: [Duration] = []
    private var scans = 0

    init(
        budget: Duration,
        scanCost: Duration,
        results: [[MenuBarOrderItem]]
    ) {
        self.budget = budget
        self.scanCost = scanCost
        self.results = results
    }

    func remainingBudget() -> Duration { budget }

    func scan(budget offeredBudget: Duration) -> [MenuBarOrderItem] {
        budgets.append(offeredBudget)
        scans += 1
        consume(scanCost)
        return results.isEmpty ? [] : results.removeFirst()
    }

    func sleep(duration: Duration) {
        consume(duration)
    }

    func receivedBudgets() -> [Duration] { budgets }

    func scanCount() -> Int { scans }

    private func consume(_ duration: Duration) {
        budget = duration >= budget ? .zero : budget - duration
    }
}

private actor CancellationProbe {
    private var scans = 0
    private var sleeping = false

    func scan(budget: Duration) -> [MenuBarOrderItem] {
        scans += 1
        return []
    }

    func sleep(duration: Duration) async throws {
        sleeping = true
        try await Task.sleep(for: duration)
    }

    func isSleeping() -> Bool { sleeping }

    func scanCount() -> Int { scans }
}
