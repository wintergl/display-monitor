import Foundation

public enum ScrollCaptureMode: String, Codable, CaseIterable, Hashable, Sendable {
    case automaticFirstManualFallback
    case manual

    public var label: String {
        switch self {
        case .automaticFirstManualFallback: return "鼠标滚动（默认）"
        case .manual: return "逐段确认（高级）"
        }
    }
}

/// Deterministic orchestration state for one scroll-capture operation. Keeping
/// this state outside AppKit makes cancellation, fallback, and finalization
/// ordering independently testable.
public enum ScrollCaptureSessionPhase: String, Equatable, Sendable {
    case idle
    case preparing
    case following
    case manual
    case reviewingSeam
    case finalizing

    public var isBusy: Bool { self != .idle }

    public var acceptsFrames: Bool {
        self == .following || self == .manual
    }
}

public enum ScrollCaptureSessionEvent: Equatable, Sendable {
    case start
    case readyFollow
    case readyManual
    case fallbackToManual
    case reviewSeam
    case resumeFollow
    case resumeManual
    case beginFinalizing
    case reset
}

public struct ScrollCaptureSessionStateMachine: Equatable, Sendable {
    public private(set) var phase: ScrollCaptureSessionPhase = .idle

    public init() {}

    @discardableResult
    public mutating func handle(_ event: ScrollCaptureSessionEvent) -> Bool {
        let next: ScrollCaptureSessionPhase?
        switch (phase, event) {
        case (.idle, .start):
            next = .preparing
        case (.preparing, .readyFollow):
            next = .following
        case (.preparing, .readyManual):
            next = .manual
        case (.following, .fallbackToManual), (.reviewingSeam, .fallbackToManual):
            next = .manual
        case (.manual, .reviewSeam), (.following, .reviewSeam):
            next = .reviewingSeam
        case (.reviewingSeam, .resumeFollow):
            next = .following
        case (.reviewingSeam, .resumeManual):
            next = .manual
        case (.preparing, .beginFinalizing),
             (.following, .beginFinalizing),
             (.manual, .beginFinalizing),
             (.reviewingSeam, .beginFinalizing):
            next = .finalizing
        case (_, .reset):
            next = .idle
        default:
            next = nil
        }
        guard let next else { return false }
        phase = next
        return true
    }
}

/// Terminal reason recorded for a scroll artifact. The reason deliberately
/// distinguishes a verified end from an operator decision or an automatic
/// failure followed by a successful manual completion.
public enum ScrollCaptureEndReason: String, Codable, CaseIterable, Sendable {
    case endConfirmed
    case endConfirmedByUser
    case userStopped
    case scrollFailedManualCompleted
    case resourceLimit
    case cancelled
}

/// Manifest-side description of one persisted viewport fragment. `relativeURL`
/// is relative to the artifact directory so a canonical artifact can move as a
/// unit without embedding a second absolute source of truth.
public struct ScrollCapturePiece: Codable, Equatable, Sendable {
    public var relativeURL: String
    public var capturedAt: Date
    public var sourceRect: CaptureRegion
    public var displayID: UInt32
    public var pixelSize: PixelSize
    public var estimatedOffset: Int?
    public var confirmedOffset: Int?
    public var topY: Int
    /// Registration evidence is optional so manifests written by older
    /// versions remain readable. It records which earlier viewport anchored
    /// this piece and how strong the image match was.
    public var registrationConfidence: Double?
    public var registrationOverlap: Int?
    public var registrationAnchorIndex: Int?
    /// Source-row contribution retained by the seam composer. Optional values
    /// keep older manifests readable; absent values mean the full viewport.
    public var sourceCropTop: Int?
    public var sourceCropBottom: Int?
    public var registrationResidual: Double?
    public var registrationAmbiguityRatio: Double?

    public init(
        relativeURL: String,
        capturedAt: Date = Date(),
        sourceRect: CaptureRegion,
        displayID: UInt32,
        pixelSize: PixelSize,
        estimatedOffset: Int?,
        confirmedOffset: Int?,
        topY: Int,
        registrationConfidence: Double? = nil,
        registrationOverlap: Int? = nil,
        registrationAnchorIndex: Int? = nil,
        sourceCropTop: Int? = nil,
        sourceCropBottom: Int? = nil,
        registrationResidual: Double? = nil,
        registrationAmbiguityRatio: Double? = nil
    ) {
        self.relativeURL = relativeURL
        self.capturedAt = capturedAt
        self.sourceRect = sourceRect
        self.displayID = displayID
        self.pixelSize = pixelSize
        self.estimatedOffset = estimatedOffset
        self.confirmedOffset = confirmedOffset
        self.topY = topY
        self.registrationConfidence = registrationConfidence
        self.registrationOverlap = registrationOverlap
        self.registrationAnchorIndex = registrationAnchorIndex
        self.sourceCropTop = sourceCropTop
        self.sourceCropBottom = sourceCropBottom
        self.registrationResidual = registrationResidual
        self.registrationAmbiguityRatio = registrationAmbiguityRatio
    }
}

