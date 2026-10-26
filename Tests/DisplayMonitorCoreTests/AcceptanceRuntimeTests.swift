import Foundation
import XCTest
@testable import DisplayMonitor

final class AcceptanceRuntimeTests: XCTestCase {
    func testNormalLaunchDoesNotReadAcceptanceConfiguration() throws {
        XCTAssertNil(try AcceptanceRuntime.loadIfRequested(arguments: ["DisplayMonitor"]))
    }

    func testValidExecutionPlanConsumesNonceExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = fixture.makePlan(phase: .execute)
        try fixture.write(plan: plan)

        let context = try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        XCTAssertEqual(context?.artifactRoot.standardizedFileURL.path, fixture.artifactRoot.standardizedFileURL.path)
        XCTAssertThrowsError(
            try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        ) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .nonceAlreadyConsumed)
        }
    }

    func testRecoveryPlanCanReuseOnlyReceiptedNonEmptyRootWithNewNonce() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let execution = fixture.makePlan(phase: .execute)
        try fixture.write(plan: execution)
        _ = try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        try Data("prior artifact".utf8).write(
            to: fixture.artifactRoot.appendingPathComponent("prior.txt")
        )

        let recovery = fixture.makePlan(
            phase: .recover,
            nonce: UUID(),
            recoveryOfNonce: execution.nonce
        )
        try fixture.write(plan: recovery)
        let context = try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)

        XCTAssertEqual(context?.plan.phase, .recover)
        XCTAssertEqual(context?.artifactRoot.standardizedFileURL.path, fixture.artifactRoot.standardizedFileURL.path)
    }

    func testExecutionPlanRejectsNonEmptyRoot() throws {
        let fixture = try makeFixture(createRoot: true)
        defer { fixture.cleanup() }
        try Data("do not reuse".utf8).write(
            to: fixture.artifactRoot.appendingPathComponent("existing.txt")
        )
        try fixture.write(plan: fixture.makePlan(phase: .execute))

        XCTAssertThrowsError(
            try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        ) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .nonEmptyExecutionRoot)
        }
    }

    func testPlanRequiresOwnerOnlyPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.write(plan: fixture.makePlan(phase: .execute))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.planURL.path
        )

        XCTAssertThrowsError(
            try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        ) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .invalidFileMetadata)
        }
    }

    func testExpiredPlanIsRejectedBeforeArtifactRootCreation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = fixture.makePlan(
            phase: .execute,
            expiresAt: Date(timeIntervalSinceNow: -1)
        )
        try fixture.write(plan: plan)

        XCTAssertThrowsError(
            try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        ) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .expiredPlan)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactRoot.path))
    }

    func testExternalVolumeNameCannotEscapeVolumesDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = fixture.makePlan(
            phase: .execute,
            volumeName: "DisplayMonitorAcceptance-test/../escape",
            volumeUUID: UUID().uuidString
        )
        try fixture.write(plan: plan)

        XCTAssertThrowsError(
            try AcceptanceRuntime.loadIfRequested(arguments: fixture.arguments)
        ) { error in
            XCTAssertEqual(error as? AcceptanceValidationError, .invalidModeFields)
        }
    }

    private func makeFixture(createRoot: Bool = false) throws -> AcceptanceFixture {
        let base = URL(fileURLWithPath: "/private/tmp/DisplayMonitorAcceptance", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runDirectory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let artifactRoot = runDirectory.appendingPathComponent("artifacts", isDirectory: true)
        if createRoot {
            try FileManager.default.createDirectory(
                at: artifactRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return try AcceptanceFixture(runDirectory: runDirectory, artifactRoot: artifactRoot)
    }
}

private struct AcceptanceFixture {
    let runDirectory: URL
    let artifactRoot: URL
    let planURL: URL
    let identity: ExecutableSigningIdentity
    let bundleVersion: String

    init(runDirectory: URL, artifactRoot: URL) throws {
        self.runDirectory = runDirectory
        self.artifactRoot = artifactRoot
        planURL = runDirectory.appendingPathComponent("plan.json")
        identity = try ExecutableSigningIdentity.current()
        bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var arguments: [String] {
        ["DisplayMonitor", "--acceptance-plan", planURL.path]
    }

    func makePlan(
        phase: AcceptancePlanPhase,
        nonce: UUID = UUID(),
        recoveryOfNonce: UUID? = nil,
        expiresAt: Date = Date(timeIntervalSinceNow: 5 * 60),
        volumeName: String? = nil,
        volumeUUID: String? = nil
    ) -> AcceptancePlan {
        AcceptancePlan(
            mode: .diskAcceptance,
            phase: phase,
            nonce: nonce,
            expiresAt: expiresAt,
            bundleVersion: bundleVersion,
            teamID: identity.teamID,
            executableCDHash: identity.cdHash,
            artifactRoot: artifactRoot.path,
            combination: nil,
            volumeName: volumeName,
            volumeUUID: volumeUUID,
            finalizationFault: nil,
            writerFault: nil,
            recoveryOfNonce: recoveryOfNonce
        )
    }

    func write(plan: AcceptancePlan) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(plan).write(to: planURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: planURL.path
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: runDirectory)
    }
}
