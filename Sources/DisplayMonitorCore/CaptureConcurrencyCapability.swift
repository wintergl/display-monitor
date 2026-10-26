import Foundation

public enum CaptureConcurrencyCombination: String, Codable, CaseIterable, Sendable {
    case monitorRecording
    case recordingStill
    case monitorScroll
}

public struct CaptureConcurrencyEvidenceKey: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let policyRevision: String
    public let combination: CaptureConcurrencyCombination
    public let appBundleVersion: String
    public let executableCDHash: String?
    public let teamID: String
    public let osProductVersion: String
    public let osBuild: String
    public let hardwareModelIdentifier: String
    public let displayTopologyFingerprint: String

    public init(
        schemaVersion: Int = 1,
        policyRevision: String,
        combination: CaptureConcurrencyCombination,
        appBundleVersion: String,
        executableCDHash: String?,
        teamID: String,
        osProductVersion: String,
        osBuild: String,
        hardwareModelIdentifier: String,
        displayTopologyFingerprint: String
    ) {
        self.schemaVersion = schemaVersion
        self.policyRevision = policyRevision
        self.combination = combination
        self.appBundleVersion = appBundleVersion
        self.executableCDHash = executableCDHash
        self.teamID = teamID
        self.osProductVersion = osProductVersion
        self.osBuild = osBuild
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.displayTopologyFingerprint = displayTopologyFingerprint
    }
}

public enum CaptureConcurrencyEvidenceResult: String, Codable, Equatable, Sendable {
    case allowed
    case denied
}

public enum CaptureConcurrencyEvidenceSource: String, Codable, Equatable, Sendable {
    case bundledMatrix
    case localAcceptance
}

public struct CaptureConcurrencyEvidence: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let key: CaptureConcurrencyEvidenceKey
    public let result: CaptureConcurrencyEvidenceResult
    public let source: CaptureConcurrencyEvidenceSource
    public let reportSHA256: String
    public let reportFileName: String?
    public let createdAt: Date
    public let generation: Int?
    public let supersedesEvidenceID: String?

    public init(
        evidenceID: String,
        key: CaptureConcurrencyEvidenceKey,
        result: CaptureConcurrencyEvidenceResult,
        source: CaptureConcurrencyEvidenceSource,
        reportSHA256: String,
        reportFileName: String? = nil,
        createdAt: Date,
        generation: Int? = nil,
        supersedesEvidenceID: String? = nil
    ) {
        self.evidenceID = evidenceID
        self.key = key
        self.result = result
        self.source = source
        self.reportSHA256 = reportSHA256
        self.reportFileName = reportFileName
        self.createdAt = createdAt
        self.generation = generation
        self.supersedesEvidenceID = supersedesEvidenceID
    }
}

/// A separately persisted monotonic pointer. Keeping it outside the replaceable
/// evidence file makes deleting a local deny fail closed instead of revealing a
/// bundled allow underneath it.
public struct CaptureConcurrencyLocalHeadAnchor: Codable, Equatable, Sendable {
    public let key: CaptureConcurrencyEvidenceKey
    public let evidenceID: String
    public let generation: Int
    public let reportSHA256: String

    public init(
        key: CaptureConcurrencyEvidenceKey,
        evidenceID: String,
        generation: Int,
        reportSHA256: String
    ) {
        self.key = key
        self.evidenceID = evidenceID
        self.generation = generation
        self.reportSHA256 = reportSHA256
    }
}

public enum CaptureSlotCapability: Equatable, Sendable {
    case notRequired
    case unknown(String)
    case allowed(evidenceID: String)
    case denied(reason: String, evidenceID: String?)
}

public protocol CaptureConcurrencyCapabilityProviding: Sendable {
    func capability(for combination: CaptureConcurrencyCombination) async -> CaptureSlotCapability
}

public enum CaptureConcurrencyEvidenceEvaluator {
    public static func evaluate(
        runtimeKey: CaptureConcurrencyEvidenceKey,
        bundledEvidence: [CaptureConcurrencyEvidence],
        localEvidence: [CaptureConcurrencyEvidence],
        localHeadAnchor: CaptureConcurrencyLocalHeadAnchor?
    ) -> CaptureSlotCapability {
        let bundled = bundledEvidence.filter {
            $0.source == .bundledMatrix && bundledKey($0.key, matches: runtimeKey)
        }
        if let hardDeny = bundled.first(where: { $0.result == .denied }) {
            return .denied(
                reason: "当前系统与显示器组合已被发布矩阵禁用",
                evidenceID: hardDeny.evidenceID
            )
        }

        let local = localEvidence.filter {
            $0.source == .localAcceptance && $0.key == runtimeKey
        }
        if !local.isEmpty || localHeadAnchor?.key == runtimeKey {
            switch validatedLocalHead(
                runtimeKey: runtimeKey,
                evidence: local,
                anchor: localHeadAnchor
            ) {
            case .success(let head):
                switch head.result {
                case .allowed:
                    return .allowed(evidenceID: head.evidenceID)
                case .denied:
                    return .denied(
                        reason: "当前机器的并发采集验收未通过",
                        evidenceID: head.evidenceID
                    )
                }
            case .failure(let failure):
                return .unknown(failure.reason)
            }
        }

        if let allowed = bundled.first(where: { $0.result == .allowed }) {
            return .allowed(evidenceID: allowed.evidenceID)
        }
        return .unknown("当前系统与显示器组合尚无精确匹配的并发采集验收证据")
    }

