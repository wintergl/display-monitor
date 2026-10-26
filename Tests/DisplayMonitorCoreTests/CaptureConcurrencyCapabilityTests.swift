import XCTest
@testable import DisplayMonitorCore

final class CaptureConcurrencyCapabilityTests: XCTestCase {
    func testSingleRecordingDoesNotRequireCapabilityEvidence() {
        XCTAssertEqual(
            CaptureResourcePolicy.requiredCombinations(
                requested: .recording,
                active: [],
                monitorActive: false
            ),
            []
        )
        XCTAssertEqual(
            CaptureResourcePolicy.decision(
                requested: .recording,
                active: [],
                monitorActive: false,
                slotCapabilities: []
            ),
            .granted
        )
    }

    func testConcurrentRecordingFailsClosedWhenCapabilityIsUnknown() {
        XCTAssertEqual(
            CaptureResourcePolicy.requiredCombinations(
                requested: .recording,
                active: [],
                monitorActive: true
            ),
            [.monitorRecording]
        )
        XCTAssertEqual(
            CaptureResourcePolicy.decision(
                requested: .recording,
                active: [],
                monitorActive: true,
                slotCapabilities: [.unknown("没有证据")]
            ),
            .rejected("没有证据；请关闭 Monitor 后重试")
        )
    }

    func testExactBundledAllowedEvidencePermitsCombination() {
        let key = makeKey()
        let evidence = makeEvidence(
            id: "bundled-allowed",
            key: keyWithCDHash(key, nil),
            result: .allowed,
            source: .bundledMatrix
        )

        XCTAssertEqual(
            CaptureConcurrencyEvidenceEvaluator.evaluate(
                runtimeKey: key,
                bundledEvidence: [evidence],
                localEvidence: [],
                localHeadAnchor: nil
            ),
            .allowed(evidenceID: "bundled-allowed")
        )
    }

    func testAnyRuntimeKeyChangeInvalidatesBundledEvidence() {
        let key = makeKey()
        let stale = makeEvidence(
            id: "stale",
            key: CaptureConcurrencyEvidenceKey(
                policyRevision: key.policyRevision,
                combination: key.combination,
                appBundleVersion: key.appBundleVersion,
                executableCDHash: nil,
                teamID: key.teamID,
                osProductVersion: key.osProductVersion,
                osBuild: key.osBuild,
                hardwareModelIdentifier: key.hardwareModelIdentifier,
                displayTopologyFingerprint: "different-topology"
            ),
            result: .allowed,
            source: .bundledMatrix
        )

        guard case .unknown = CaptureConcurrencyEvidenceEvaluator.evaluate(
            runtimeKey: key,
            bundledEvidence: [stale],
            localEvidence: [],
            localHeadAnchor: nil
        ) else {
            return XCTFail("key mismatch must fail closed")
        }
    }

    func testBundledDenyCannotBeOverriddenByLocalAllowed() {
        let key = makeKey()
        let bundled = makeEvidence(
            id: "hard-deny",
            key: keyWithCDHash(key, nil),
            result: .denied,
            source: .bundledMatrix
        )
        let local = makeEvidence(
            id: "local-allow",
            key: key,
            result: .allowed,
            source: .localAcceptance,
            generation: 1
        )
        let anchor = CaptureConcurrencyLocalHeadAnchor(
            key: key,
            evidenceID: local.evidenceID,
            generation: 1,
            reportSHA256: local.reportSHA256
        )

        XCTAssertEqual(
            CaptureConcurrencyEvidenceEvaluator.evaluate(
                runtimeKey: key,
                bundledEvidence: [bundled],
                localEvidence: [local],
                localHeadAnchor: anchor
            ),
            .denied(reason: "当前系统与显示器组合已被发布矩阵禁用", evidenceID: "hard-deny")
        )
    }

    func testDeletingLocalDenyDoesNotRevealBundledAllowed() {
        let key = makeKey()
        let bundled = makeEvidence(
            id: "bundled-allow",
            key: keyWithCDHash(key, nil),
            result: .allowed,
            source: .bundledMatrix
        )
        let deletedLocalDenyAnchor = CaptureConcurrencyLocalHeadAnchor(
            key: key,
            evidenceID: "deleted-deny",
            generation: 1,
            reportSHA256: "deny-report"
        )

        guard case .unknown = CaptureConcurrencyEvidenceEvaluator.evaluate(
            runtimeKey: key,
            bundledEvidence: [bundled],
            localEvidence: [],
            localHeadAnchor: deletedLocalDenyAnchor
        ) else {
            return XCTFail("a retained head anchor must make local evidence deletion fail closed")
        }
    }

