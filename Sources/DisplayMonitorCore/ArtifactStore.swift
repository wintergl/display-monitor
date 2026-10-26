import CoreGraphics
import CryptoKit
import Darwin
import Foundation

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case still
    case scrollStill
    case recording
    case gif
    case revision

    public var label: String {
        switch self {
        case .still: return "截图"
        case .scrollStill: return "滚动截图"
        case .recording: return "录屏"
        case .gif: return "GIF"
        case .revision: return "编辑版本"
        }
    }
}

public enum ArtifactStatus: String, Codable, CaseIterable, Sendable {
    case preparing
    case capturing
    case finalizing
    case completed
    case partial
    case recoveredPartial
    case failed
    case discarded

    public var isTerminal: Bool {
        switch self {
        case .completed, .partial, .recoveredPartial, .failed, .discarded:
            return true
        case .preparing, .capturing, .finalizing:
            return false
        }
    }

    public var label: String {
        switch self {
        case .preparing: return "准备中"
        case .capturing: return "采集中"
        case .finalizing: return "正在完成"
        case .completed: return "已完成"
        case .partial: return "部分产物"
        case .recoveredPartial: return "已恢复的部分产物"
        case .failed: return "失败"
        case .discarded: return "已删除"
        }
    }
}

public enum ArtifactCommitPhase: String, Codable, CaseIterable, Sendable {
    case writingTemporary
    case validated
    case renamed
    case manifestCommitted

    fileprivate var rank: Int {
        switch self {
        case .writingTemporary: return 0
        case .validated: return 1
        case .renamed: return 2
        case .manifestCommitted: return 3
        }
    }
}

public enum ArtifactEncoderMode: String, Codable, CaseIterable, Sendable {
    case fullBitmap
    case striped
}

public struct ArtifactStorageLimits: Codable, Equatable, Sendable {
    public static let scrollDefault = ArtifactStorageLimits(
        maxOutputPixelCount: 200_000_000,
        maxFullBitmapPixelCount: 100_000_000,
        decodedBudgetBytes: 512 * 1_024 * 1_024,
        temporaryDiskBudgetBytes: 2 * 1_024 * 1_024 * 1_024,
        minimumFreeDiskBytes: 1 * 1_024 * 1_024 * 1_024
    )

    public var maxOutputPixelCount: Int
    public var maxFullBitmapPixelCount: Int
    public var decodedBudgetBytes: Int64
    public var temporaryDiskBudgetBytes: Int64
    public var minimumFreeDiskBytes: Int64

    public init(
        maxOutputPixelCount: Int,
        maxFullBitmapPixelCount: Int,
        decodedBudgetBytes: Int64,
        temporaryDiskBudgetBytes: Int64,
        minimumFreeDiskBytes: Int64
    ) {
        self.maxOutputPixelCount = maxOutputPixelCount
        self.maxFullBitmapPixelCount = maxFullBitmapPixelCount
        self.decodedBudgetBytes = decodedBudgetBytes
        self.temporaryDiskBudgetBytes = temporaryDiskBudgetBytes
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }
}

/// The durable source of truth for a captured file. Desktop files and user
/// exports are deliberately optional compatibility copies, not identity.
public struct ArtifactManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1

    public var id: UUID
    public var kind: ArtifactKind
    public var status: ArtifactStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceArtifactID: UUID?
    public var canonicalURL: URL
    public var temporaryURL: URL
    public var desktopExportURL: URL?
    public var recycledURL: URL?
    public var previewURL: URL?
    public var dimensions: PixelSize?
    public var outputPixelCount: Int?
    public var maxOutputPixelCount: Int?
    public var decodedBudgetBytes: Int64?
    public var encoderMode: ArtifactEncoderMode?
    public var durationSeconds: Double?
    public var displayID: UInt32?
    public var captureRegion: CaptureRegion?
    public var manifestVersion: Int
    public var originOperationID: UUID
    public var activeOperationID: UUID
    public var commitSequence: Int
    public var commitPhase: ArtifactCommitPhase
    public var contentByteCount: Int64?
    public var contentSHA256: String?
    public var frameCount: Int?
    public var droppedFrameCount: Int?
    public var scrollCaptureMode: ScrollCaptureMode?
    public var scrollEndReason: ScrollCaptureEndReason?
    public var scrollFailureReason: String?
    public var scrollPieces: [ScrollCapturePiece]?
    public var errorCode: String?
    public var errorMessage: String?
    public var revisionNumber: Int

    public init(
        id: UUID,
        kind: ArtifactKind,
        status: ArtifactStatus = .preparing,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceArtifactID: UUID? = nil,
        canonicalURL: URL,
        temporaryURL: URL,
        desktopExportURL: URL? = nil,
        recycledURL: URL? = nil,
        previewURL: URL? = nil,
        dimensions: PixelSize? = nil,
        outputPixelCount: Int? = nil,
        maxOutputPixelCount: Int? = nil,
        decodedBudgetBytes: Int64? = nil,
        encoderMode: ArtifactEncoderMode? = nil,
        durationSeconds: Double? = nil,
        displayID: UInt32? = nil,
        captureRegion: CaptureRegion? = nil,
        manifestVersion: Int = ArtifactManifest.currentVersion,
        originOperationID: UUID,
        activeOperationID: UUID,
        commitSequence: Int = 0,
        commitPhase: ArtifactCommitPhase = .writingTemporary,
        contentByteCount: Int64? = nil,
        contentSHA256: String? = nil,
        frameCount: Int? = nil,
        droppedFrameCount: Int? = nil,
        scrollCaptureMode: ScrollCaptureMode? = nil,
        scrollEndReason: ScrollCaptureEndReason? = nil,
        scrollFailureReason: String? = nil,
        scrollPieces: [ScrollCapturePiece]? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        revisionNumber: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceArtifactID = sourceArtifactID
        self.canonicalURL = canonicalURL
        self.temporaryURL = temporaryURL
        self.desktopExportURL = desktopExportURL
        self.recycledURL = recycledURL
        self.previewURL = previewURL
        self.dimensions = dimensions
        self.outputPixelCount = outputPixelCount
        self.maxOutputPixelCount = maxOutputPixelCount
        self.decodedBudgetBytes = decodedBudgetBytes
        self.encoderMode = encoderMode
        self.durationSeconds = durationSeconds
        self.displayID = displayID
        self.captureRegion = captureRegion
        self.manifestVersion = manifestVersion
        self.originOperationID = originOperationID
        self.activeOperationID = activeOperationID
        self.commitSequence = commitSequence
        self.commitPhase = commitPhase
        self.contentByteCount = contentByteCount
        self.contentSHA256 = contentSHA256
        self.frameCount = frameCount
        self.droppedFrameCount = droppedFrameCount
        self.scrollCaptureMode = scrollCaptureMode
        self.scrollEndReason = scrollEndReason
        self.scrollFailureReason = scrollFailureReason
        self.scrollPieces = scrollPieces
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.revisionNumber = revisionNumber
    }

    public var isVisibleInShelf: Bool {
        status != .discarded
    }

    public var directoryURL: URL {
        canonicalURL.deletingLastPathComponent()
    }
}

