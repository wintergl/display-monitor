import CoreGraphics
import Foundation
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarQuickBarIconCaptureTests: XCTestCase {
    func testTimeoutReturnsWithoutNativeReplyAndRejectsRetryUntilLateSettlement() async {
        let operation = MenuBarQuickBarIconCaptureOperation(
            timeoutNanoseconds: 20_000_000
        )
        let entered = MenuBarIconCaptureTestLatch()
        let nativeReply = MenuBarIconCaptureTestLatch()
        let settled = MenuBarIconCaptureTestLatch()
        var issuedNativeCalls = 0
        var issuedSecondDisplayCapture = false
        var settledCount = 0

        let result = await operation.capture(onSettled: {
            settledCount += 1
            settled.open()
        }) { shouldContinue in
            issuedNativeCalls += 1
            entered.open()
            await nativeReply.wait()
            if shouldContinue() {
                issuedSecondDisplayCapture = true
            }
            return ["late": self.snapshot(9)]
        }

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(issuedNativeCalls, 1)
        XCTAssertFalse(operation.canStart)
        XCTAssertEqual(operation.pendingCount, 1)
        XCTAssertEqual(settledCount, 0)

        var skippedSettled = 0
        let skipped = await operation.capture(onSettled: {
            skippedSettled += 1
        }) { _ in
            issuedNativeCalls += 1
            return ["unexpected": self.snapshot(1)]
        }
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(issuedNativeCalls, 1, "Pending native work must reject retries")
        XCTAssertEqual(skippedSettled, 1, "A skipped caller owns no native resource")

        nativeReply.open()
        await settled.wait()
        XCTAssertEqual(settledCount, 1)
        XCTAssertFalse(issuedSecondDisplayCapture, "Timeout must stop optional follow-up captures")
        XCTAssertTrue(operation.canStart)
        XCTAssertEqual(operation.pendingCount, 0)

        let fresh = await operation.capture { _ in ["fresh": self.snapshot(2)] }
        XCTAssertEqual(fresh, ["fresh": snapshot(2)], "The late result must not leak into a later refresh")
    }

    func testCancellationReturnsBeforeIgnoredNativeReplyAndSettlesOnlyAfterReply() async {
        let operation = MenuBarQuickBarIconCaptureOperation(
            timeoutNanoseconds: 2_000_000_000
        )
        let entered = MenuBarIconCaptureTestLatch()
        let nativeReply = MenuBarIconCaptureTestLatch()
        let settled = MenuBarIconCaptureTestLatch()
        var settledCount = 0

        let request = Task { @MainActor in
            await operation.capture(onSettled: {
                settledCount += 1
                settled.open()
            }) { _ in
                entered.open()
                await nativeReply.wait()
                return ["late": self.snapshot(3)]
            }
        }
        await entered.wait()
        request.cancel()
        let result = await request.value

        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(operation.canStart)
        XCTAssertEqual(operation.pendingCount, 1)
        XCTAssertEqual(settledCount, 0)

        nativeReply.open()
        await settled.wait()
        XCTAssertEqual(settledCount, 1)
        XCTAssertTrue(operation.canStart)
        XCTAssertEqual(operation.pendingCount, 0)
    }

    func testRetinaPixelScaleAndNegativeDisplayOriginUseDisplayLocalCoordinates() throws {
        let display = CGRect(x: -1_440, y: -900, width: 1_440, height: 900)
        let item = MenuBarOrderItem(
            id: "negative-origin",
            bundleIdentifier: "example.item",
            applicationName: "Item",
            title: "Item",
            processIdentifier: 42,
            displayID: 7,
            frame: CGRect(x: -120, y: -900, width: 44, height: 22)
        )

        let geometry = try XCTUnwrap(MenuBarQuickBarCaptureGeometry.make(
            displayID: 7,
            displayBounds: display,
            items: [item]
        ))
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 1_320, y: 0, width: 44, height: 22))
        let pixels = geometry.pixelSize(pointPixelScale: 2)
        XCTAssertEqual(pixels.width, 88)
        XCTAssertEqual(pixels.height, 44)
        XCTAssertEqual(
            geometry.pixelCropRect(
                for: item.id,
                imageSize: CGSize(width: pixels.width, height: pixels.height)
            ),
            CGRect(x: 0, y: 0, width: 88, height: 44)
        )
    }

    private func snapshot(_ byte: UInt8) -> MenuBarQuickBarIconSnapshot {
        MenuBarQuickBarIconSnapshot(
            pngData: Data([byte]),
            pointSize: CGSize(width: 22, height: 22)
        )
    }
}

@MainActor
private final class MenuBarIconCaptureTestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