public struct ScrollCaptureLimits: Codable, Equatable, Sendable {
    public static let `default` = ScrollCaptureLimits(
        maxPieces: 100,
        maxHeight: 30_000,
        maxDuration: 120,
        storage: .scrollDefault,
        stripeHeight: 1_024
    )

    public var maxPieces: Int
    public var maxHeight: Int
    public var maxDuration: TimeInterval
    public var storage: ArtifactStorageLimits
    public var stripeHeight: Int

    public init(
        maxPieces: Int,
        maxHeight: Int,
        maxDuration: TimeInterval,
        storage: ArtifactStorageLimits,
        stripeHeight: Int
    ) {
        self.maxPieces = maxPieces
        self.maxHeight = maxHeight
        self.maxDuration = maxDuration
        self.storage = storage
        self.stripeHeight = stripeHeight
    }

    public func decision(
        width: Int,
        projectedHeight: Int,
        pieceCount: Int,
        elapsed: TimeInterval,
        temporaryBytes: Int64,
        availableDiskBytes: Int64
    ) -> ScrollResourceDecision {
        evaluateResources(
            width: width,
            projectedHeight: projectedHeight,
            pieceCount: pieceCount,
            captureElapsed: elapsed,
            temporaryBytes: temporaryBytes,
            availableDiskBytes: availableDiskBytes
        )
    }

    /// The capture deadline prevents collecting more viewports. It must not
    /// prevent encoding the valid pieces that are already on disk, including
    /// when the user spent time reviewing a seam or correcting its offset.
    /// Finalization still obeys all size, pixel and disk limits.
    public func finalizationDecision(
        width: Int,
        projectedHeight: Int,
        pieceCount: Int,
        temporaryBytes: Int64,
        availableDiskBytes: Int64
    ) -> ScrollResourceDecision {
        evaluateResources(
            width: width,
            projectedHeight: projectedHeight,
            pieceCount: pieceCount,
            captureElapsed: nil,
            temporaryBytes: temporaryBytes,
            availableDiskBytes: availableDiskBytes
        )
    }

    private func evaluateResources(
        width: Int,
        projectedHeight: Int,
        pieceCount: Int,
        captureElapsed: TimeInterval?,
        temporaryBytes: Int64,
        availableDiskBytes: Int64
    ) -> ScrollResourceDecision {
        guard width > 0, projectedHeight > 0 else {
            return .reject(.invalidDimensions)
        }
        guard pieceCount <= maxPieces else {
            return .reject(.pieceLimit)
        }
        guard projectedHeight <= maxHeight else {
            return .reject(.heightLimit)
        }
        let pixels = width.multipliedReportingOverflow(by: projectedHeight)
        guard !pixels.overflow, pixels.partialValue <= storage.maxOutputPixelCount else {
            return .reject(.outputPixelBudget)
        }
        if let elapsed = captureElapsed, !(elapsed <= maxDuration) {
            return .reject(.timeLimit)
        }
        guard temporaryBytes <= storage.temporaryDiskBudgetBytes else {
            return .reject(.temporaryDiskBudget)
        }
        guard availableDiskBytes >= storage.minimumFreeDiskBytes else {
            return .reject(.freeDiskBudget)
        }
        let fullBitmapBytes = Int64(pixels.partialValue) * 4 + 128 * 1_024 * 1_024
        let mode: ArtifactEncoderMode = pixels.partialValue <= storage.maxFullBitmapPixelCount &&
            fullBitmapBytes <= storage.decodedBudgetBytes
            ? .fullBitmap
            : .striped
        return .allow(mode: mode, outputPixelCount: pixels.partialValue)
    }
}

public enum ScrollResourceLimit: String, Codable, Equatable, Sendable {
    case invalidDimensions
    case pieceLimit
    case heightLimit
    case outputPixelBudget
    case timeLimit
    case temporaryDiskBudget
    case freeDiskBudget
}

public enum ScrollResourceDecision: Equatable, Sendable {
    case allow(mode: ArtifactEncoderMode, outputPixelCount: Int)
    case reject(ScrollResourceLimit)
}

public enum ScrollCaptureProgressDecision: Equatable, Sendable {
    case continueCapturing
    case needsStartReposition(reason: String)
    case suggestEndConfirmation(reason: String)
    case endConfirmed
    case failed(reason: String)
}