public struct ArtifactLockRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var activeOperationID: UUID
    public var processUUID: UUID
    public var pid: Int32
    public var processStartToken: String
    public var acquiredAt: Date
    public var heartbeatAt: Date
    public var lockVersion: Int

    public init(
        activeOperationID: UUID,
        processUUID: UUID,
        pid: Int32,
        processStartToken: String,
        acquiredAt: Date = Date(),
        heartbeatAt: Date = Date(),
        lockVersion: Int = ArtifactLockRecord.currentVersion
    ) {
        self.activeOperationID = activeOperationID
        self.processUUID = processUUID
        self.pid = pid
        self.processStartToken = processStartToken
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
        self.lockVersion = lockVersion
    }
}

public struct ArtifactLockToken: Equatable, Sendable {
    public var artifactID: UUID
    public var operationID: UUID
    public var lockURL: URL

    public init(artifactID: UUID, operationID: UUID, lockURL: URL) {
        self.artifactID = artifactID
        self.operationID = operationID
        self.lockURL = lockURL
    }
}

public struct ArtifactSession: Equatable, Sendable {
    public var manifest: ArtifactManifest
    public var lockToken: ArtifactLockToken

    public init(manifest: ArtifactManifest, lockToken: ArtifactLockToken) {
        self.manifest = manifest
        self.lockToken = lockToken
    }
}

public enum ArtifactFinalizationFault: String, Codable, Equatable, Sendable {
    case none
    case afterFinalizingPersisted
    case afterValidatedPersistedBeforeRename
    case afterRenameBeforeManifest
    case afterRenamedPersistedBeforeTerminal
    case afterManifestCommittedControl
}

public enum ArtifactProcessLiveness: Sendable {
    case alive
    case dead
    case unknown
}

public enum ArtifactRecoveryDisposition: Equatable, Sendable {
    case unchanged
    case recoveredCompleted
    case recoveredPartial
    case failed
    case needsConfirmation
}

public struct ArtifactRecoveryResult: Equatable, Sendable {
    public var manifest: ArtifactManifest
    public var disposition: ArtifactRecoveryDisposition
    public var message: String?

    public init(
        manifest: ArtifactManifest,
        disposition: ArtifactRecoveryDisposition,
        message: String? = nil
    ) {
        self.manifest = manifest
        self.disposition = disposition
        self.message = message
    }
}

public enum ArtifactStoreError: Error, LocalizedError, Sendable {
    case notFound(UUID)
    case invalidOperation
    case lockUnavailable
    case lockMismatch
    case recoveryNeedsConfirmation
    case identityMismatch
    case injectedFinalizationFault
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidFile(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到产物 manifest"
        case .invalidOperation:
            return "产物已被其他操作接管"
        case .lockUnavailable:
            return "产物正在由其他进程处理"
        case .lockMismatch:
            return "产物锁身份不匹配"
        case .recoveryNeedsConfirmation:
            return "无法确认旧进程是否已退出"
        case .identityMismatch:
            return "temporary 与 canonical 文件身份冲突"
        case .injectedFinalizationFault:
            return "已注入 rename 后 manifest 前的崩溃"
        case .insufficientDiskSpace(let required, let available):
            return "磁盘空间不足：需要 \(required) 字节，可用 \(available) 字节"
        case .invalidFile(let detail):
            return "产物文件不可用：\(detail)"
        case .io(let detail):
            return "文件系统错误：\(detail)"
        }
    }
}

public typealias ArtifactFileValidator = @Sendable (URL, ArtifactKind) -> Bool
public typealias ArtifactLivenessProbe = @Sendable (ArtifactLockRecord) -> ArtifactProcessLiveness

