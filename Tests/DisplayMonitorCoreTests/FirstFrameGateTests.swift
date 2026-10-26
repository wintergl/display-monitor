import XCTest
@testable import DisplayMonitorCore

final class FirstFrameGateTests: XCTestCase {
    func testAppendBeforeCancelMakesFirstFrameMonotonic() {
        var gate = FirstFrameGate(deadlineID: UUID())
        XCTAssertEqual(
            gate.commitSuccessfulAppend(presentationTime: 12.5),
            .firstFrameCommitted(presentationTime: 12.5)
        )
        XCTAssertEqual(
            gate.cancel(),
            .firstFrameAlreadyCommitted(presentationTime: 12.5)
        )
    }

    func testCancelBeforeAppendWins() {
        var gate = FirstFrameGate(deadlineID: UUID())
        XCTAssertEqual(gate.cancel(), .cancelWon)
        XCTAssertEqual(
            gate.commitSuccessfulAppend(presentationTime: 1),
            .alreadyResolved
        )
    }

    func testAppendBeforeDeadlineMakesFirstFrameMonotonic() {
        let deadlineID = UUID()
        var gate = FirstFrameGate(deadlineID: deadlineID)
        XCTAssertEqual(
            gate.commitSuccessfulAppend(presentationTime: 3),
            .firstFrameCommitted(presentationTime: 3)
        )
        XCTAssertEqual(
            gate.timeout(deadlineID: deadlineID),
            .firstFrameAlreadyCommitted(presentationTime: 3)
        )
    }

    func testDeadlineBeforeAppendWins() {
        let deadlineID = UUID()
        var gate = FirstFrameGate(deadlineID: deadlineID)
        XCTAssertEqual(
            gate.timeout(deadlineID: deadlineID),
            .timeoutWon(deadlineID: deadlineID)
        )
        XCTAssertEqual(
            gate.commitSuccessfulAppend(presentationTime: 4),
            .alreadyResolved
        )
    }

    func testCancelBeforeDeadlineWins() {
        let deadlineID = UUID()
        var gate = FirstFrameGate(deadlineID: deadlineID)
        XCTAssertEqual(gate.cancel(), .cancelWon)
        XCTAssertEqual(gate.timeout(deadlineID: deadlineID), .alreadyResolved)
    }

    func testDeadlineBeforeCancelWins() {
        let deadlineID = UUID()
        var gate = FirstFrameGate(deadlineID: deadlineID)
        XCTAssertEqual(
            gate.timeout(deadlineID: deadlineID),
            .timeoutWon(deadlineID: deadlineID)
        )
        XCTAssertEqual(gate.cancel(), .alreadyResolved)
    }

    func testStaleDeadlineCannotResolveGate() {
        let deadlineID = UUID()
        var gate = FirstFrameGate(deadlineID: deadlineID)
        XCTAssertEqual(gate.timeout(deadlineID: UUID()), .alreadyResolved)
        XCTAssertEqual(
            gate.commitSuccessfulAppend(presentationTime: 5),
            .firstFrameCommitted(presentationTime: 5)
        )
    }

    func testLegacyAndCurrentBackpressureCodesShareUserPresentation() {
        XCTAssertEqual(
            RecordingErrorPresentation.message(
                errorCode: "writer_backpressure",
                storedMessage: nil
            ),
            RecordingErrorPresentation.message(
                errorCode: "recording_encoder_backpressure",
                storedMessage: nil
            )
        )
    }
}