public enum ScrollCaptureUserCompletionDecision: Equatable, Sendable {
    case finalize
    case requireStitchedMovement
}

public enum ScrollCaptureDirectionDecision: Equatable, Sendable {
    case appendForward
    case redefineInitialSection(discardedPieceCount: Int)
    case unchanged
}

/// Keeps reverse movement out of the monotonic stitch ledger. A viewport that
/// moved upward becomes the new first section; every previously accumulated
/// tail piece is discarded only after the replacement baseline is committed.
public enum ScrollCaptureDirectionPolicy {
    public static func decision(
        registeredOffset: Int,
        registrationReliable: Bool,
        pieceCount: Int
    ) -> ScrollCaptureDirectionDecision {
        if registeredOffset < 0, registrationReliable {
            return .redefineInitialSection(
                discardedPieceCount: max(0, pieceCount - 1)
            )
        }
        return registeredOffset > 0 ? .appendForward : .unchanged
    }
}

/// A scrolling session is not a successful long capture until at least one
/// viewport has been stitched onto its baseline. This prevents a no-op session
/// from masquerading as a completed scrolling screenshot.
public enum ScrollCaptureUserCompletionPolicy {
    public static func decision(
        captureHasStarted: Bool,
        pieceCount: Int
    ) -> ScrollCaptureUserCompletionDecision {
        captureHasStarted && pieceCount > 1
            ? .finalize
            : .requireStitchedMovement
    }
}

/// Encodes the distinction between a page that never moved and a page that
/// has reached its end. The caller owns image matching; this tracker owns the
/// state transition and is deterministic in tests.
public struct ScrollCaptureProgressTracker: Equatable, Sendable {
    private var observedMovement = false
    private var consecutiveNoMovement = 0

    public init() {}

    public mutating func record(
        estimatedOffset: Int?,
        focusAvailable: Bool,
        automaticMode: Bool,
        endBoundaryConfirmed: Bool = false
    ) -> ScrollCaptureProgressDecision {
        guard focusAvailable else {
            return .failed(reason: "scroll_focus_lost")
        }
        if let estimatedOffset, estimatedOffset > 0 {
            observedMovement = true
            consecutiveNoMovement = 0
            return .continueCapturing
        }
        guard automaticMode else {
            return .failed(
                reason: estimatedOffset == nil
                    ? "scroll_manual_offset_required"
                    : "scroll_manual_no_movement"
            )
        }

        // A single unchanged/uncertain frame is normal at gesture boundaries,
        // during lazy layout, and at the bottom of a document. It is content
        // evidence, not evidence that automatic capture is unavailable, so it
        // must never force a mode switch.
        consecutiveNoMovement += 1
        guard consecutiveNoMovement >= 3 else { return .continueCapturing }
        guard observedMovement else {
            return .needsStartReposition(reason: "scroll_no_movement_unconfirmed")
        }
        return endBoundaryConfirmed
            ? .endConfirmed
            : .suggestEndConfirmation(reason: "scroll_end_unconfirmed")
    }
}

public enum RecordingFrameDecision: Equatable, Sendable {
    case append(normalizedPresentationTime: Double)
    case discardInvalidTimestamp
    case dropBackpressure(consecutive: Int)
    case failBackpressure(consecutive: Int)
}

/// Pure timestamp/backpressure contract used by RecordingWriter. It prevents
/// duplicate or backward PTS from reaching AVAssetWriter and keeps the fixed
/// "more than 30 consecutive drops" failure boundary testable.
public struct RecordingTimingPolicy: Equatable, Sendable {
    public static let backpressureFailureThreshold = 30

    private var firstPresentationTime: Double?
    private var previousPresentationTime: Double?
    private var consecutiveDrops = 0

    public init() {}

    public mutating func consume(
        presentationTime: Double,
        writerReady: Bool
    ) -> RecordingFrameDecision {
        guard presentationTime.isFinite, presentationTime >= 0 else {
            return .discardInvalidTimestamp
        }
        if !writerReady {
            consecutiveDrops += 1
            return consecutiveDrops > Self.backpressureFailureThreshold
                ? .failBackpressure(consecutive: consecutiveDrops)
                : .dropBackpressure(consecutive: consecutiveDrops)
        }
        guard previousPresentationTime.map({ presentationTime > $0 }) ?? true else {
            return .discardInvalidTimestamp
        }
        let first = firstPresentationTime ?? presentationTime
        firstPresentationTime = first
        previousPresentationTime = presentationTime
        consecutiveDrops = 0
        return .append(normalizedPresentationTime: presentationTime - first)
    }
}

