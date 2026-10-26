import AppKit
import CoreGraphics
import DisplayMonitorCore
import Foundation
import ImageIO
import XCTest

@testable import DisplayMonitor

final class ScrollStitcherTests: XCTestCase {
    func testCaptureDeadlineDoesNotPreventFinalizingAcceptedPieces() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("accepted.png")
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 17), to: source)
        let sourceBytes = try Data(contentsOf: source)
        let limits = ScrollCaptureLimits.default
        let size = PixelSize(width: 16, height: 20)

        for elapsed in [TimeInterval(119), 120, 121] {
            let captureDecision = limits.decision(
                width: size.width,
                projectedHeight: size.height,
                pieceCount: 1,
                elapsed: elapsed,
                temporaryBytes: 1_280,
                availableDiskBytes: limits.storage.minimumFreeDiskBytes
            )
            XCTAssertEqual(
                captureDecision,
                elapsed <= 120
                    ? .allow(mode: .fullBitmap, outputPixelCount: 320)
                    : .reject(.timeLimit)
            )
            let decision = limits.finalizationDecision(
                width: size.width,
                projectedHeight: size.height,
                pieceCount: 1,
                temporaryBytes: 1_280,
                availableDiskBytes: limits.storage.minimumFreeDiskBytes
            )
            guard case .allow(let mode, _) = decision else {
                return XCTFail("已有片段应能在 \(elapsed) 秒收尾")
            }
            let destination = root.appendingPathComponent("final-\(Int(elapsed)).png")
            _ = try ScrollStitcher.writePNG(
                pieces: [ScrollStitchPiece(url: source, topY: 0, pixelSize: size)],
                outputSize: size,
                mode: mode,
                limits: limits,
                destination: destination
            )
            try assertDecodedSize(of: destination, width: 16, height: 20)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        }
    }

    func testFinalizationRetainsSizePixelAndDiskLimits() {
        let limits = ScrollCaptureLimits.default
        let cases: [(width: Int, height: Int, pieces: Int, temporary: Int64, free: Int64, limit: ScrollResourceLimit)] = [
            (0, 20, 1, 0, limits.storage.minimumFreeDiskBytes, .invalidDimensions),
            (16, 20, limits.maxPieces + 1, 0, limits.storage.minimumFreeDiskBytes, .pieceLimit),
            (16, limits.maxHeight + 1, 1, 0, limits.storage.minimumFreeDiskBytes, .heightLimit),
            (8_000, 30_000, 1, 0, limits.storage.minimumFreeDiskBytes, .outputPixelBudget),
            (16, 20, 1, limits.storage.temporaryDiskBudgetBytes + 1, limits.storage.minimumFreeDiskBytes, .temporaryDiskBudget),
            (16, 20, 1, 0, limits.storage.minimumFreeDiskBytes - 1, .freeDiskBudget)
        ]
        for test in cases {
            XCTAssertEqual(
                limits.finalizationDecision(
                    width: test.width,
                    projectedHeight: test.height,
                    pieceCount: test.pieces,
                    temporaryBytes: test.temporary,
                    availableDiskBytes: test.free
                ),
                .reject(test.limit)
            )
        }
    }

    func testBothEncodersRejectMissingCorruptAndResizedContributingPieces() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 18), to: first)
        let firstBytes = try Data(contentsOf: first)
        let missing = root.appendingPathComponent("missing.png")
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data("not a PNG".utf8).write(to: corrupt)
        let wrongWidth = root.appendingPathComponent("wrong-width.png")
        try writePNG(try makePatternImage(width: 15, height: 20, seed: 19), to: wrongWidth)
        let wrongHeight = root.appendingPathComponent("wrong-height.png")
        try writePNG(try makePatternImage(width: 16, height: 19, seed: 20), to: wrongHeight)

        for pieceURL in [missing, corrupt, wrongWidth, wrongHeight] {
            let original = try? Data(contentsOf: pieceURL)
            for mode in ArtifactEncoderMode.allCases {
                let destination = root.appendingPathComponent("\(pieceURL.lastPathComponent)-\(mode.rawValue).png")
                XCTAssertThrowsError(try ScrollStitcher.writePNG(
                    pieces: [
                        ScrollStitchPiece(url: first, topY: 0, pixelSize: PixelSize(width: 16, height: 20)),
                        ScrollStitchPiece(url: pieceURL, topY: 10, pixelSize: PixelSize(width: 16, height: 20))
                    ],
                    outputSize: PixelSize(width: 16, height: 30),
                    mode: mode,
                    limits: .default,
                    destination: destination
                )) { error in
                    guard let error = error as? ScrollStitcherError else {
                        return XCTFail("意外错误：\(error)")
                    }
                    if pieceURL == missing || pieceURL == corrupt {
                        guard case .invalidPiece = error else {
                            return XCTFail("缺失/损坏片段必须明确失败：\(error)")
                        }
                    } else {
                        guard case .unsupportedDimensions = error else {
                            return XCTFail("尺寸变化必须明确失败：\(error)")
                        }
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertEqual(try Data(contentsOf: first), firstBytes)
                XCTAssertEqual(try? Data(contentsOf: pieceURL), original)
            }
        }
    }

    func testBothEncodersIgnoreAnUnavailablePieceWithNoOutputContribution() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 21), to: source)
        for mode in ArtifactEncoderMode.allCases {
            let destination = root.appendingPathComponent("empty-contribution-\(mode.rawValue).png")
            _ = try ScrollStitcher.writePNG(
                pieces: [
                    ScrollStitchPiece(url: source, topY: 0, pixelSize: PixelSize(width: 16, height: 20)),
                    ScrollStitchPiece(
                        url: root.appendingPathComponent("not-used.png"),
                        topY: 0,
                        pixelSize: PixelSize(width: 16, height: 20),
                        sourceCropTop: 10,
                        sourceCropBottom: 10
                    )
                ],
                outputSize: PixelSize(width: 16, height: 20),
                mode: mode,
                limits: .default,
                destination: destination
            )
            try assertDecodedSize(of: destination, width: 16, height: 20)
        }
    }

    func testDefaultScrollModeCopyDescribesDirectScrolling() {
        XCTAssertEqual(
            ScrollCaptureMode.automaticFirstManualFallback.label,
            "鼠标滚动（默认）"
        )
        XCTAssertEqual(ScrollCaptureMode.manual.label, "逐段确认（高级）")
    }

    func testInjectedWheelTagSurvivesAppKitEventConversion() throws {
        let injected = try XCTUnwrap(ScrollAutomaticScrollProfile.event(pixelDelta: -12, location: CGPoint(x: 25, y: 35)))
        let observed = try XCTUnwrap(NSEvent(cgEvent: injected))
        let sourceTag = observed.cgEvent?.getIntegerValueField(.eventSourceUserData)
        XCTAssertEqual(sourceTag, ScrollCaptureWheelInputPolicy.injectedEventTag)
        XCTAssertEqual(ScrollCaptureWheelInputPolicy.decision(
            deltaY: observed.scrollingDeltaY,
            gestureEnded: false,
            hasPendingScrollBurst: false,
            eventSourceUserData: sourceTag,
            automaticScrollRunning: true
        ), .ignore)
    }

    func testCaptureTargetFallsBackToLastExternalApplication() {
        XCTAssertEqual(
            CaptureTargetApplicationPolicy.preferredPID(
                frontmostExternalPID: 42,
                lastExternalPID: 21
            ),
            42
        )
        XCTAssertEqual(
            CaptureTargetApplicationPolicy.preferredPID(
                frontmostExternalPID: nil,
                lastExternalPID: 21
            ),
            21
        )
        XCTAssertNil(
            CaptureTargetApplicationPolicy.preferredPID(
                frontmostExternalPID: nil,
                lastExternalPID: nil
            )
        )
    }

    func testFollowModeArmsWithoutASeparateNaturalScrollConfirmation() {
        XCTAssertTrue(
            ScrollCaptureFollowStartPolicy.shouldArmAutomatically(
                captureHasStarted: false,
                captureInFlight: false,
                pieceCount: 1,
                targetApplicationFrontmost: true
            )
        )
        XCTAssertFalse(
            ScrollCaptureFollowStartPolicy.shouldArmAutomatically(
                captureHasStarted: false,
                captureInFlight: false,
                pieceCount: 1,
                targetApplicationFrontmost: false
            )
        )
        XCTAssertFalse(
            ScrollCaptureFollowStartPolicy.shouldArmAutomatically(
                captureHasStarted: true,
                captureInFlight: false,
                pieceCount: 1,
                targetApplicationFrontmost: true
            )
        )
        XCTAssertFalse(
            ScrollCaptureFollowStartPolicy.shouldArmAutomatically(
                captureHasStarted: false,
                captureInFlight: true,
                pieceCount: 1,
                targetApplicationFrontmost: true
            )
        )
    }

    func testScrollGuideStrokeStaysOutsideCaptureRect() {
        let selection = CGRect(x: 120, y: 80, width: 640, height: 360)
        let panels = ScrollCaptureGuideGeometry.panelFrames(around: selection)
        let bounds = panels.reduce(CGRect.null) { $0.union($1) }

        XCTAssertEqual(panels.count, 4)
        XCTAssertTrue(panels.allSatisfy { !$0.intersects(selection) })
        XCTAssertLessThan(bounds.minX, selection.minX)
        XCTAssertGreaterThan(bounds.maxX, selection.maxX)
        XCTAssertLessThan(bounds.minY, selection.minY)
        XCTAssertGreaterThan(bounds.maxY, selection.maxY)
        XCTAssertGreaterThanOrEqual(ScrollCaptureGuideGeometry.captureClearance, 2)
    }

    func testScrollFilterRefreshesOnlyExplicitWindowFallback() {
        XCTAssertFalse(ScrollCaptureFilterRefreshPolicy.requiresLiveUpdate(for: "process"))
        XCTAssertFalse(ScrollCaptureFilterRefreshPolicy.requiresLiveUpdate(for: "bundle"))
        XCTAssertTrue(ScrollCaptureFilterRefreshPolicy.requiresLiveUpdate(for: "windows:4"))
    }

    func testAutomaticScrollProfileKeepsInjectedDistanceAndTargetLocationInSync() {
        let chunk = ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: 720)
        XCTAssertEqual(chunk.logicalDistance, 240)
        XCTAssertEqual(chunk.pixelDeltas, Array(repeating: -12, count: 20))
        XCTAssertLessThan(chunk.logicalDistance * 2, 1440 * 0.35,
                          "The observed 720 CSS/1440px viewport must retain overlap at 2x")
        let location = ScrollAutomaticScrollProfile.eventLocation(
            displayBounds: CGRect(x: -1920, y: 120, width: 1920, height: 1080),
            sourceRect: CGRect(x: 100, y: 220, width: 800, height: 600)
        )
        XCTAssertEqual(location, CGPoint(x: -1420, y: 640))
    }

    func testAutomaticPixelChunksRespectViewportAndEventUnits() throws {
        for height in [CGFloat(4), 32, 200, 720, 20_000] {
            let chunk = ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: height)
            XCTAssertLessThanOrEqual(chunk.logicalDistance, Double(height * 0.35))
            XCTAssertLessThanOrEqual(chunk.logicalDistance, 240)
            XCTAssertTrue(chunk.pixelDeltas.allSatisfy { (-12 ... -1).contains($0) })
            for delta in chunk.pixelDeltas {
                let event = try XCTUnwrap(ScrollAutomaticScrollProfile.event(pixelDelta: delta, location: CGPoint(x: 25, y: 35)))
                XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ScrollCaptureWheelInputPolicy.injectedEventTag,
                               "Injected wheel events must remain distinguishable after mouse takeover")
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1,
                               "The native event must use pixel units rather than accelerated line units")
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(delta))
                XCTAssertEqual(event.location, CGPoint(x: 25, y: 35))
            }
        }
        XCTAssertEqual(ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: 200).pixelDeltas, [-12, -12, -12, -12, -12, -10])
        for height in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertTrue(ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: height).pixelDeltas.isEmpty)
        }
        XCTAssertNil(ScrollAutomaticScrollProfile.event(pixelDelta: -13, location: .zero))
        XCTAssertNil(ScrollAutomaticScrollProfile.event(pixelDelta: 0, location: .zero))
    }

    func testProgrammaticCheckpointPlannerPreservesBoundedChunkEndpointsWithoutSpendingPieceBudget() {
        let signature = ScrollImageSignature(width: 1, height: 1, sourceHeight: 1440, values: [0])
        for count in [1, 9, 12, 37] {
            let frames = (1...count).map {
                ScrollBufferedFrameDescriptor(sequence: UInt64($0), capturedAt: Date(), signature: signature)
            }
            let selected = ScrollFrameCheckpointPlanner.programmaticScrollSequences(from: frames)
            XCTAssertEqual(selected.first, 1)
            XCTAssertEqual(selected.last, UInt64(count))
            XCTAssertEqual(selected.count, min(2, count))
            XCTAssertEqual(selected, selected.sorted())
        }
        let chunk = ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: 720)
        let physicalHeight = 1440
        let chunkCount = 32
        let projectedHeight = physicalHeight + Int(chunk.logicalDistance * 2) * chunkCount
        let conservativePieceCount = 1 + 2 * chunkCount
        XCTAssertGreaterThan(projectedHeight, 16_384)
        XCTAssertLessThan(conservativePieceCount, ScrollCaptureLimits.default.maxPieces)
        guard case .allow = ScrollCaptureLimits.default.finalizationDecision(
            width: 2980, projectedHeight: projectedHeight, pieceCount: conservativePieceCount,
            temporaryBytes: Int64(2980 * physicalHeight * 4 * conservativePieceCount),
            availableDiskBytes: Int64.max
        ) else { return XCTFail("The existing piece/disk/height budget must permit a real >16K automatic long image") }
    }

    func testAutomaticPixelChunkRetainsReliableImageOverlapOnRetinaViewport() throws {
        let logicalHeight: CGFloat = 720
        let pixelScale = 2
        let chunk = ScrollAutomaticScrollProfile.chunk(viewportLogicalHeight: logicalHeight)
        let offset = Int(chunk.logicalDistance) * pixelScale
        let physicalHeight = Int(logicalHeight) * pixelScale
        // The old tiny-test helper produces one-pixel, full-width RGB rows
        // from a linear row generator. At 1440px its long-range aliases can
        // outrank a coarse candidate 4px from the true match. Distinct 16px
        // multi-column blocks retain spatial features at the real matcher
        // sampling scale, like the varied page fixture used on the desktop.
        let previous = try makeTexturedDocumentViewport(width: 320, height: physicalHeight, documentOffset: 0)
        let current = try makeTexturedDocumentViewport(width: 320, height: physicalHeight, documentOffset: offset)
        let registration = try XCTUnwrap(ScrollStitcher.registerVertical(previous: previous, current: current))
        XCTAssertEqual(registration.offset, 480)
        XCTAssertEqual(registration.overlapPixels, physicalHeight - offset)
        XCTAssertTrue(registration.isReliable(viewportHeight: physicalHeight),
                      "A complete native chunk must retain enough real image overlap without relaxing matcher confidence")
    }

    func testChangedAutomaticChunkEntersReviewRegardlessOfWeakMatchDirection() {
        // These are the three weak registrations seen in the real build4
        // trace. The first negative match must pause at the first pair, rather
        // than scrolling twice more until an unreliable positive alias occurs.
        let weakMatches: [ScrollVerticalRegistration?] = [
            ScrollVerticalRegistration(offset: -436, confidence: 0.220249, overlapPixels: 1004,
                                       residual: 58.702212, ambiguityRatio: 1.008171),
            ScrollVerticalRegistration(offset: -744, confidence: 0.183671, overlapPixels: 696,
                                       residual: 68.017194, ambiguityRatio: 1.071740),
            ScrollVerticalRegistration(offset: 356, confidence: 0.404946, overlapPixels: 1084,
                                       residual: 42.244384, ambiguityRatio: 1.133095),
            nil
        ]
        for match in weakMatches {
            XCTAssertEqual(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
                automaticDriverRunning: true, expectedOffsetPixels: 480,
                signatureDelta: 38.705295, registration: match, viewportHeight: 1440
            ), 480, "Only the emitted distance initializes the manual slider; a weak sign never commits or authorizes more input")
            for unchanged in [0.0, 0.8, 1.8] {
                XCTAssertNil(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
                    automaticDriverRunning: true, expectedOffsetPixels: 480,
                    signatureDelta: unchanged, registration: match, viewportHeight: 1440
                ))
            }
            XCTAssertNil(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
                automaticDriverRunning: false, expectedOffsetPixels: 480,
                signatureDelta: 38.705295, registration: match, viewportHeight: 1440
            ), "Direct user-follow/manual paths keep their existing behavior")
        }
        let reliable = ScrollVerticalRegistration(offset: 480, confidence: 0.98,
            overlapPixels: 960, residual: 0, ambiguityRatio: 1.8)
        XCTAssertNil(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
            automaticDriverRunning: true, expectedOffsetPixels: 480,
            signatureDelta: 38, registration: reliable, viewportHeight: 1440
        ))
        XCTAssertNil(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
            automaticDriverRunning: true, expectedOffsetPixels: nil,
            signatureDelta: 38, registration: nil, viewportHeight: 1440
        ))
        XCTAssertEqual(ScrollAutomaticChunkReviewPolicy.suggestedReviewOffset(
            automaticDriverRunning: true, expectedOffsetPixels: 5_000,
            signatureDelta: 38, registration: nil, viewportHeight: 1440
        ), 1440, "The hint is bounded by the existing review slider; it is never a saved offset")
    }

    func testUnchangedAutomaticChunksKeepThreeAttemptBoundaryConfirmation() {
        var progress = ScrollCaptureProgressTracker()
        _ = progress.record(estimatedOffset: 480, focusAvailable: true, automaticMode: true)
        for _ in 0..<2 {
            XCTAssertEqual(progress.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true), .continueCapturing)
        }
        guard case .suggestEndConfirmation = progress.record(
            estimatedOffset: 0, focusAvailable: true, automaticMode: true
        ) else { return XCTFail("An unchanged bottom still requires the existing three-attempt/user-confirmation path") }
    }

    func testCheckpointPlannerPreservesGestureEndpointsWithinBound() {
        let signature = ScrollImageSignature(
            width: 1,
            height: 1,
            sourceHeight: 1,
            values: [0]
        )
        let descriptors = (1...37).map {
            ScrollBufferedFrameDescriptor(
                sequence: UInt64($0),
                capturedAt: Date(),
                signature: signature
            )
        }

        let sequences = ScrollFrameCheckpointPlanner.sequences(
            from: descriptors,
            maximumCount: 10
        )

        XCTAssertEqual(sequences.first, 1)
        XCTAssertEqual(sequences.last, 37)
        XCTAssertEqual(sequences.count, 10)
        XCTAssertEqual(sequences, sequences.sorted())
    }

    func testOverlapGovernorCollapsesSmoothFramesIntoUsefulCheckpoints() {
        let signature = ScrollImageSignature(width: 1, height: 1, sourceHeight: 272, values: [0])
        let descriptors = (1...25).map {
            ScrollBufferedFrameDescriptor(
                sequence: UInt64($0),
                capturedAt: Date(),
                signature: signature
            )
        }

        let sequences = ScrollFrameCheckpointPlanner.continuousGestureSequences(
            from: descriptors,
            estimatedTotalOffsetPixels: 250,
            viewportHeight: 272
        )

        XCTAssertEqual(sequences.count, 4)
        XCTAssertEqual(sequences.last, descriptors.last?.sequence)
    }

    func testSignaturePreservesTopToBottomProviderRowOrder() throws {
        let width = 4
        let height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let value: UInt8 = row < height / 2 ? 24 : 224
            for column in 0..<width {
                let index = (row * width + column) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = 255
            }
        }
        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let signature = try XCTUnwrap(ScrollStitcher.signature(for: image))
        let firstRow = signature.values.prefix(signature.width).map(Int.init).reduce(0, +)
        let lastRow = signature.values.suffix(signature.width).map(Int.init).reduce(0, +)
        XCTAssertLessThan(firstRow, lastRow)
    }

    func testRegistrationFindsPositiveTopLeftOffset() throws {
        let previous = try makeTopDownDocumentViewport(width: 64, height: 60, documentOffset: 0)
        let current = try makeTopDownDocumentViewport(width: 64, height: 60, documentOffset: 15)

        let registration = try XCTUnwrap(
            ScrollStitcher.registerVertical(previous: previous, current: current)
        )

        XCTAssertLessThanOrEqual(abs(registration.offset - 15), 2)
        XCTAssertGreaterThan(registration.confidence, 0.18)
        XCTAssertGreaterThan(registration.overlapPixels, 40)
    }

    func testRegistrationFindsNegativeOffsetWhenViewportMovesUp() throws {
        let previous = try makeTopDownDocumentViewport(width: 64, height: 60, documentOffset: 20)
        let current = try makeTopDownDocumentViewport(width: 64, height: 60, documentOffset: 5)

        let registration = try XCTUnwrap(
            ScrollStitcher.registerVertical(previous: previous, current: current)
        )

        XCTAssertLessThanOrEqual(abs(registration.offset + 15), 2)
        XCTAssertGreaterThan(registration.confidence, 0.18)
        XCTAssertGreaterThan(registration.overlapPixels, 40)
    }

    func testFineRegistrationResolvesRealisticOffsetToSinglePixel() throws {
        let previous = try makeTopDownDocumentViewport(width: 320, height: 272, documentOffset: 0)
        let current = try makeTopDownDocumentViewport(width: 320, height: 272, documentOffset: 122)

        let registration = try XCTUnwrap(
            ScrollStitcher.registerVertical(previous: previous, current: current)
        )

        XCTAssertEqual(registration.offset, 122)
        XCTAssertTrue(registration.isReliable(viewportHeight: 272))
        XCTAssertGreaterThanOrEqual(registration.ambiguityRatio, 1.06)
    }

    func testRegistrationRejectsGestureThatLeavesTooLittleOverlap() throws {
        let previous = try makeTopDownDocumentViewport(width: 320, height: 272, documentOffset: 0)
        let current = try makeTopDownDocumentViewport(width: 320, height: 272, documentOffset: 250)

        let registration = ScrollStitcher.registerVertical(previous: previous, current: current)

        XCTAssertFalse(registration?.isReliable(viewportHeight: 272) ?? false)
    }

    func testRegistrationRejectsAmbiguousRepeatedRows() throws {
        let previous = try makePeriodicDocumentViewport(
            width: 240,
            height: 180,
            documentOffset: 0,
            period: 20
        )
        let current = try makePeriodicDocumentViewport(
            width: 240,
            height: 180,
            documentOffset: 15,
            period: 20
        )

        let registration = ScrollStitcher.registerVertical(previous: previous, current: current)

        XCTAssertFalse(registration?.isReliable(viewportHeight: 180) ?? false)
    }

    func testRegistrationRejectsFlatViewport() throws {
        let previous = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let registration = try XCTUnwrap(
            ScrollStitcher.registerVertical(previous: previous, current: previous)
        )

        XCTAssertEqual(registration.offset, 0)
        XCTAssertEqual(registration.confidence, 0)
    }

    func testSolveTopPositionsUsesLateHighConfidenceAnchor() {
        let positions = ScrollStitcher.solveTopPositions(
            pieceCount: 3,
            edges: [
                ScrollRegistrationEdge(fromIndex: 0, toIndex: 1, offset: 100, confidence: 0.45, overlapPixels: 20),
                ScrollRegistrationEdge(fromIndex: 1, toIndex: 2, offset: 100, confidence: 0.45, overlapPixels: 20),
                ScrollRegistrationEdge(fromIndex: 0, toIndex: 2, offset: 198, confidence: 0.95, overlapPixels: 40)
            ]
        )

        XCTAssertEqual(positions[0], 0)
        XCTAssertEqual(positions[1], 100)
        XCTAssertLessThanOrEqual(abs(positions[2] - 198), 3)
    }

    func testAdjacentRegistrationLedgerKeepsExactIntegerOffsets() {
        let positions = ScrollStitcher.solveTopPositions(
            pieceCount: 4,
            edges: [
                ScrollRegistrationEdge(fromIndex: 0, toIndex: 1, offset: 122, confidence: 0.8, overlapPixels: 150),
                ScrollRegistrationEdge(fromIndex: 1, toIndex: 2, offset: 62, confidence: 0.8, overlapPixels: 210),
                ScrollRegistrationEdge(fromIndex: 2, toIndex: 3, offset: 145, confidence: 0.8, overlapPixels: 127)
            ]
        )

        XCTAssertEqual(positions, [0, 122, 184, 329])
    }

    func testFullBitmapStitchProducesDecodableCombinedPNG() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 1), to: firstURL)
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 2), to: secondURL)

        let destination = root.appendingPathComponent("combined.png")
        let actualMode = try ScrollStitcher.writePNG(
            pieces: [
                ScrollStitchPiece(url: firstURL, topY: 0, pixelSize: PixelSize(width: 16, height: 20)),
                ScrollStitchPiece(url: secondURL, topY: 10, pixelSize: PixelSize(width: 16, height: 20))
            ],
            outputSize: PixelSize(width: 16, height: 30),
            mode: .fullBitmap,
            limits: .default,
            destination: destination
        )

        XCTAssertEqual(actualMode, .fullBitmap)
        try assertDecodedSize(of: destination, width: 16, height: 30)
    }

    func testStripedStitchProducesDecodablePNG() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 3), to: firstURL)
        try writePNG(try makePatternImage(width: 16, height: 20, seed: 4), to: secondURL)

        let limits = ScrollCaptureLimits(
            maxPieces: 100,
            maxHeight: 30_000,
            maxDuration: 120,
            storage: ArtifactStorageLimits(
                maxOutputPixelCount: 200_000_000,
                maxFullBitmapPixelCount: 10,
                decodedBudgetBytes: 512 * 1_024 * 1_024,
                temporaryDiskBudgetBytes: 2 * 1_024 * 1_024 * 1_024,
                minimumFreeDiskBytes: 1
            ),
            stripeHeight: 8
        )
        let destination = root.appendingPathComponent("combined-striped.png")
        let actualMode = try ScrollStitcher.writePNG(
            pieces: [
                ScrollStitchPiece(url: firstURL, topY: 0, pixelSize: PixelSize(width: 16, height: 20)),
                ScrollStitchPiece(url: secondURL, topY: 10, pixelSize: PixelSize(width: 16, height: 20))
            ],
            outputSize: PixelSize(width: 16, height: 30),
            mode: .striped,
            limits: limits,
            destination: destination
        )

        XCTAssertEqual(actualMode, .striped)
        try assertDecodedSize(of: destination, width: 16, height: 30)
    }

    func testSinglePieceFullBitmapPreservesVisualOrientation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("combined.png")
        let source = try makePatternImage(width: 16, height: 20, seed: 7)
        try writePNG(source, to: sourceURL)

        _ = try ScrollStitcher.writePNG(
            pieces: [ScrollStitchPiece(url: sourceURL, topY: 0, pixelSize: PixelSize(width: 16, height: 20))],
            outputSize: PixelSize(width: 16, height: 20),
            mode: .fullBitmap,
            limits: .default,
            destination: destination
        )
        let combined = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(source), normalizedPixels(combined))
    }

    func testSinglePieceStripedPreservesVisualOrientation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("combined-striped.png")
        let source = try makePatternImage(width: 16, height: 20, seed: 8)
        try writePNG(source, to: sourceURL)
        let limits = ScrollCaptureLimits(
            maxPieces: 100,
            maxHeight: 30_000,
            maxDuration: 120,
            storage: ArtifactStorageLimits(
                maxOutputPixelCount: 200_000_000,
                maxFullBitmapPixelCount: 1,
                decodedBudgetBytes: 512 * 1_024 * 1_024,
                temporaryDiskBudgetBytes: 2 * 1_024 * 1_024 * 1_024,
                minimumFreeDiskBytes: 1
            ),
            stripeHeight: 8
        )

        _ = try ScrollStitcher.writePNG(
            pieces: [ScrollStitchPiece(url: sourceURL, topY: 0, pixelSize: PixelSize(width: 16, height: 20))],
            outputSize: PixelSize(width: 16, height: 20),
            mode: .striped,
            limits: limits,
            destination: destination
        )
        let combined = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(source), normalizedPixels(combined))
    }

    func testStitchUsesTopLeftPieceCoordinatesForFullAndStripedModes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        let first = try makePatternImage(width: 16, height: 20, seed: 1)
        let second = try makePatternImage(width: 16, height: 20, seed: 2)
        try writePNG(first, to: firstURL)
        try writePNG(second, to: secondURL)
        let pieces = [
            ScrollStitchPiece(url: firstURL, topY: 0, pixelSize: PixelSize(width: 16, height: 20)),
            ScrollStitchPiece(url: secondURL, topY: 10, pixelSize: PixelSize(width: 16, height: 20))
        ]
        let expected = expectedOverlay(first: first, second: second, secondTopY: 10, height: 30)

        let fullDestination = root.appendingPathComponent("full.png")
        _ = try ScrollStitcher.writePNG(
            pieces: pieces,
            outputSize: PixelSize(width: 16, height: 30),
            mode: .fullBitmap,
            limits: .default,
            destination: fullDestination
        )
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(fullDestination as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(full), expected)

        let stripedDestination = root.appendingPathComponent("striped.png")
        let limits = ScrollCaptureLimits(
            maxPieces: 100,
            maxHeight: 30_000,
            maxDuration: 120,
            storage: ArtifactStorageLimits(
                maxOutputPixelCount: 200_000_000,
                maxFullBitmapPixelCount: 1,
                decodedBudgetBytes: 512 * 1_024 * 1_024,
                temporaryDiskBudgetBytes: 2 * 1_024 * 1_024 * 1_024,
                minimumFreeDiskBytes: 1
            ),
            stripeHeight: 8
        )
        _ = try ScrollStitcher.writePNG(
            pieces: pieces,
            outputSize: PixelSize(width: 16, height: 30),
            mode: .striped,
            limits: limits,
            destination: stripedDestination
        )
        let striped = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(stripedDestination as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(striped), expected)
    }

    func testSeamCroppedCompositionReconstructsDocumentWithoutOverlay() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        let first = try makeTopDownDocumentViewport(width: 96, height: 80, documentOffset: 0)
        let second = try makeTopDownDocumentViewport(width: 96, height: 80, documentOffset: 30)
        let expected = try makeTopDownDocumentViewport(width: 96, height: 110, documentOffset: 0)
        try writePNG(first, to: firstURL)
        try writePNG(second, to: secondURL)
        let seam = try XCTUnwrap(
            ScrollStitcher.chooseSeam(previous: first, current: second, offset: 30)
        )
        XCTAssertEqual(seam.previousCropBottom - seam.currentCropTop, 30)
        let pieces = [
            ScrollStitchPiece(
                url: firstURL,
                topY: 0,
                pixelSize: PixelSize(width: 96, height: 80),
                sourceCropBottom: seam.previousCropBottom
            ),
            ScrollStitchPiece(
                url: secondURL,
                topY: 30,
                pixelSize: PixelSize(width: 96, height: 80),
                sourceCropTop: seam.currentCropTop
            )
        ]

        let fullURL = root.appendingPathComponent("full.png")
        _ = try ScrollStitcher.writePNG(
            pieces: pieces,
            outputSize: PixelSize(width: 96, height: 110),
            mode: .fullBitmap,
            limits: .default,
            destination: fullURL
        )
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(fullURL as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(full), normalizedPixels(expected))

        let stripedURL = root.appendingPathComponent("striped.png")
        let limits = ScrollCaptureLimits(
            maxPieces: 100,
            maxHeight: 30_000,
            maxDuration: 120,
            storage: ArtifactStorageLimits(
                maxOutputPixelCount: 200_000_000,
                maxFullBitmapPixelCount: 1,
                decodedBudgetBytes: 512 * 1_024 * 1_024,
                temporaryDiskBudgetBytes: 2 * 1_024 * 1_024 * 1_024,
                minimumFreeDiskBytes: 1
            ),
            stripeHeight: 17
        )
        _ = try ScrollStitcher.writePNG(
            pieces: pieces,
            outputSize: PixelSize(width: 96, height: 110),
            mode: .striped,
            limits: limits,
            destination: stripedURL
        )
        let striped = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(stripedURL as CFURL, nil)),
            0,
            nil
        ))
        XCTAssertEqual(normalizedPixels(striped), normalizedPixels(expected))
    }

    func testLivePreviewIsBoundedAndDecodable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        try writePNG(try makePatternImage(width: 64, height: 80, seed: 4), to: firstURL)
        try writePNG(try makePatternImage(width: 64, height: 80, seed: 5), to: secondURL)
        let destination = root.appendingPathComponent("preview.png")

        let size = try ScrollStitcher.writePreviewPNG(
            pieces: [
                ScrollStitchPiece(url: firstURL, topY: 0, pixelSize: PixelSize(width: 64, height: 80)),
                ScrollStitchPiece(url: secondURL, topY: 60, pixelSize: PixelSize(width: 64, height: 80))
            ],
            outputSize: PixelSize(width: 64, height: 140),
            maximumWidth: 24,
            maximumHeight: 32,
            destination: destination
        )

        XCTAssertLessThanOrEqual(size.width, 24)
        XCTAssertLessThanOrEqual(size.height, 32)
        try assertDecodedSize(of: destination, width: size.width, height: size.height)
    }

    private func assertDecodedSize(of url: URL, width: Int, height: Int) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }

    private func makePatternImage(width: Int, height: Int, seed: UInt8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for row in 0..<height {
            let value = CGFloat((Int(seed) * 23 + row * 11) % 255) / 255
            context.setFillColor(CGColor(red: value, green: 1 - value, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTexturedDocumentViewport(width: Int, height: Int, documentOffset: Int) throws -> CGImage {
        var bytes = Data(repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                var state = UInt64((row + documentOffset) / 16) &* 0x9E3779B97F4A7C15
                state ^= UInt64(column / 16 + 1) &* 0xBF58476D1CE4E5B9
                state = (state ^ (state >> 30)) &* 0xBF58476D1CE4E5B9
                state = (state ^ (state >> 27)) &* 0x94D049BB133111EB
                let value = UInt8(truncatingIfNeeded: state ^ (state >> 31))
                let index = (row * width + column) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func makeTopDownDocumentViewport(
        width: Int,
        height: Int,
        documentOffset: Int
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let documentRow = row + documentOffset
            var state = UInt64(documentRow + 1)
            state = state &* 2_862_933_555_777_941_757 &+ 3_039_700_493
            let red = UInt8(state % 251)
            let green = UInt8((state >> 8) % 251)
            let blue = UInt8((state >> 16) % 251)
            for column in 0..<width {
                let index = (row * width + column) * 4
                pixels[index] = red
                pixels[index + 1] = green
                pixels[index + 2] = blue
                pixels[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makePeriodicDocumentViewport(
        width: Int,
        height: Int,
        documentOffset: Int,
        period: Int
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let phase = (row + documentOffset) % period
            for column in 0..<width {
                let index = (row * width + column) * 4
                let stripe = (column / 7 + phase / 3) % 2
                let value: UInt8 = stripe == 0 ? UInt8(40 + phase * 4) : UInt8(210 - phase * 3)
                pixels[index] = value
                pixels[index + 1] = UInt8((Int(value) + phase * 5) % 255)
                pixels[index + 2] = UInt8((Int(value) + column) % 255)
                pixels[index + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorScrollStitcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func normalizedPixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func expectedOverlay(first: CGImage, second: CGImage, secondTopY: Int, height: Int) -> [UInt8] {
        let firstPixels = normalizedPixels(first)
        let secondPixels = normalizedPixels(second)
        let rowBytes = first.width * 4
        var output = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            let source = row >= secondTopY ? secondPixels : firstPixels
            let sourceRow = row >= secondTopY ? row - secondTopY : row
            output.replaceSubrange(
                (row * rowBytes)..<((row + 1) * rowBytes),
                with: source[(sourceRow * rowBytes)..<((sourceRow + 1) * rowBytes)]
            )
        }
        return output
    }
}
