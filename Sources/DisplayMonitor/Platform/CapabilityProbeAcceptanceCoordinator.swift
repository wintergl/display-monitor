import DisplayMonitorCore
import Foundation

actor CapabilityProbeAcceptanceCoordinator {
    private let context: AcceptanceContext
    private let provider: CaptureConcurrencyCapabilityProvider
    private var roundPolicy = CapabilityProbeRoundPolicy()
    private var terminalEvidenceID: String?

    init(
        context: AcceptanceContext,
        provider: CaptureConcurrencyCapabilityProvider
    ) {
        self.context = context
        self.provider = provider
    }

    func recordRound(
        artifact: ArtifactManifest,
        monitorCompleteFrameDelta: UInt64,
        monitorHealthy: Bool,
        activeResourceCount: Int
    ) async {
        guard terminalEvidenceID == nil,
              context.plan.mode == .capabilityProbe,
              context.plan.phase == .execute,
              let combination = context.plan.combination else { return }

        let duration = artifact.durationSeconds ?? 0
        let round = CapabilityProbeRound(
            durationSeconds: duration,
            recordingFrameCount: artifact.status == .completed ? artifact.frameCount ?? 0 : 0,
            monitorCompleteFrameDelta: monitorCompleteFrameDelta,
            monitorHealthy: monitorHealthy,
            activeResourceCount: activeResourceCount
        )
        let progress = roundPolicy.consume(round)
        context.reporter.record(event: "acceptance.capabilityProbe.round", fields: [
            "succeeded": String(round.passed),
            "durationSeconds": String(duration),
            "recordingFrameCount": String(artifact.frameCount ?? 0),
            "monitorCompleteFrameDelta": String(monitorCompleteFrameDelta),
            "monitorHealthy": String(monitorHealthy),
            "activeResourceCount": String(activeResourceCount),
            "artifactID": artifact.id.uuidString
        ])

        switch progress {
        case .continueProbe, .alreadyTerminal:
            return
        case .commit(let result):
            await commit(result: result, combination: combination)
        }
    }

    private func commit(
        result: CaptureConcurrencyEvidenceResult,
        combination: CaptureConcurrencyCombination
    ) async {
        let provisionalEvidenceID = "provisional-\(context.plan.nonce.uuidString)"
        do {
            let evidence = try await provider.commitLocalAcceptance(
                combination: combination,
                result: result,
                immutableReportData: context.reporter.snapshotData()
            )
            terminalEvidenceID = evidence.evidenceID
            context.reporter.record(event: "acceptance.capabilityProbe.committed", fields: [
                "result": result.rawValue,
                "evidenceID": evidence.evidenceID,
                "generation": String(evidence.generation ?? 0)
            ])
        } catch {
            terminalEvidenceID = "commit-failed"
            context.reporter.record(event: "acceptance.capabilityProbe.commitFailed", fields: [
                "result": result.rawValue,
                "error": error.localizedDescription
            ])
        }
        await provider.revokeProvisionalProbe(evidenceID: provisionalEvidenceID)
        context.reporter.record(event: "acceptance.capabilityProbe.provisionalRevoked", fields: [
            "evidenceID": provisionalEvidenceID
        ])
    }
}
