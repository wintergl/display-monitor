import AVFoundation
import CoreMedia
import CoreVideo
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

final class RecordingWriterTests: XCTestCase {
    @MainActor
    func testLocalScreenshotAdmissionCompletesBeforeFinalizationAndPreservesTimeline() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(assetWriter: assetWriter, input: input, deadlineID: UUID())
        for index in 0..<3 {
            let sample = try makeVideoSample(presentationTime: CMTime(value: Int64(60 + index), timescale: 30))
            await writer.appendAndWait(sample)
            XCTAssertEqual(input.appendedPresentationTimes.count, index + 1)
        }
        let metrics = await writer.finish()
        XCTAssertEqual(metrics.frameCount, 3)
        XCTAssertEqual(metrics.invalidTimestampCount, 0)
        XCTAssertNil(metrics.failure)
        XCTAssertEqual(input.appendedPresentationTimes, [0, 1.0 / 30, 2.0 / 30])
    }
    func testWriterStartsSessionBeforeConsultingFirstFrameReadiness() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID()
        )
        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 60, timescale: 30))
        )

        writer.sampleHandlerQueue.async {
            writer.append(sample.value)
        }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 1)
        XCTAssertNil(metrics.failure)
        XCTAssertEqual(
            events.values.prefix(4),
            ["startWriting", "startSession", "isReady", "append"]
        )
    }

    func testFirstFrameGateCancelAndAppendShareWriterQueueOrder() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID()
        )
        let resolution = await writer.requestFirstFrameCancel()
        XCTAssertEqual(resolution, .cancelWon)

        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )
        writer.sampleHandlerQueue.async {
            writer.append(sample.value)
        }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 0)
        XCTAssertEqual(metrics.failure?.code, "recording_no_valid_frames")
        XCTAssertFalse(events.values.contains("append"))
    }

    func testInjectedFailureBeforeFirstAppendProducesZeroFrameFailure() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID(),
            injectedFault: .beforeFirstAppend
        )
        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )

        writer.sampleHandlerQueue.async { writer.append(sample.value) }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 0)
        XCTAssertEqual(metrics.failure?.code, "recording_writer_fault_injected")
        XCTAssertFalse(events.values.contains("append"))
    }

    func testInjectedFailureAfterThirtySuccessfulFramesPreservesFrameMetrics() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID(),
            injectedFault: .afterSuccessfulFrameCount30
        )
        let samples = try (1...31).map { index in
            SampleBufferBox(
                try makeVideoSample(
                    presentationTime: CMTime(value: CMTimeValue(index), timescale: 30)
                )
            )
        }

        writer.sampleHandlerQueue.async {
            samples.forEach { writer.append($0.value) }
        }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 30)
        XCTAssertEqual(metrics.failure?.code, "recording_writer_fault_injected")
        XCTAssertEqual(events.values.filter { $0 == "append" }.count, 30)
    }

    func testFinishWatchdogAcceptsCompletedWriterWhenCompletionCallbackIsMissed() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        assetWriter.finishBehavior = .completeWithoutCallback
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID(),
            finishTimeout: 0.02
        )
        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )

        writer.sampleHandlerQueue.async { writer.append(sample.value) }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 1)
        XCTAssertNil(metrics.failure)
        XCTAssertFalse(events.values.contains("cancelWriting"))
    }

    func testFinishWatchdogCancelsWriterThatRemainsWriting() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        assetWriter.finishBehavior = .remainWritingWithoutCallback
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID(),
            finishTimeout: 0.02
        )
        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )

        writer.sampleHandlerQueue.async { writer.append(sample.value) }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 1)
        XCTAssertEqual(metrics.failure?.code, "recording_finish_timeout")
        XCTAssertTrue(events.values.contains("cancelWriting"))
    }

    func testWriterFailsImmediatelyWhenStartSessionTransitionsWriterToFailed() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        assetWriter.failOnStartSession = true
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID()
        )
        let sample = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )

        writer.sampleHandlerQueue.async { writer.append(sample.value) }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 0)
        XCTAssertEqual(metrics.failure?.code, "recording_start_writing_failed")
        XCTAssertFalse(events.values.contains("isReady"))
    }

    func testDuplicatePresentationTimestampIsCountedAndNotAppended() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID()
        )
        let first = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )
        let duplicate = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(value: 1, timescale: 30))
        )

        writer.sampleHandlerQueue.async {
            writer.append(first.value)
            writer.append(duplicate.value)
        }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 1)
        XCTAssertEqual(metrics.invalidTimestampCount, 1)
        XCTAssertEqual(events.values.filter { $0 == "append" }.count, 1)
    }

    func testSuccessfulSamplesAreNormalizedToZeroBasedPresentationTime() async throws {
        let events = EventLog()
        let assetWriter = FakeAssetWriter(events: events)
        let input = FakeWriterInput(events: events, assetWriter: assetWriter)
        let writer = RecordingWriter(
            assetWriter: assetWriter,
            input: input,
            deadlineID: UUID()
        )
        let first = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(seconds: 60, preferredTimescale: 600))
        )
        let second = SampleBufferBox(
            try makeVideoSample(presentationTime: CMTime(seconds: 61, preferredTimescale: 600))
        )

        writer.sampleHandlerQueue.async {
            writer.append(first.value)
            writer.append(second.value)
        }
        let metrics = await writer.finish()

        XCTAssertEqual(metrics.frameCount, 2)
        XCTAssertEqual(input.appendedPresentationTimes.count, 2)
        XCTAssertEqual(input.appendedPresentationTimes[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(input.appendedPresentationTimes[1], 1, accuracy: 0.000_1)
    }

    func testTemporaryMP4SuffixValidatesAsPlayableVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("artifact.mp4.tmp")
        let fixture = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMVbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAACgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAj90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAACgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAAoAAAAAAABAAAAAAG3bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAAAgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABYm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAASJzdGJsAAAAvnN0c2QAAAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAAAwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAinoAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAAACAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAALFAAAAAQAAABRzdGNvAAAAAAAAAAEAAANFAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAAs1tZGF0AAACrgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAD2WIhAAr//72c3wKa22xgQ==
        """
        try XCTUnwrap(
            Data(base64Encoded: fixture, options: .ignoreUnknownCharacters)
        ).write(to: output)

        XCTAssertTrue(ArtifactMediaValidator.validate(url: output, kind: .recording))
    }

    private func makeVideoSample(
        presentationTime: CMTime,
        width: Int = 2,
        height: Int = 2
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        guard let pixelBuffer else {
            throw NSError(domain: "RecordingWriterTests", code: 1)
        }
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        guard let formatDescription else {
            throw NSError(domain: "RecordingWriterTests", code: 2)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        guard let sampleBuffer else {
            throw NSError(domain: "RecordingWriterTests", code: 3)
        }
        return sampleBuffer
    }
}

private final class SampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class FakeAssetWriter: RecordingAssetWriterAdapter, @unchecked Sendable {
    enum FinishBehavior {
        case completeWithCallback
        case completeWithoutCallback
        case remainWritingWithoutCallback
    }

    private let events: EventLog
    private(set) var started = false
    var status: AVAssetWriter.Status = .unknown
    var error: Error?
    var finishBehavior: FinishBehavior = .completeWithCallback
    var failOnStartSession = false

    init(events: EventLog) {
        self.events = events
    }

    func startWriting() -> Bool {
        events.append("startWriting")
        started = true
        status = .writing
        return true
    }

    func startSession(atSourceTime startTime: CMTime) {
        events.append("startSession")
        if failOnStartSession {
            status = .failed
        }
    }

    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {
        events.append("finishWriting")
        switch finishBehavior {
        case .completeWithCallback:
            status = .completed
            handler()
        case .completeWithoutCallback:
            status = .completed
        case .remainWritingWithoutCallback:
            break
        }
    }

    func cancelWriting() {
        events.append("cancelWriting")
        status = .cancelled
    }
}

private final class FakeWriterInput: RecordingWriterInputAdapter, @unchecked Sendable {
    private let events: EventLog
    private weak var assetWriter: FakeAssetWriter?
    private let lock = NSLock()
    private var presentationTimes: [Double] = []

    init(events: EventLog, assetWriter: FakeAssetWriter) {
        self.events = events
        self.assetWriter = assetWriter
    }

    var isReadyForMoreMediaData: Bool {
        events.append("isReady")
        return assetWriter?.started == true
    }

    var appendedPresentationTimes: [Double] {
        lock.withLock { presentationTimes }
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        events.append("append")
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.withLock { presentationTimes.append(time) }
        return true
    }

    func markAsFinished() {
        events.append("markAsFinished")
    }
}