    func testLocalSupersedingHeadMustBeUniqueAndMonotonic() {
        let key = makeKey()
        let denied = makeEvidence(
            id: "deny-1",
            key: key,
            result: .denied,
            source: .localAcceptance,
            generation: 1
        )
        let allowed = makeEvidence(
            id: "allow-2",
            key: key,
            result: .allowed,
            source: .localAcceptance,
            generation: 2,
            supersedes: denied.evidenceID
        )
        let anchor = CaptureConcurrencyLocalHeadAnchor(
            key: key,
            evidenceID: allowed.evidenceID,
            generation: 2,
            reportSHA256: allowed.reportSHA256
        )

        XCTAssertEqual(
            CaptureConcurrencyEvidenceEvaluator.evaluate(
                runtimeKey: key,
                bundledEvidence: [],
                localEvidence: [denied, allowed],
                localHeadAnchor: anchor
            ),
            .allowed(evidenceID: "allow-2")
        )
    }

    func testCapabilityProbeRequiresThreeCompleteTenSecondRounds() {
        var policy = CapabilityProbeRoundPolicy()
        let passing = CapabilityProbeRound(
            durationSeconds: 10,
            recordingFrameCount: 300,
            monitorCompleteFrameDelta: 300,
            monitorHealthy: true,
            activeResourceCount: 0
        )
        XCTAssertEqual(policy.consume(passing), .continueProbe(successfulRounds: 1))
        XCTAssertEqual(policy.consume(passing), .continueProbe(successfulRounds: 2))
        XCTAssertEqual(policy.consume(passing), .commit(.allowed))
        XCTAssertEqual(policy.consume(passing), .alreadyTerminal)
    }

    func testCapabilityProbeWritesDenyOnFirstIncompleteRound() {
        var policy = CapabilityProbeRoundPolicy()
        let incomplete = CapabilityProbeRound(
            durationSeconds: 9.99,
            recordingFrameCount: 299,
            monitorCompleteFrameDelta: 299,
            monitorHealthy: true,
            activeResourceCount: 0
        )
        XCTAssertEqual(policy.consume(incomplete), .commit(.denied))
        XCTAssertEqual(policy.consume(incomplete), .alreadyTerminal)
    }

    private func makeKey() -> CaptureConcurrencyEvidenceKey {
        CaptureConcurrencyEvidenceKey(
            policyRevision: "recording-v1",
            combination: .monitorRecording,
            appBundleVersion: "42",
            executableCDHash: "current-cdhash",
            teamID: "TEAMID",
            osProductVersion: "macOS 15.6",
            osBuild: "24G90",
            hardwareModelIdentifier: "Mac15,7",
            displayTopologyFingerprint: "topology"
        )
    }

    private func keyWithCDHash(
        _ key: CaptureConcurrencyEvidenceKey,
        _ cdHash: String?
    ) -> CaptureConcurrencyEvidenceKey {
        CaptureConcurrencyEvidenceKey(
            schemaVersion: key.schemaVersion,
            policyRevision: key.policyRevision,
            combination: key.combination,
            appBundleVersion: key.appBundleVersion,
            executableCDHash: cdHash,
            teamID: key.teamID,
            osProductVersion: key.osProductVersion,
            osBuild: key.osBuild,
            hardwareModelIdentifier: key.hardwareModelIdentifier,
            displayTopologyFingerprint: key.displayTopologyFingerprint
        )
    }

    private func makeEvidence(
        id: String,
        key: CaptureConcurrencyEvidenceKey,
        result: CaptureConcurrencyEvidenceResult,
        source: CaptureConcurrencyEvidenceSource,
        generation: Int? = nil,
        supersedes: String? = nil
    ) -> CaptureConcurrencyEvidence {
        CaptureConcurrencyEvidence(
            evidenceID: id,
            key: key,
            result: result,
            source: source,
            reportSHA256: "report-\(id)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: generation,
            supersedesEvidenceID: supersedes
        )
    }
}
