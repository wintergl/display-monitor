import DisplayMonitorCore
import Foundation
import XCTest

final class ArtifactStoreTests: XCTestCase {
    func testRecordingPreparedArtifactPromotesToCapturingExactlyOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let operationID = UUID()

        let session = try await store.beginPreparedArtifact(
            dimensions: PixelSize(width: 640, height: 360),
            displayID: 7,
            operationID: operationID
        )
        XCTAssertEqual(session.manifest.status, .preparing)
        XCTAssertEqual(session.manifest.commitSequence, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.lockToken.lockURL.path))

        let capturing = try await store.markCapturing(for: session)
        XCTAssertEqual(capturing.status, .capturing)
        XCTAssertEqual(capturing.commitSequence, 1)

        let repeated = try await store.markCapturing(for: session)
        XCTAssertEqual(repeated.status, .capturing)
        XCTAssertEqual(repeated.commitSequence, capturing.commitSequence)
    }

    func testStoragePreflightDoesNotCreateArtifactIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)

        try await store.preflightWriteAvailability(minimumFreeBytes: 0)

        let artifacts = try await store.artifacts(includeDiscarded: true)
        XCTAssertTrue(artifacts.isEmpty)
        let visibleEntries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertTrue(visibleEntries.isEmpty)
    }

    func testAllFinalizationFaultPointsRecoverWithoutDuplicateCommit() async throws {
        let cases: [(ArtifactFinalizationFault, ArtifactCommitPhase, ArtifactStatus)] = [
            (.afterFinalizingPersisted, .writingTemporary, .recoveredPartial),
            (.afterValidatedPersistedBeforeRename, .validated, .completed),
            (.afterRenameBeforeManifest, .validated, .completed),
            (.afterRenamedPersistedBeforeTerminal, .renamed, .completed),
            (.afterManifestCommittedControl, .manifestCommitted, .completed)
        ]

        for (fault, expectedPhaseBeforeRecovery, expectedStatus) in cases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ArtifactStore(
                rootURL: root,
                validator: { url, _ in
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
                },
                livenessProbe: { _ in .dead },
                staleLockInterval: 0
            )
            let session = try await store.beginArtifact(kind: .recording, fileExtension: "mp4")
            _ = try await store.writeTemporaryData(Data("recording-\(fault)".utf8), for: session)

            do {
                _ = try await store.finalizeTemporary(for: session, fault: fault)
                XCTFail("Expected injected finalization fault: \(fault)")
            } catch ArtifactStoreError.injectedFinalizationFault {
                // Expected.
            }

            let beforeRecovery = try await store.artifact(id: session.manifest.id)
            XCTAssertEqual(beforeRecovery.commitPhase, expectedPhaseBeforeRecovery)

            // Ensure the heartbeat is older than a zero-second stale threshold.
            try await Task.sleep(nanoseconds: 2_000_000)
            let recoveryResults = try await store.recoverAll()
            let result = try XCTUnwrap(
                recoveryResults.first { $0.manifest.id == session.manifest.id }
            )
            XCTAssertEqual(result.manifest.status, expectedStatus)
            XCTAssertEqual(result.manifest.commitPhase, .manifestCommitted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.lockToken.lockURL.path))
            let recoveredLockArchives = try FileManager.default.contentsOfDirectory(
                at: result.manifest.directoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".artifact.lock.recovered-") }
            XCTAssertTrue(recoveredLockArchives.isEmpty)
            if fault == .afterManifestCommittedControl {
                XCTAssertEqual(result.manifest.commitSequence, beforeRecovery.commitSequence)
            }
        }
    }

    func testCanonicalArtifactCompletesBeforeDesktopCompatibilityCopy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)

        let session = try await store.beginArtifact(kind: .still, fileExtension: "png")
        let completed = try await store.finalizeData(Data("png-content".utf8), for: session)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.commitPhase, .manifestCommitted)
        XCTAssertEqual(completed.commitSequence, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.temporaryURL.path))
        XCTAssertNil(completed.desktopExportURL)

        let desktopCopy = root.appendingPathComponent("desktop-copy.png")
        try FileManager.default.copyItem(at: completed.canonicalURL, to: desktopCopy)
        let updated = try await store.setDesktopExportURL(desktopCopy, for: completed.id)
        XCTAssertEqual(updated.desktopExportURL, desktopCopy)
        XCTAssertEqual(updated.canonicalURL, completed.canonicalURL)
    }

    func testCanonicalFirstRecoveryAfterRenameBeforeManifestCrash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let liveness: ArtifactLivenessProbe = { _ in .dead }
        let store = ArtifactStore(rootURL: root, livenessProbe: liveness, staleLockInterval: 0)
        let session = try await store.beginArtifact(kind: .still, fileExtension: "png")

        do {
            _ = try await store.finalizeData(
                Data("durable-image".utf8),
                for: session,
                fault: .afterRenameBeforeManifest
            )
            XCTFail("Expected injected fault")
        } catch let error as ArtifactStoreError {
            guard case .injectedFinalizationFault = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let beforeRecovery = try await store.artifact(id: session.manifest.id)
        XCTAssertEqual(beforeRecovery.commitPhase, .validated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeRecovery.canonicalURL.path))

        let staleLock = ArtifactLockRecord(
            activeOperationID: session.lockToken.operationID,
            processUUID: UUID(),
            pid: 999_999,
            processStartToken: "dead",
            acquiredAt: Date(timeIntervalSinceNow: -60),
            heartbeatAt: Date(timeIntervalSinceNow: -60)
        )
        try write(staleLock, to: session.lockToken.lockURL)

        let restartedStore = ArtifactStore(rootURL: root, livenessProbe: liveness, staleLockInterval: 0)
        let outcomes = try await restartedStore.recoverAll()
        let recovered = try XCTUnwrap(outcomes.first { $0.manifest.id == session.manifest.id })

        XCTAssertEqual(recovered.disposition, .recoveredCompleted)
        XCTAssertEqual(recovered.manifest.status, .completed)
        XCTAssertEqual(recovered.manifest.commitPhase, .manifestCommitted)
        XCTAssertNotEqual(recovered.manifest.activeOperationID, recovered.manifest.originOperationID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.manifest.canonicalURL.path))
    }

    func testDerivedArtifactDoesNotOverwriteSourceAndDiscardLeavesChild() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)

        let sourceSession = try await store.beginArtifact(kind: .still, fileExtension: "png")
        let source = try await store.finalizeData(Data("source".utf8), for: sourceSession)
        let revisionSession = try await store.beginArtifact(
            kind: .revision,
            fileExtension: "png",
            sourceArtifactID: source.id
        )
        let revision = try await store.finalizeData(Data("revision".utf8), for: revisionSession)

        XCTAssertEqual(try Data(contentsOf: source.canonicalURL), Data("source".utf8))
        XCTAssertEqual(revision.sourceArtifactID, source.id)
        XCTAssertNotEqual(revision.id, source.id)

        let discarded = try await store.discard(id: source.id)
        XCTAssertEqual(discarded.status, .discarded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: revision.canonicalURL.path))
        let children = try await store.childArtifacts(of: source.id)
        XCTAssertEqual(children.map(\.id), [revision.id])
    }

    func testStrictInputLeaseRejectsSameOwnerAndStaleToken() {
        var registry = InputLeaseRegistry()
        let operation = UUID()
        let token = registry.acquire(owner: .stillCaptureSelection, operationID: operation)
        XCTAssertNotNil(token)
        XCTAssertNil(registry.acquire(owner: .stillCaptureSelection, operationID: UUID()))

        let stale = InputLeaseToken(
            owner: .stillCaptureSelection,
            operationID: operation,
            nonce: UUID()
        )
        XCTAssertFalse(registry.release(stale))
        XCTAssertEqual(registry.activeLease?.token, token)
        XCTAssertTrue(registry.release(try! XCTUnwrap(token)))
        XCTAssertNil(registry.activeLease)
    }

    func testInputLeaseTransferIsAtomicAndInvalidatesPreviousToken() throws {
        var registry = InputLeaseRegistry()
        let operation = UUID()
        let selection = try XCTUnwrap(
            registry.acquire(owner: .captureWorkflow, operationID: operation)
        )
        let scroll = try XCTUnwrap(registry.transfer(selection, to: .scrollCapture))

        XCTAssertEqual(scroll.operationID, operation)
        XCTAssertEqual(scroll.owner, .scrollCapture)
        XCTAssertNotEqual(scroll.nonce, selection.nonce)
        XCTAssertFalse(registry.release(selection))
        XCTAssertEqual(registry.activeLease?.token, scroll)
        XCTAssertTrue(registry.release(scroll))
    }

    func testScrollSessionStateMachineRejectsLateFrameStates() {
        var machine = ScrollCaptureSessionStateMachine()
        XCTAssertTrue(machine.handle(.start))
        XCTAssertEqual(machine.phase, .preparing)
        XCTAssertTrue(machine.handle(.readyFollow))
        XCTAssertTrue(machine.phase.acceptsFrames)
        XCTAssertTrue(machine.handle(.fallbackToManual))
        XCTAssertEqual(machine.phase, .manual)
        XCTAssertTrue(machine.handle(.reviewSeam))
        XCTAssertFalse(machine.phase.acceptsFrames)
        XCTAssertTrue(machine.handle(.resumeManual))
        XCTAssertTrue(machine.handle(.beginFinalizing))
        XCTAssertFalse(machine.phase.acceptsFrames)
        XCTAssertFalse(machine.handle(.readyFollow))
        XCTAssertTrue(machine.handle(.reset))
        XCTAssertEqual(machine.phase, .idle)

        var followReview = ScrollCaptureSessionStateMachine()
        XCTAssertTrue(followReview.handle(.start))
        XCTAssertTrue(followReview.handle(.readyFollow))
        XCTAssertTrue(followReview.handle(.reviewSeam))
        XCTAssertEqual(followReview.phase, .reviewingSeam)
        XCTAssertTrue(followReview.handle(.resumeFollow))
        XCTAssertEqual(followReview.phase, .following)
    }

    func testDiscardingActiveSessionReleasesItsOperationLock() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let session = try await store.beginArtifact(kind: .scrollStill, fileExtension: "png")

        let discarded = try await store.discard(for: session)
        let visibleArtifacts = try await store.artifacts()

        XCTAssertEqual(discarded.status, .discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.lockToken.lockURL.path))
        XCTAssertFalse(visibleArtifacts.contains { $0.id == discarded.id })
    }

    func testScrollLimitsAndProgressDoNotTreatInitialNoMovementAsEnd() {
        let limits = ScrollCaptureLimits.default
        XCTAssertEqual(
            limits.decision(
                width: 6_144,
                projectedHeight: 30_000,
                pieceCount: 10,
                elapsed: 5,
                temporaryBytes: 100,
                availableDiskBytes: limits.storage.minimumFreeDiskBytes
            ),
            .allow(mode: .striped, outputPixelCount: 184_320_000)
        )
        XCTAssertEqual(
            limits.decision(
                width: 8_000,
                projectedHeight: 30_000,
                pieceCount: 10,
                elapsed: 5,
                temporaryBytes: 100,
                availableDiskBytes: limits.storage.minimumFreeDiskBytes
            ),
            .reject(.outputPixelBudget)
        )

        var tracker = ScrollCaptureProgressTracker()
        XCTAssertEqual(
            tracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .continueCapturing
        )
        XCTAssertEqual(
            tracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .continueCapturing
        )
        XCTAssertEqual(
            tracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .needsStartReposition(reason: "scroll_no_movement_unconfirmed")
        )
        XCTAssertEqual(
            tracker.record(estimatedOffset: 120, focusAvailable: true, automaticMode: true),
            .continueCapturing
        )
        XCTAssertEqual(
            tracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .continueCapturing
        )
        XCTAssertEqual(
            tracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .continueCapturing
        )
        XCTAssertEqual(
            tracker.record(
                estimatedOffset: 0,
                focusAvailable: true,
                automaticMode: true,
                endBoundaryConfirmed: true
            ),
            .endConfirmed
        )

        var unconfirmedTracker = ScrollCaptureProgressTracker()
        _ = unconfirmedTracker.record(estimatedOffset: 60, focusAvailable: true, automaticMode: true)
        _ = unconfirmedTracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true)
        _ = unconfirmedTracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true)
        XCTAssertEqual(
            unconfirmedTracker.record(estimatedOffset: 0, focusAvailable: true, automaticMode: true),
            .suggestEndConfirmation(reason: "scroll_end_unconfirmed")
        )
    }

    func testRecordingTimingFailsOnlyAfterMoreThanThirtyConsecutiveDrops() {
        var policy = RecordingTimingPolicy()
        XCTAssertEqual(policy.consume(presentationTime: 10, writerReady: true), .append(normalizedPresentationTime: 0))
        XCTAssertEqual(policy.consume(presentationTime: 10, writerReady: true), .discardInvalidTimestamp)
        for index in 1...30 {
            XCTAssertEqual(
                policy.consume(presentationTime: 11 + Double(index), writerReady: false),
                .dropBackpressure(consecutive: index)
            )
        }
        XCTAssertEqual(
            policy.consume(presentationTime: 99, writerReady: false),
            .failBackpressure(consecutive: 31)
        )
    }

    func testScrollUserCompletionRequiresAStitchedSecondViewport() {
        XCTAssertEqual(
            ScrollCaptureUserCompletionPolicy.decision(
                captureHasStarted: false,
                pieceCount: 1
            ),
            .requireStitchedMovement
        )
        XCTAssertEqual(
            ScrollCaptureUserCompletionPolicy.decision(
                captureHasStarted: true,
                pieceCount: 1
            ),
            .requireStitchedMovement
        )
        XCTAssertEqual(
            ScrollCaptureUserCompletionPolicy.decision(
                captureHasStarted: true,
                pieceCount: 2
            ),
            .finalize
        )
    }

    func testReverseScrollAlwaysRedefinesTheInitialSection() {
        XCTAssertEqual(
            ScrollCaptureDirectionPolicy.decision(
                registeredOffset: -120,
                registrationReliable: true,
                pieceCount: 1
            ),
            .redefineInitialSection(discardedPieceCount: 0)
        )
        XCTAssertEqual(
            ScrollCaptureDirectionPolicy.decision(
                registeredOffset: -120,
                registrationReliable: true,
                pieceCount: 5
            ),
            .redefineInitialSection(discardedPieceCount: 4)
        )
        XCTAssertEqual(
            ScrollCaptureDirectionPolicy.decision(
                registeredOffset: 0,
                registrationReliable: true,
                pieceCount: 5
            ),
            .unchanged
        )
        XCTAssertEqual(
            ScrollCaptureDirectionPolicy.decision(
                registeredOffset: 120,
                registrationReliable: true,
                pieceCount: 5
            ),
            .appendForward
        )
        XCTAssertEqual(
            ScrollCaptureDirectionPolicy.decision(
                registeredOffset: -120,
                registrationReliable: false,
                pieceCount: 5
            ),
            .unchanged
        )
    }

    func testScrollLedgerAndPartialFinalizationRemainCanonical() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            selectionRect: CGRect(x: 10, y: 20, width: 200, height: 100),
            pixelScale: 2
        )
        let session = try await store.beginArtifact(
            kind: .scrollStill,
            fileExtension: "png",
            dimensions: PixelSize(width: 400, height: 200),
            displayID: 7,
            captureRegion: region,
            limits: .scrollDefault,
            operationID: UUID()
        )
        let piece = ScrollCapturePiece(
            relativeURL: "pieces/0001.png",
            sourceRect: region,
            displayID: 7,
            pixelSize: PixelSize(width: 400, height: 200),
            estimatedOffset: nil,
            confirmedOffset: nil,
            topY: 0,
            sourceCropTop: 12,
            sourceCropBottom: 188,
            registrationResidual: 1.25,
            registrationAmbiguityRatio: 1.42
        )
        _ = try await store.updateScrollCaptureMetadata(
            for: session,
            mode: .manual,
            endReason: .resourceLimit,
            failureReason: "scroll_resource_limit",
            pieces: [piece],
            outputSize: PixelSize(width: 400, height: 200),
            outputPixelCount: 80_000,
            encoderMode: .fullBitmap
        )
        _ = try await store.writeTemporaryData(Data("partial-scroll".utf8), for: session)
        let partial = try await store.finalizeTemporary(
            for: session,
            terminalStatus: .partial,
            terminalError: CaptureError(code: "scroll_resource_limit", message: "资源限制")
        )

        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.scrollCaptureMode, .manual)
        XCTAssertEqual(partial.scrollEndReason, .resourceLimit)
        let savedPiece = try XCTUnwrap(partial.scrollPieces?.first)
        XCTAssertEqual(savedPiece.relativeURL, piece.relativeURL)
        XCTAssertEqual(savedPiece.sourceRect, piece.sourceRect)
        XCTAssertEqual(savedPiece.displayID, piece.displayID)
        XCTAssertEqual(savedPiece.pixelSize, piece.pixelSize)
        XCTAssertEqual(savedPiece.topY, piece.topY)
        XCTAssertEqual(savedPiece.sourceCropTop, 12)
        XCTAssertEqual(savedPiece.sourceCropBottom, 188)
        XCTAssertEqual(savedPiece.registrationResidual, 1.25)
        XCTAssertEqual(savedPiece.registrationAmbiguityRatio, 1.42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.temporaryURL.path))
    }

    func testScrollPreviewPublishesSeparateAtomicFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArtifactStore(rootURL: root)
        let session = try await store.beginArtifact(
            kind: .scrollStill,
            fileExtension: "png",
            dimensions: PixelSize(width: 20, height: 10),
            limits: .scrollDefault
        )
        let previewStaging = session.manifest.directoryURL.appendingPathComponent(".preview-test.png")
        try Data("preview".utf8).write(to: previewStaging)

        let updated = try await store.commitScrollPreview(
            from: previewStaging,
            for: session,
            dimensions: PixelSize(width: 20, height: 30),
            outputPixelCount: 600,
            encoderMode: .fullBitmap
        )

        XCTAssertEqual(updated.previewURL?.lastPathComponent, "preview.png")
        XCTAssertEqual(updated.dimensions, PixelSize(width: 20, height: 30))
        XCTAssertEqual(updated.outputPixelCount, 600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.previewURL!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: updated.canonicalURL.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorArtifactStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ record: ArtifactLockRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}