/// A file-system actor that makes a canonical artifact directory the sole
/// recovery authority. Every caller receives an operation-bound session and
/// cannot accidentally overwrite an artifact created by a later session.
public actor ArtifactStore {
    public static let manifestFileName = "manifest.json"
    public static let lockFileName = ".artifact.lock"

    private let rootURL: URL
    private let fileManager: FileManager
    private let validator: ArtifactFileValidator
    private let livenessProbe: ArtifactLivenessProbe
    private let staleLockInterval: TimeInterval
    private let configuredFinalizationFault: ArtifactFinalizationFault
    private let finalizationFaultHandler: (@Sendable (
        ArtifactFinalizationFault,
        ArtifactManifest
    ) -> Void)?
    private let processUUID = UUID()
    private let processStartToken = UUID().uuidString

    public init(
        rootURL: URL = ArtifactStore.defaultRootURL(),
        fileManager: FileManager = .default,
        validator: @escaping ArtifactFileValidator = ArtifactStore.defaultValidator,
        livenessProbe: @escaping ArtifactLivenessProbe = ArtifactStore.defaultLivenessProbe,
        staleLockInterval: TimeInterval = 30,
        configuredFinalizationFault: ArtifactFinalizationFault = .none,
        finalizationFaultHandler: (@Sendable (
            ArtifactFinalizationFault,
            ArtifactManifest
        ) -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.validator = validator
        self.livenessProbe = livenessProbe
        self.staleLockInterval = max(0, staleLockInterval)
        self.configuredFinalizationFault = configuredFinalizationFault
        self.finalizationFaultHandler = finalizationFaultHandler
    }

    public nonisolated static func defaultRootURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("DisplayMonitor", isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
    }

    public nonisolated static func defaultValidator(url: URL, _: ArtifactKind) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return false
        }
        return size > 0
    }

    public nonisolated static func defaultLivenessProbe(_ lock: ArtifactLockRecord) -> ArtifactProcessLiveness {
        guard lock.pid > 0 else {
            return .unknown
        }
        if kill(lock.pid, 0) == 0 {
            // A matching pid alone cannot prove start-token identity. Be
            // conservative and require user confirmation rather than stealing.
            return .unknown
        }
        return errno == ESRCH ? .dead : .unknown
    }

    public func artifacts(includeDiscarded: Bool = false) throws -> [ArtifactManifest] {
        try manifests(includeDiscarded: includeDiscarded)
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// External export must never overwrite an artifact, manifest or sidecar.
    /// Resolve existing symlink parents as well as the destination itself.
    public func isManagedLocation(_ url: URL) -> Bool {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public func artifact(id: UUID) throws -> ArtifactManifest {
        try loadManifest(id: id)
    }

    /// Verifies that the artifact root can be written without creating a user
    /// artifact identity. The probe lives in a dedicated hidden directory and
    /// is removed before this method returns successfully.
    public func preflightWriteAvailability(
        minimumFreeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    ) throws {
        try ensureRootDirectory()
        let values = try rootURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available = ArtifactDiskCapacity.availableBytes(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            ordinary: values.volumeAvailableCapacity.map(Int64.init)
        )
        guard available >= minimumFreeBytes else {
            throw ArtifactStoreError.insufficientDiskSpace(
                required: minimumFreeBytes,
                available: available
            )
        }

        let probeDirectory = rootURL.appendingPathComponent(".preflight", isDirectory: true)
        try fileManager.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let probeURL = probeDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        do {
            try atomicWrite(Data("DisplayMonitor preflight".utf8), to: probeURL)
            try fileManager.removeItem(at: probeURL)
        } catch {
            try? fileManager.removeItem(at: probeURL)
            throw error
        }
    }

    public func beginArtifact(
        kind: ArtifactKind,
        fileExtension: String,
        sourceArtifactID: UUID? = nil,
        dimensions: PixelSize? = nil,
        displayID: UInt32? = nil,
        captureRegion: CaptureRegion? = nil,
        limits: ArtifactStorageLimits? = nil,
        encoderMode: ArtifactEncoderMode? = nil,
        operationID: UUID = UUID()
    ) throws -> ArtifactSession {
        try beginArtifactSession(
            kind: kind,
            fileExtension: fileExtension,
            sourceArtifactID: sourceArtifactID,
            dimensions: dimensions,
            displayID: displayID,
            captureRegion: captureRegion,
            limits: limits,
            encoderMode: encoderMode,
            operationID: operationID,
            initialStatus: .capturing
        )
    }

    /// Creates the durable recording identity while deliberately leaving it in
    /// `preparing`. Recording promotes it only after the first frame commits.
    public func beginPreparedArtifact(
        kind: ArtifactKind = .recording,
        fileExtension: String = "mp4",
        dimensions: PixelSize? = nil,
        displayID: UInt32? = nil,
        captureRegion: CaptureRegion? = nil,
        operationID: UUID = UUID()
    ) throws -> ArtifactSession {
        guard kind == .recording else {
            throw ArtifactStoreError.invalidOperation
        }
        return try beginArtifactSession(
            kind: kind,
            fileExtension: fileExtension,
            sourceArtifactID: nil,
            dimensions: dimensions,
            displayID: displayID,
            captureRegion: captureRegion,
            limits: nil,
            encoderMode: nil,
            operationID: operationID,
            initialStatus: .preparing
        )
    }

    @discardableResult
    public func markCapturing(for session: ArtifactSession) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        if manifest.status == .capturing {
            return manifest
        }
        guard manifest.status == .preparing else {
            throw ArtifactStoreError.invalidOperation
        }
        manifest.status = .capturing
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    @discardableResult
    public func markFinalizing(for session: ArtifactSession) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        if manifest.status == .finalizing {
            return manifest
        }
        guard manifest.status == .preparing || manifest.status == .capturing else {
            throw ArtifactStoreError.invalidFile("只有 preparing/capturing 产物可以进入 finalizing")
        }
        manifest.status = .finalizing
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    private func beginArtifactSession(
        kind: ArtifactKind,
        fileExtension: String,
        sourceArtifactID: UUID?,
        dimensions: PixelSize?,
        displayID: UInt32?,
        captureRegion: CaptureRegion?,
        limits: ArtifactStorageLimits?,
        encoderMode: ArtifactEncoderMode?,
        operationID: UUID,
        initialStatus: ArtifactStatus
    ) throws -> ArtifactSession {
        try ensureRootDirectory()
        let suffix = try sanitizedExtension(fileExtension)
        let id = UUID()
        let artifactDirectory = datedDirectory(for: Date()).appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        let canonicalURL = artifactDirectory.appendingPathComponent("artifact.\(suffix)")
        let temporaryURL = artifactDirectory.appendingPathComponent("artifact.\(suffix).tmp")
        let revisionNumber: Int
        if let sourceArtifactID, let source = try? loadManifest(id: sourceArtifactID) {
            revisionNumber = source.revisionNumber + 1
        } else {
            revisionNumber = 0
        }

        var manifest = ArtifactManifest(
            id: id,
            kind: kind,
            sourceArtifactID: sourceArtifactID,
            canonicalURL: canonicalURL,
            temporaryURL: temporaryURL,
            dimensions: dimensions,
            outputPixelCount: dimensions.map { $0.width * $0.height },
            maxOutputPixelCount: limits?.maxOutputPixelCount,
            decodedBudgetBytes: limits?.decodedBudgetBytes,
            encoderMode: encoderMode,
            displayID: displayID,
            captureRegion: captureRegion,
            originOperationID: operationID,
            activeOperationID: operationID,
            revisionNumber: revisionNumber
        )
        do {
            try persist(manifest)
            let lockToken = try acquireLock(for: manifest, operationID: operationID)
            if initialStatus != .preparing {
                manifest.status = initialStatus
                incrementCommit(&manifest)
                try persist(manifest)
            }
            return ArtifactSession(manifest: manifest, lockToken: lockToken)
        } catch {
            // This directory was allocated from a fresh UUID and cannot contain
            // another artifact. A normal-return failure must not leave a shelf
            // entry or active lock behind.
            try? fileManager.removeItem(at: artifactDirectory)
            throw error
        }
    }

    @discardableResult
    public func writeTemporaryData(
        _ data: Data,
        for session: ArtifactSession
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        guard data.isEmpty == false else {
            throw ArtifactStoreError.invalidFile("空数据")
        }
        try atomicWrite(data, to: manifest.temporaryURL)
        manifest.status = .capturing
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    /// Stages an already-produced media file into the artifact directory
    /// without making the source URL part of artifact identity.
    @discardableResult
    public func stageTemporaryFile(
        from sourceURL: URL,
        for session: ArtifactSession
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ArtifactStoreError.invalidFile("待导入文件不存在")
        }
        let stagingURL = manifest.temporaryURL.appendingPathExtension("copying")
        try? fileManager.removeItem(at: stagingURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            try atomicRename(from: stagingURL, to: manifest.temporaryURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw ArtifactStoreError.io("无法暂存产物文件：\(error.localizedDescription)")
        }
        manifest.status = .capturing
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    @discardableResult
    public func finalizeData(
        _ data: Data,
        for session: ArtifactSession,
        fault: ArtifactFinalizationFault = .none
    ) throws -> ArtifactManifest {
        _ = try writeTemporaryData(data, for: session)
        return try finalizeTemporary(for: session, fault: fault)
    }

    @discardableResult
    public func finalizeTemporary(
        for session: ArtifactSession,
        terminalStatus: ArtifactStatus = .completed,
        terminalError: CaptureError? = nil,
        fault: ArtifactFinalizationFault = .none
    ) throws -> ArtifactManifest {
        guard terminalStatus == .completed || terminalStatus == .partial else {
            throw ArtifactStoreError.invalidFile("finalizeTemporary 只支持 completed 或 partial")
        }
        var manifest = try validatedManifest(for: session)
        manifest.status = .finalizing
        incrementCommit(&manifest)
        try persist(manifest)
        try triggerFinalizationFault(.afterFinalizingPersisted, requested: fault, manifest: manifest)

        let temporaryIdentity = try validatedIdentity(at: manifest.temporaryURL, kind: manifest.kind)
        manifest.contentByteCount = temporaryIdentity.byteCount
        manifest.contentSHA256 = temporaryIdentity.sha256
        manifest.commitPhase = .validated
        incrementCommit(&manifest)
        try persist(manifest)
        try triggerFinalizationFault(
            .afterValidatedPersistedBeforeRename,
            requested: fault,
            manifest: manifest
        )

        if fileManager.fileExists(atPath: manifest.canonicalURL.path) {
            guard try identityMatches(manifest, at: manifest.canonicalURL) else {
                throw ArtifactStoreError.identityMismatch
            }
        } else {
            try atomicRename(from: manifest.temporaryURL, to: manifest.canonicalURL)
        }

        try triggerFinalizationFault(.afterRenameBeforeManifest, requested: fault, manifest: manifest)

        manifest.commitPhase = .renamed
        incrementCommit(&manifest)
        try persist(manifest)
        try triggerFinalizationFault(
            .afterRenamedPersistedBeforeTerminal,
            requested: fault,
            manifest: manifest
        )

        manifest.status = terminalStatus
        manifest.commitPhase = .manifestCommitted
        manifest.errorCode = terminalError?.code
        manifest.errorMessage = terminalError?.description
        incrementCommit(&manifest)
        try persist(manifest)
        try triggerFinalizationFault(
            .afterManifestCommittedControl,
            requested: fault,
            manifest: manifest
        )
        try releaseLock(session.lockToken)
        return manifest
    }

    @discardableResult
    public func markPartial(
        for session: ArtifactSession,
        error: CaptureError? = nil
    ) throws -> ArtifactManifest {
        try markTerminal(for: session, status: .partial, error: error)
    }

    @discardableResult
    public func markFailed(
        for session: ArtifactSession,
        error: CaptureError
    ) throws -> ArtifactManifest {
        try markTerminal(for: session, status: .failed, error: error)
    }

    @discardableResult
    public func updateRecordingMetrics(
        for session: ArtifactSession,
        durationSeconds: Double?,
        frameCount: Int,
        droppedFrameCount: Int
    ) throws -> ArtifactManifest {
        try updateArtifactMetrics(
            for: session,
            durationSeconds: durationSeconds,
            frameCount: frameCount,
            droppedFrameCount: droppedFrameCount
        )
    }

    @discardableResult
    public func updateArtifactMetrics(
        for session: ArtifactSession,
        durationSeconds: Double?,
        frameCount: Int?,
        droppedFrameCount: Int?
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        manifest.durationSeconds = durationSeconds
        manifest.frameCount = frameCount
        manifest.droppedFrameCount = droppedFrameCount
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    /// Persists the scroll-session ledger before the output is finalized. The
    /// ledger makes manual offsets, failure reasons and retained fragments
    /// recoverable without treating a Desktop compatibility copy as identity.
    @discardableResult
    public func updateScrollCaptureMetadata(
        for session: ArtifactSession,
        mode: ScrollCaptureMode,
        endReason: ScrollCaptureEndReason?,
        failureReason: String?,
        pieces: [ScrollCapturePiece],
        outputSize: PixelSize?,
        outputPixelCount: Int?,
        encoderMode: ArtifactEncoderMode?
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        manifest.scrollCaptureMode = mode
        manifest.scrollEndReason = endReason
        manifest.scrollFailureReason = failureReason
        manifest.scrollPieces = pieces
        if let outputSize {
            manifest.dimensions = outputSize
        }
        manifest.outputPixelCount = outputPixelCount
        manifest.encoderMode = encoderMode
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    /// Atomically publishes the latest in-progress scroll composite as a
    /// preview. The preview is deliberately separate from `temporaryURL` and
    /// `canonicalURL`, so a partially rendered image can never be mistaken for
    /// the final artifact during recovery or export.
    @discardableResult
    public func commitScrollPreview(
        from sourceURL: URL,
        for session: ArtifactSession,
        dimensions: PixelSize?,
        outputPixelCount: Int?,
        encoderMode: ArtifactEncoderMode?
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        let directory = manifest.directoryURL.standardizedFileURL
        guard sourceURL.deletingLastPathComponent().standardizedFileURL == directory else {
            throw ArtifactStoreError.invalidFile("滚动预览不在当前 artifact 目录")
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ArtifactStoreError.invalidFile("滚动预览暂存文件不存在")
        }
        let previewURL = directory.appendingPathComponent("preview.png")
        try atomicRename(from: sourceURL, to: previewURL)
        manifest.previewURL = previewURL
        if let dimensions {
            manifest.dimensions = dimensions
        }
        manifest.outputPixelCount = outputPixelCount
        manifest.encoderMode = encoderMode
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    @discardableResult
    public func setDesktopExportURL(_ url: URL?, for id: UUID) throws -> ArtifactManifest {
        var manifest = try loadManifest(id: id)
        manifest.desktopExportURL = url
        incrementCommit(&manifest)
        try persist(manifest)
        return manifest
    }

    @discardableResult
    public func discard(id: UUID) throws -> ArtifactManifest {
        var manifest = try loadManifest(id: id)
        guard manifest.status != .discarded else {
            return manifest
        }

        manifest.status = .discarded
        incrementCommit(&manifest)
        try persist(manifest)

        if fileManager.fileExists(atPath: manifest.canonicalURL.path) {
            let recycleDirectory = rootURL.appendingPathComponent(".recycle", isDirectory: true)
            try fileManager.createDirectory(at: recycleDirectory, withIntermediateDirectories: true)
            let recycledURL = recycleDirectory.appendingPathComponent(
                "\(manifest.id.uuidString)-\(manifest.canonicalURL.lastPathComponent)"
            )
            try atomicRename(from: manifest.canonicalURL, to: recycledURL)
            manifest.recycledURL = recycledURL
            incrementCommit(&manifest)
            try persist(manifest)
        }
        return manifest
    }

    /// Discards an artifact that is still owned by a live capture session and
    /// releases its exact operation lock. Session files remain in the artifact
    /// directory for recoverable cleanup, but the artifact is hidden from all
    /// user-facing inventories immediately.
    @discardableResult
    public func discard(for session: ArtifactSession) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        manifest.status = .discarded
        manifest.errorCode = nil
        manifest.errorMessage = nil
        incrementCommit(&manifest)
        try persist(manifest)
        try releaseLock(session.lockToken)
        return manifest
    }

    public func childArtifacts(of id: UUID) throws -> [ArtifactManifest] {
        try artifacts().filter { $0.sourceArtifactID == id }
    }

    public func recoverAll() throws -> [ArtifactRecoveryResult] {
        try manifests(includeDiscarded: true)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { manifest in
                do {
                    return try recover(manifest: manifest)
                } catch {
                    var failed = manifest
                    failed.status = .failed
                    failed.errorCode = "recovery_unexpected_error"
                    failed.errorMessage = String(describing: error)
                    incrementCommit(&failed)
                    try? persist(failed)
                    return ArtifactRecoveryResult(
                        manifest: failed,
                        disposition: .failed,
                        message: failed.errorMessage
                    )
                }
            }
    }

    public func touchLock(_ token: ArtifactLockToken) throws {
        guard let record = try readLock(at: token.lockURL),
              record.activeOperationID == token.operationID else {
            throw ArtifactStoreError.lockMismatch
        }
        var updated = record
        updated.heartbeatAt = Date()
        try writeLock(updated, to: token.lockURL, exclusive: false)
    }

    private func recover(manifest originalManifest: ArtifactManifest) throws -> ArtifactRecoveryResult {
        var manifest = originalManifest
        guard manifest.status != .discarded else {
            return ArtifactRecoveryResult(manifest: manifest, disposition: .unchanged)
        }

        if manifest.status == .completed {
            guard try fileIsValid(manifest, at: manifest.canonicalURL) else {
                manifest.status = .failed
                manifest.errorCode = "canonical_missing_or_invalid"
                manifest.errorMessage = "已完成产物的 canonical 文件不可读取"
                incrementCommit(&manifest)
                try persist(manifest)
                return ArtifactRecoveryResult(manifest: manifest, disposition: .failed)
            }
        }

        if manifest.status.isTerminal {
            return try recoverTerminalLockIfNeeded(manifest: manifest)
        }

        guard manifest.status == .preparing || manifest.status == .capturing || manifest.status == .finalizing else {
            return ArtifactRecoveryResult(manifest: manifest, disposition: .unchanged)
        }

        let recoveryOperationID = UUID()
        let recoveryLock: ArtifactLockToken
        do {
            recoveryLock = try acquireRecoveryLock(for: manifest, operationID: recoveryOperationID)
        } catch ArtifactStoreError.recoveryNeedsConfirmation {
            return ArtifactRecoveryResult(
                manifest: manifest,
                disposition: .needsConfirmation,
                message: "旧进程锁无法确认 stale"
            )
        }

        manifest.activeOperationID = recoveryOperationID
        incrementCommit(&manifest)
        try persist(manifest)
        let session = ArtifactSession(manifest: manifest, lockToken: recoveryLock)

        let canonicalValid = try fileIsValid(manifest, at: manifest.canonicalURL)
        let temporaryValid = try fileIsValid(manifest, at: manifest.temporaryURL)

        if canonicalValid && temporaryValid,
           let canonicalIdentity = try? fileIdentity(at: manifest.canonicalURL),
           let temporaryIdentity = try? fileIdentity(at: manifest.temporaryURL),
           canonicalIdentity != temporaryIdentity {
            return try finalizeRecoveryFailure(
                session: session,
                manifest: manifest,
                code: "recovery_conflict",
                message: "canonical 与 temporary 文件身份不同"
            )
        }

        if canonicalValid {
            // canonical-first: a validated manifest plus matching canonical
            // proves rename won the crash race, even if renamed was not written.
            if manifest.commitPhase.rank < ArtifactCommitPhase.renamed.rank {
                manifest.commitPhase = .renamed
                incrementCommit(&manifest)
                try persist(manifest)
            }
            manifest.status = manifest.commitPhase.rank >= ArtifactCommitPhase.validated.rank
                ? .completed
                : .recoveredPartial
            manifest.commitPhase = .manifestCommitted
            incrementCommit(&manifest)
            try persist(manifest)
            try releaseLock(session.lockToken)
            return ArtifactRecoveryResult(
                manifest: manifest,
                disposition: manifest.status == .completed ? .recoveredCompleted : .recoveredPartial
            )
        }

        if temporaryValid {
            if manifest.commitPhase.rank >= ArtifactCommitPhase.validated.rank {
                let identity = try validatedIdentity(at: manifest.temporaryURL, kind: manifest.kind)
                manifest.contentByteCount = identity.byteCount
                manifest.contentSHA256 = identity.sha256
                try atomicRename(from: manifest.temporaryURL, to: manifest.canonicalURL)
                manifest.commitPhase = .renamed
                incrementCommit(&manifest)
                try persist(manifest)
                manifest.status = .completed
                manifest.commitPhase = .manifestCommitted
                incrementCommit(&manifest)
                try persist(manifest)
                try releaseLock(session.lockToken)
                return ArtifactRecoveryResult(manifest: manifest, disposition: .recoveredCompleted)
            }

            let identity = try validatedIdentity(at: manifest.temporaryURL, kind: manifest.kind)
            manifest.contentByteCount = identity.byteCount
            manifest.contentSHA256 = identity.sha256
            manifest.commitPhase = .validated
            incrementCommit(&manifest)
            try persist(manifest)
            try atomicRename(from: manifest.temporaryURL, to: manifest.canonicalURL)
            manifest.commitPhase = .renamed
            incrementCommit(&manifest)
            try persist(manifest)
            manifest.status = .recoveredPartial
            manifest.commitPhase = .manifestCommitted
            manifest.errorCode = "recovered_unfinalized_temporary"
            manifest.errorMessage = "发现可读取的未完成临时产物"
            incrementCommit(&manifest)
            try persist(manifest)
            try releaseLock(session.lockToken)
            return ArtifactRecoveryResult(manifest: manifest, disposition: .recoveredPartial)
        }

        return try finalizeRecoveryFailure(
            session: session,
            manifest: manifest,
            code: "recovery_no_readable_file",
            message: "未找到可读取的 canonical 或 temporary 文件"
        )
    }

    private func recoverTerminalLockIfNeeded(
        manifest: ArtifactManifest
    ) throws -> ArtifactRecoveryResult {
        let url = lockURL(for: manifest)
        guard fileManager.fileExists(atPath: url.path) else {
            return ArtifactRecoveryResult(manifest: manifest, disposition: .unchanged)
        }
        guard let existing = try readLock(at: url) else {
            return ArtifactRecoveryResult(
                manifest: manifest,
                disposition: .needsConfirmation,
                message: "terminal artifact 的残留锁无法解码"
            )
        }
        let age = Date().timeIntervalSince(existing.heartbeatAt)
        guard age > staleLockInterval, livenessProbe(existing) == .dead else {
            return ArtifactRecoveryResult(
                manifest: manifest,
                disposition: .needsConfirmation,
                message: "terminal artifact 的旧进程锁尚不能确认 stale"
            )
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ArtifactStoreError.io("无法清理 terminal artifact 残留锁：\(error.localizedDescription)")
        }
        return ArtifactRecoveryResult(
            manifest: manifest,
            disposition: .unchanged,
            message: "已清理 terminal artifact 的 stale lock"
        )
    }

    private func finalizeRecoveryFailure(
        session: ArtifactSession,
        manifest originalManifest: ArtifactManifest,
        code: String,
        message: String
    ) throws -> ArtifactRecoveryResult {
        var manifest = originalManifest
        manifest.status = .failed
        manifest.errorCode = code
        manifest.errorMessage = message
        incrementCommit(&manifest)
        try persist(manifest)
        try releaseLock(session.lockToken)
        return ArtifactRecoveryResult(manifest: manifest, disposition: .failed, message: message)
    }

    private func markTerminal(
        for session: ArtifactSession,
        status: ArtifactStatus,
        error: CaptureError?
    ) throws -> ArtifactManifest {
        var manifest = try validatedManifest(for: session)
        manifest.status = status
        manifest.errorCode = error?.code
        manifest.errorMessage = error?.description
        incrementCommit(&manifest)
        try persist(manifest)
        try releaseLock(session.lockToken)
        return manifest
    }

    private func triggerFinalizationFault(
        _ point: ArtifactFinalizationFault,
        requested: ArtifactFinalizationFault,
        manifest: ArtifactManifest
    ) throws {
        guard requested == point || configuredFinalizationFault == point else { return }
        if configuredFinalizationFault == point {
            finalizationFaultHandler?(point, manifest)
        }
        throw ArtifactStoreError.injectedFinalizationFault
    }

    private func validatedManifest(for session: ArtifactSession) throws -> ArtifactManifest {
        let manifest = try loadManifest(id: session.manifest.id)
        guard manifest.activeOperationID == session.lockToken.operationID else {
            throw ArtifactStoreError.invalidOperation
        }
        guard session.lockToken.artifactID == manifest.id else {
            throw ArtifactStoreError.lockMismatch
        }
        guard let lock = try readLock(at: session.lockToken.lockURL),
              lock.activeOperationID == session.lockToken.operationID else {
            throw ArtifactStoreError.lockMismatch
        }
        return manifest
    }

    private func acquireRecoveryLock(
        for manifest: ArtifactManifest,
        operationID: UUID
    ) throws -> ArtifactLockToken {
        let lockURL = lockURL(for: manifest)
        guard fileManager.fileExists(atPath: lockURL.path) else {
            return try acquireLock(for: manifest, operationID: operationID)
        }
        guard let existing = try readLock(at: lockURL) else {
            throw ArtifactStoreError.recoveryNeedsConfirmation
        }
        let age = Date().timeIntervalSince(existing.heartbeatAt)
        guard age > staleLockInterval, livenessProbe(existing) == .dead else {
            throw ArtifactStoreError.recoveryNeedsConfirmation
        }

        let archive = lockURL.deletingLastPathComponent().appendingPathComponent(
            ".artifact.lock.recovered-\(operationID.uuidString)"
        )
        do {
            try atomicRename(from: lockURL, to: archive)
        } catch {
            throw ArtifactStoreError.lockUnavailable
        }
        do {
            let token = try acquireLock(for: manifest, operationID: operationID)
            try? fileManager.removeItem(at: archive)
            return token
        } catch {
            // Restore the prior evidence if the replacement lock could not be
            // acquired; a later recovery attempt must not mistake this for an
            // unlocked artifact.
            try? atomicRename(from: archive, to: lockURL)
            throw error
        }
    }

    private func acquireLock(
        for manifest: ArtifactManifest,
        operationID: UUID
    ) throws -> ArtifactLockToken {
        let lockURL = lockURL(for: manifest)
        let record = ArtifactLockRecord(
            activeOperationID: operationID,
            processUUID: processUUID,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            processStartToken: processStartToken
        )
        do {
            try writeLock(record, to: lockURL, exclusive: true)
        } catch {
            throw ArtifactStoreError.lockUnavailable
        }
        return ArtifactLockToken(
            artifactID: manifest.id,
            operationID: operationID,
            lockURL: lockURL
        )
    }

    private func releaseLock(_ token: ArtifactLockToken) throws {
        guard let record = try readLock(at: token.lockURL),
              record.activeOperationID == token.operationID else {
            throw ArtifactStoreError.lockMismatch
        }
        do {
            try fileManager.removeItem(at: token.lockURL)
        } catch {
            throw ArtifactStoreError.io("无法释放 artifact lock：\(error.localizedDescription)")
        }
    }

    private func manifests(includeDiscarded: Bool) throws -> [ArtifactManifest] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var results: [ArtifactManifest] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == Self.manifestFileName else { continue }
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? Self.decoder.decode(ArtifactManifest.self, from: data) else {
                continue
            }
            if includeDiscarded || manifest.isVisibleInShelf {
                results.append(manifest)
            }
        }
        return results
    }

    private func loadManifest(id: UUID) throws -> ArtifactManifest {
        guard let manifest = try manifests(includeDiscarded: true).first(where: { $0.id == id }) else {
            throw ArtifactStoreError.notFound(id)
        }
        return manifest
    }

    private func manifestURL(for manifest: ArtifactManifest) -> URL {
        manifest.directoryURL.appendingPathComponent(Self.manifestFileName)
    }

    private func lockURL(for manifest: ArtifactManifest) -> URL {
        manifest.directoryURL.appendingPathComponent(Self.lockFileName)
    }

    private func persist(_ manifest: ArtifactManifest) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(manifest)
        } catch {
            throw ArtifactStoreError.io("manifest 编码失败：\(error.localizedDescription)")
        }
        try atomicWrite(data, to: manifestURL(for: manifest))
    }

    private func readLock(at url: URL) throws -> ArtifactLockRecord? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try Self.decoder.decode(ArtifactLockRecord.self, from: Data(contentsOf: url))
        } catch {
            throw ArtifactStoreError.io("artifact lock 无法解码：\(error.localizedDescription)")
        }
    }

    private func writeLock(
        _ record: ArtifactLockRecord,
        to url: URL,
        exclusive: Bool
    ) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(record)
        } catch {
            throw ArtifactStoreError.io("artifact lock 编码失败：\(error.localizedDescription)")
        }
        if exclusive {
            try exclusiveWrite(data, to: url)
        } else {
            try atomicWrite(data, to: url)
        }
    }

    private func ensureRootDirectory() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw ArtifactStoreError.io("无法创建 artifact 根目录：\(error.localizedDescription)")
        }
    }

    private func datedDirectory(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return rootURL.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    private func sanitizedExtension(_ fileExtension: String) throws -> String {
        let trimmed = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let allowed = CharacterSet.alphanumerics
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ArtifactStoreError.invalidFile("非法扩展名")
        }
        return trimmed.lowercased()
    }

    private func incrementCommit(_ manifest: inout ArtifactManifest) {
        manifest.commitSequence += 1
        manifest.updatedAt = Date()
    }

    private func fileIsValid(_ manifest: ArtifactManifest, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard validator(url, manifest.kind) else { return false }
        if manifest.contentByteCount != nil || manifest.contentSHA256 != nil {
            return try identityMatches(manifest, at: url)
        }
        return true
    }

    private func identityMatches(_ manifest: ArtifactManifest, at url: URL) throws -> Bool {
        guard let expectedCount = manifest.contentByteCount,
              let expectedHash = manifest.contentSHA256 else {
            return false
        }
        let identity = try fileIdentity(at: url)
        return identity.byteCount == expectedCount && identity.sha256 == expectedHash
    }

    private func validatedIdentity(at url: URL, kind: ArtifactKind) throws -> ArtifactFileIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArtifactStoreError.invalidFile("文件不存在")
        }
        guard validator(url, kind) else {
            throw ArtifactStoreError.invalidFile("解码或完整性验证失败")
        }
        return try fileIdentity(at: url)
    }

    private func fileIdentity(at url: URL) throws -> ArtifactFileIdentity {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw ArtifactStoreError.io("无法读取文件大小：\(error.localizedDescription)")
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw ArtifactStoreError.invalidFile("文件为空")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }
            return ArtifactFileIdentity(
                byteCount: Int64(fileSize),
                sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
            )
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.io("无法计算文件摘要：\(error.localizedDescription)")
        }
    }

    private func atomicRename(from source: URL, to destination: URL) throws {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else {
            throw ArtifactStoreError.io("atomic rename 失败：\(String(cString: strerror(errno)))")
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ArtifactStoreError.io("无法创建临时文件：\(String(cString: strerror(errno)))")
        }

        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw ArtifactStoreError.io("fsync 失败：\(String(cString: strerror(errno)))")
            }
            guard close(descriptor) == 0 else {
                throw ArtifactStoreError.io("关闭临时文件失败：\(String(cString: strerror(errno)))")
            }
            try atomicRename(from: temporary, to: destination)
        } catch {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func exclusiveWrite(_ data: Data, to destination: URL) throws {
        let descriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ArtifactStoreError.lockUnavailable
        }
        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw ArtifactStoreError.io("lock fsync 失败：\(String(cString: strerror(errno)))")
            }
            guard close(descriptor) == 0 else {
                throw ArtifactStoreError.io("关闭 lock 失败：\(String(cString: strerror(errno)))")
            }
        } catch {
            _ = close(descriptor)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while written < rawBuffer.count {
                let result = write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    throw ArtifactStoreError.io("写文件失败：\(String(cString: strerror(errno)))")
                }
                written += result
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct ArtifactFileIdentity: Equatable, Sendable {
    var byteCount: Int64
    var sha256: String
}
