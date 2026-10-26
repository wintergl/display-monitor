import XCTest
@testable import DisplayMonitor

final class LatestPreviewFrameMailboxTests: XCTestCase {
    func testBurstKeepsOnlyLatestFrameAndSchedulesOneDrain() {
        let mailbox = LatestPreviewFrameMailbox<Int>()
        let epoch = mailbox.epoch
        var drainsScheduled = 0
        for frame in 0..<10_000 {
            if mailbox.offer(frame, epoch: epoch) { drainsScheduled += 1 }
        }
        XCTAssertEqual(drainsScheduled, 1)
        let batch = mailbox.takeBatchForDrain()
        XCTAssertEqual(batch?.frame, 9_999)
        XCTAssertEqual(batch?.count, 10_000)
        XCTAssertNil(mailbox.takeForDrain())
        XCTAssertTrue(mailbox.offer(10_000, epoch: epoch))
    }

    func testFlushDropsBufferedFrameAndRejectsOldProducer() {
        let mailbox = LatestPreviewFrameMailbox<Int>()
        let oldEpoch = mailbox.epoch
        XCTAssertTrue(mailbox.offer(1, epoch: oldEpoch))
        mailbox.invalidate()
        XCTAssertFalse(mailbox.offer(2, epoch: oldEpoch))
        XCTAssertNil(mailbox.takeForDrain())
        XCTAssertTrue(mailbox.offer(3, epoch: mailbox.epoch))
        let batch = mailbox.takeBatchForDrain()
        XCTAssertEqual(batch?.frame, 3)
        XCTAssertEqual(batch?.count, 1)
    }

    func testFlushPreservesQueuedDrainWithoutSchedulingDuplicates() {
        let mailbox = LatestPreviewFrameMailbox<Int>()
        XCTAssertTrue(mailbox.offer(1, epoch: mailbox.epoch))
        for frame in 2..<1_000 {
            mailbox.invalidate()
            XCTAssertFalse(mailbox.offer(frame, epoch: mailbox.epoch))
        }
        XCTAssertEqual(mailbox.takeForDrain(), 999)
        XCTAssertTrue(mailbox.offer(1_000, epoch: mailbox.epoch))
    }

    func testProducerAndConsumerCanRaceWithoutLeavingUnscheduledFrame() async {
        let mailbox = LatestPreviewFrameMailbox<Int>()
        let epoch = mailbox.epoch
        let drainedCount = await withTaskGroup(of: Int.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for frame in 0..<1_000 {
                        _ = mailbox.offer(producer * 1_000 + frame, epoch: epoch)
                    }
                    return 0
                }
            }
            group.addTask {
                var count = 0
                for _ in 0..<1_000 { count += mailbox.takeBatchForDrain()?.count ?? 0 }
                return count
            }
            var total = 0
            for await count in group { total += count }
            return total
        }
        let remainingCount = mailbox.takeBatchForDrain()?.count ?? 0
        XCTAssertEqual(drainedCount + remainingCount, 4_000)
        XCTAssertTrue(mailbox.offer(4_000, epoch: epoch))
        XCTAssertEqual(mailbox.takeForDrain(), 4_000)
    }
}