public enum FirstFrameGateResolution: Equatable, Sendable {
    case firstFrameCommitted(presentationTime: Double)
    case cancelWon
    case timeoutWon(deadlineID: UUID)
    case firstFrameAlreadyCommitted(presentationTime: Double)
    case alreadyResolved
}

/// This value is intentionally not thread-safe. RecordingWriter owns it and
/// invokes every transition on the same serial writer queue as input.append.
public struct FirstFrameGate: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case awaiting
        case committed(Double)
        case cancelled
        case timedOut(UUID)
    }

    public let deadlineID: UUID
    private var state: State = .awaiting

    public init(deadlineID: UUID) {
        self.deadlineID = deadlineID
    }

    public var acceptsSamples: Bool {
        switch state {
        case .awaiting, .committed: true
        case .cancelled, .timedOut: false
        }
    }

    public mutating func commitSuccessfulAppend(
        presentationTime: Double
    ) -> FirstFrameGateResolution {
        guard case .awaiting = state else { return .alreadyResolved }
        state = .committed(presentationTime)
        return .firstFrameCommitted(presentationTime: presentationTime)
    }

    public mutating func cancel() -> FirstFrameGateResolution {
        switch state {
        case .awaiting:
            state = .cancelled
            return .cancelWon
        case .committed(let presentationTime):
            return .firstFrameAlreadyCommitted(presentationTime: presentationTime)
        case .cancelled, .timedOut:
            return .alreadyResolved
        }
    }

    public mutating func timeout(
        deadlineID candidate: UUID
    ) -> FirstFrameGateResolution {
        guard candidate == deadlineID else { return .alreadyResolved }
        switch state {
        case .awaiting:
            state = .timedOut(candidate)
            return .timeoutWon(deadlineID: candidate)
        case .committed(let presentationTime):
            return .firstFrameAlreadyCommitted(presentationTime: presentationTime)
        case .cancelled, .timedOut:
            return .alreadyResolved
        }
    }
}

public enum RecordingErrorPresentation {
    public static func message(errorCode: String?, storedMessage: String?) -> String {
        switch errorCode {
        case "writer_backpressure", "recording_encoder_backpressure":
            return "录屏编码未能启动或持续拥塞"
        case "recording_disk_full":
            return "磁盘空间不足，录屏已安全停止"
        case "recording_first_frame_timeout":
            return "区域录屏启动超时，请重试"
        default:
            return storedMessage?.isEmpty == false ? storedMessage! : "录屏失败"
        }
    }
}

public enum CaptureResourceKind: String, Codable, CaseIterable, Sendable {
    case still
    case scroll
    case recording
}

public enum CaptureResourceDecision: Equatable, Sendable {
    case granted
    case queued(String)
    case rejected(String)
}

public enum CaptureResourcePolicy {
    public static func requiredCombinations(
        requested: CaptureResourceKind,
        active: Set<CaptureResourceKind>,
        monitorActive: Bool
    ) -> [CaptureConcurrencyCombination] {
        var combinations: [CaptureConcurrencyCombination] = []
        if requested == .scroll, monitorActive {
            combinations.append(.monitorScroll)
        }
        if requested == .recording, monitorActive {
            combinations.append(.monitorRecording)
        }
        if (requested == .recording && active.contains(.still)) ||
            (requested == .still && active.contains(.recording)) {
            combinations.append(.recordingStill)
        }
        return combinations
    }

    public static func decision(
        requested: CaptureResourceKind,
        active: Set<CaptureResourceKind>,
        monitorActive: Bool,
        slotCapabilities: [CaptureSlotCapability]
    ) -> CaptureResourceDecision {
        if active.contains(requested) {
            return .rejected("该采集会话已在运行")
        }
        if requested == .recording, active.contains(.recording) {
            return .rejected("同一时间只能运行一个区域录屏")
        }
        if (requested == .recording && active.contains(.scroll)) ||
            (requested == .scroll && active.contains(.recording)) {
            return .rejected("滚动截图与区域录屏不能同时运行")
        }
        let required = requiredCombinations(
            requested: requested,
            active: active,
            monitorActive: monitorActive
        )
        guard required.count == slotCapabilities.count else {
            return .rejected("并发采集能力未知，请关闭 Monitor 后重试")
        }
        for capability in slotCapabilities {
            switch capability {
            case .allowed:
                continue
            case .denied(let reason, _), .unknown(let reason):
                let suffix = monitorActive ? "；请关闭 Monitor 后重试" : ""
                return .rejected(reason + suffix)
            case .notRequired:
                return .rejected("并发采集能力证据缺失，请关闭 Monitor 后重试")
            }
        }
        return .granted
    }
}