    private static func validatedLocalHead(
        runtimeKey: CaptureConcurrencyEvidenceKey,
        evidence: [CaptureConcurrencyEvidence],
        anchor: CaptureConcurrencyLocalHeadAnchor?
    ) -> Result<CaptureConcurrencyEvidence, LocalEvidenceFailure> {
        guard runtimeKey.executableCDHash?.isEmpty == false else {
            return .failure(.init(reason: "本机验收键缺少 executable CDHash"))
        }
        guard let anchor, anchor.key == runtimeKey else {
            return .failure(.init(reason: "本机验收 head anchor 缺失或不匹配"))
        }
        guard !anchor.reportSHA256.isEmpty else {
            return .failure(.init(reason: "本机验收 head anchor 报告摘要无效"))
        }
        guard Set(evidence.map(\.evidenceID)).count == evidence.count else {
            return .failure(.init(reason: "本机验收 evidenceID 重复"))
        }
        guard evidence.allSatisfy({
            ($0.generation ?? 0) > 0 && !$0.reportSHA256.isEmpty
        }) else {
            return .failure(.init(reason: "本机验收 generation 或报告摘要无效"))
        }

        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.evidenceID, $0) })
        for record in evidence {
            if let predecessorID = record.supersedesEvidenceID {
                guard let predecessor = byID[predecessorID],
                      let generation = record.generation,
                      let predecessorGeneration = predecessor.generation,
                      generation > predecessorGeneration else {
                    return .failure(.init(reason: "本机验收 supersedes 链损坏或 generation 回退"))
                }
            } else if record.generation != 1 {
                return .failure(.init(reason: "本机验收 generation 链缺少起点"))
            }
        }

        let supersededIDs = Set(evidence.compactMap(\.supersedesEvidenceID))
        let activeHeads = evidence.filter { !supersededIDs.contains($0.evidenceID) }
        guard activeHeads.count == 1, let head = activeHeads.first else {
            return .failure(.init(reason: "本机验收存在多个 active head"))
        }
        guard head.evidenceID == anchor.evidenceID,
              head.generation == anchor.generation,
              head.reportSHA256 == anchor.reportSHA256 else {
            return .failure(.init(reason: "本机验收记录缺失、被修改或未原子提交"))
        }
        return .success(head)
    }

    private struct LocalEvidenceFailure: Error {
        let reason: String
    }

    private static func bundledKey(
        _ candidate: CaptureConcurrencyEvidenceKey,
        matches runtime: CaptureConcurrencyEvidenceKey
    ) -> Bool {
        candidate.schemaVersion == runtime.schemaVersion &&
            candidate.policyRevision == runtime.policyRevision &&
            candidate.combination == runtime.combination &&
            candidate.appBundleVersion == runtime.appBundleVersion &&
            (candidate.executableCDHash == nil ||
                candidate.executableCDHash == runtime.executableCDHash) &&
            candidate.teamID == runtime.teamID &&
            candidate.osProductVersion == runtime.osProductVersion &&
            candidate.osBuild == runtime.osBuild &&
            candidate.hardwareModelIdentifier == runtime.hardwareModelIdentifier &&
            candidate.displayTopologyFingerprint == runtime.displayTopologyFingerprint
    }
}

public struct CapabilityProbeRound: Equatable, Sendable {
    public let durationSeconds: Double
    public let recordingFrameCount: Int
    public let monitorCompleteFrameDelta: UInt64
    public let monitorHealthy: Bool
    public let activeResourceCount: Int

    public init(
        durationSeconds: Double,
        recordingFrameCount: Int,
        monitorCompleteFrameDelta: UInt64,
        monitorHealthy: Bool,
        activeResourceCount: Int
    ) {
        self.durationSeconds = durationSeconds
        self.recordingFrameCount = recordingFrameCount
        self.monitorCompleteFrameDelta = monitorCompleteFrameDelta
        self.monitorHealthy = monitorHealthy
        self.activeResourceCount = activeResourceCount
    }

    public var passed: Bool {
        durationSeconds >= 10 && recordingFrameCount > 0 &&
            monitorCompleteFrameDelta > 0 && monitorHealthy && activeResourceCount == 0
    }
}

public enum CapabilityProbeProgress: Equatable, Sendable {
    case continueProbe(successfulRounds: Int)
    case commit(CaptureConcurrencyEvidenceResult)
    case alreadyTerminal
}

public struct CapabilityProbeRoundPolicy: Equatable, Sendable {
    public static let requiredSuccessfulRounds = 3

    private var successfulRounds = 0
    private var isTerminal = false

    public init() {}

    public mutating func consume(_ round: CapabilityProbeRound) -> CapabilityProbeProgress {
        guard !isTerminal else { return .alreadyTerminal }
        guard round.passed else {
            isTerminal = true
            return .commit(.denied)
        }
        successfulRounds += 1
        if successfulRounds == Self.requiredSuccessfulRounds {
            isTerminal = true
            return .commit(.allowed)
        }
        return .continueProbe(successfulRounds: successfulRounds)
    }
}
