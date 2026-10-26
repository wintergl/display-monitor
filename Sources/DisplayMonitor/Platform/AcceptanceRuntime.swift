import CryptoKit
import Darwin
import DisplayMonitorCore
import Foundation
import Security

enum AcceptanceMode: String, Codable, Sendable {
    case capabilityProbe
    case finalizationFault
    case writerFault
    case diskAcceptance
}

enum AcceptancePlanPhase: String, Codable, Sendable {
    case execute
    case recover
}

enum AcceptanceWriterFault: String, Codable, Sendable {
    case beforeFirstAppend
    case afterSuccessfulFrameCount30
}

struct AcceptancePlan: Codable, Sendable {
    let mode: AcceptanceMode
    let phase: AcceptancePlanPhase
    let nonce: UUID
    let expiresAt: Date
    let bundleVersion: String
    let teamID: String
    let executableCDHash: String
    let artifactRoot: String
    let combination: CaptureConcurrencyCombination?
    let volumeName: String?
    let volumeUUID: String?
    let finalizationFault: ArtifactFinalizationFault?
    let writerFault: AcceptanceWriterFault?
    let recoveryOfNonce: UUID?
}

struct ExecutableSigningIdentity: Equatable, Sendable {
    let teamID: String
    let cdHash: String

    static func current(bundle: Bundle = .main) throws -> ExecutableSigningIdentity {
        guard let executableURL = bundle.executableURL else {
            throw AcceptanceValidationError.signingIdentityUnavailable
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw AcceptanceValidationError.signingIdentityUnavailable
        }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let cdHashData = information[kSecCodeInfoUnique] as? Data else {
            throw AcceptanceValidationError.signingIdentityUnavailable
        }
        let teamID = information[kSecCodeInfoTeamIdentifier] as? String ?? "UNSIGNED"
        let cdHash = cdHashData.map { String(format: "%02x", $0) }.joined()
        return ExecutableSigningIdentity(teamID: teamID, cdHash: cdHash)
    }
}

struct AcceptanceContext: @unchecked Sendable {
    let plan: AcceptancePlan
    let planURL: URL
    let artifactRoot: URL
    let reporter: AcceptanceReporter

    var configuredFinalizationFault: ArtifactFinalizationFault {
        plan.mode == .finalizationFault ? plan.finalizationFault ?? .none : .none
    }

    var writerFault: AcceptanceWriterFault? {
        plan.mode == .writerFault ? plan.writerFault : nil
    }
}

enum AcceptanceRuntime {
    static func loadIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        now: Date = Date(),
        uid: uid_t = getuid()
    ) throws -> AcceptanceContext? {
        let matches = arguments.indices.filter { arguments[$0] == "--acceptance-plan" }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1,
              let index = matches.first,
              arguments.indices.contains(index + 1) else {
            throw AcceptanceValidationError.invalidArgument
        }
        let rawPlanPath = arguments[index + 1]
        guard rawPlanPath.hasPrefix("/private/tmp/DisplayMonitorAcceptance/"),
              rawPlanPath.hasSuffix("/plan.json") else {
            throw AcceptanceValidationError.invalidPlanLocation
        }
        let planURL = URL(fileURLWithPath: rawPlanPath)
        guard planURL.path.hasPrefix("/private/tmp/DisplayMonitorAcceptance/"),
              planURL.lastPathComponent == "plan.json" else {
            throw AcceptanceValidationError.invalidPlanLocation
        }
        let runDirectory = planURL.deletingLastPathComponent()
        guard UUID(uuidString: runDirectory.lastPathComponent) != nil,
              runDirectory.deletingLastPathComponent().path ==
                "/private/tmp/DisplayMonitorAcceptance" else {
            throw AcceptanceValidationError.invalidPlanLocation
        }
        try validateNode(runDirectory, type: .directory, permissions: 0o700, uid: uid)
        try validateNode(planURL, type: .regularFile, permissions: 0o600, uid: uid)

        let planData = try Data(contentsOf: planURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(AcceptancePlan.self, from: planData)
        guard plan.expiresAt >= now,
              plan.expiresAt.timeIntervalSince(now) <= 10 * 60 else {
            throw AcceptanceValidationError.expiredPlan
        }

        let currentBundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let identity = try ExecutableSigningIdentity.current(bundle: bundle)
        guard plan.bundleVersion == currentBundleVersion,
              plan.teamID == identity.teamID,
              plan.executableCDHash.caseInsensitiveCompare(identity.cdHash) == .orderedSame else {
            throw AcceptanceValidationError.executableIdentityMismatch
        }
        try validateModeFields(plan)

        let artifactRoot = URL(fileURLWithPath: plan.artifactRoot).standardizedFileURL
        try validateArtifactRoot(
            artifactRoot,
            runDirectory: runDirectory,
            plan: plan,
            identity: identity,
            fileManager: fileManager,
            uid: uid
        )
        try consumeNonce(plan.nonce, in: runDirectory)

        let planSHA256 = SHA256.hash(data: planData)
            .map { String(format: "%02x", $0) }.joined()
        if plan.phase == .execute {
            let receipt = AcceptanceExecutionReceipt(
                nonce: plan.nonce,
                mode: plan.mode,
                artifactRoot: artifactRoot.path,
                bundleVersion: plan.bundleVersion,
                teamID: plan.teamID,
                executableCDHash: plan.executableCDHash,
                planSHA256: planSHA256
            )
            try writeReceipt(receipt, in: runDirectory)
        }
        let reporter = AcceptanceReporter(
            reportURL: runDirectory.appendingPathComponent("acceptance-report.jsonl"),
            planSHA256: planSHA256,
            nonce: plan.nonce
        )
        reporter.record(event: "acceptance.plan.validated", fields: [
            "mode": plan.mode.rawValue,
            "phase": plan.phase.rawValue,
            "artifactRoot": artifactRoot.path
        ])
        return AcceptanceContext(
            plan: plan,
            planURL: planURL,
            artifactRoot: artifactRoot,
            reporter: reporter
        )
    }

    private static func validateModeFields(_ plan: AcceptancePlan) throws {
        switch plan.mode {
        case .finalizationFault:
            guard let fault = plan.finalizationFault, fault != .none,
                  plan.writerFault == nil else {
                throw AcceptanceValidationError.invalidModeFields
            }
        case .writerFault:
            guard plan.writerFault != nil, plan.finalizationFault == nil else {
                throw AcceptanceValidationError.invalidModeFields
            }
        case .capabilityProbe, .diskAcceptance:
            guard plan.writerFault == nil, plan.finalizationFault == nil else {
                throw AcceptanceValidationError.invalidModeFields
            }
        }
        if plan.mode == .capabilityProbe {
            guard plan.combination != nil else {
                throw AcceptanceValidationError.invalidModeFields
            }
        } else if plan.combination != nil {
            throw AcceptanceValidationError.invalidModeFields
        }
        if plan.volumeName != nil || plan.volumeUUID != nil {
            guard plan.mode == .diskAcceptance,
                  let volumeName = plan.volumeName,
                  let volumeUUID = plan.volumeUUID,
                  volumeName.hasPrefix("DisplayMonitorAcceptance-"),
                  !volumeName.contains("/"),
                  volumeName != ".",
                  volumeName != "..",
                  !volumeUUID.isEmpty else {
                throw AcceptanceValidationError.invalidModeFields
            }
        }
        if plan.phase == .execute {
            guard plan.recoveryOfNonce == nil else {
                throw AcceptanceValidationError.invalidRecoveryPhase
            }
        } else {
            guard plan.recoveryOfNonce != nil else {
                throw AcceptanceValidationError.invalidRecoveryPhase
            }
        }
    }

    private static func validateArtifactRoot(
        _ root: URL,
        runDirectory: URL,
        plan: AcceptancePlan,
        identity: ExecutableSigningIdentity,
        fileManager: FileManager,
        uid: uid_t
    ) throws {
        let rootPath = root.standardizedFileURL.path
        let runPath = runDirectory.standardizedFileURL.path
        let rootParentPath = root.deletingLastPathComponent().standardizedFileURL.path
        let isRunDirectoryRoot = rootParentPath == runPath
        let isAcceptanceVolumeRoot: Bool
        if !isRunDirectoryRoot,
           plan.mode == .diskAcceptance,
           let volumeName = plan.volumeName,
           let volumeUUID = plan.volumeUUID,
           volumeName.hasPrefix("DisplayMonitorAcceptance-") {
            let volumeRoot = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
            let values = try volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey])
            isAcceptanceVolumeRoot = rootParentPath == volumeRoot.standardizedFileURL.path &&
                values.volumeUUIDString == volumeUUID
            if isAcceptanceVolumeRoot {
                try ensureNoSymlinkComponents(from: volumeRoot, to: root)
            }
        } else {
            isAcceptanceVolumeRoot = false
        }
        guard isRunDirectoryRoot || isAcceptanceVolumeRoot,
              rootPath != runPath,
              rootPath != ArtifactStore.defaultRootURL().standardizedFileURL.path,
              rootPath != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else {
            throw AcceptanceValidationError.invalidArtifactRoot
        }
        if isRunDirectoryRoot {
            try ensureNoSymlinkComponents(from: runDirectory, to: root)
        }

        let exists = fileManager.fileExists(atPath: root.path)
        if exists {
            try validateNode(root, type: .directory, permissions: 0o700, uid: uid)
        } else {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let contents = try fileManager.contentsOfDirectory(atPath: root.path)
        switch plan.phase {
        case .execute:
            guard contents.isEmpty else {
                throw AcceptanceValidationError.nonEmptyExecutionRoot
            }
        case .recover:
            guard let priorNonce = plan.recoveryOfNonce else {
                throw AcceptanceValidationError.invalidRecoveryPhase
            }
            let receipt = try readReceipt(priorNonce, in: runDirectory)
            guard receipt.nonce == priorNonce,
                  receipt.mode == plan.mode,
                  URL(fileURLWithPath: receipt.artifactRoot).standardizedFileURL.path == rootPath,
                  receipt.bundleVersion == plan.bundleVersion,
                  receipt.teamID == identity.teamID,
                  receipt.executableCDHash.caseInsensitiveCompare(identity.cdHash) == .orderedSame else {
                throw AcceptanceValidationError.recoveryReceiptMismatch
            }
        }
    }

    private static func validateNode(
        _ url: URL,
        type: AcceptanceNodeType,
        permissions: Int,
        uid: uid_t
    ) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw AcceptanceValidationError.invalidFileMetadata
        }
        let fileType = information.st_mode & S_IFMT
        let expected: mode_t = type == .directory ? S_IFDIR : S_IFREG
        guard fileType == expected,
              information.st_uid == uid,
              Int(information.st_mode & 0o777) == permissions else {
            throw AcceptanceValidationError.invalidFileMetadata
        }
    }

    private static func ensureNoSymlinkComponents(from base: URL, to target: URL) throws {
        let relative = target.path.dropFirst(base.path.count)
            .split(separator: "/").map(String.init)
        var current = base
        for component in relative {
            current.appendPathComponent(component)
            var information = stat()
            if lstat(current.path, &information) == 0,
               information.st_mode & S_IFMT == S_IFLNK {
                throw AcceptanceValidationError.symlinkNotAllowed
            }
        }
    }

    private static func consumeNonce(_ nonce: UUID, in runDirectory: URL) throws {
        let url = runDirectory.appendingPathComponent(".nonce-\(nonce.uuidString).consumed")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AcceptanceValidationError.nonceAlreadyConsumed }
        defer { close(descriptor) }
        let bytes = Array(nonce.uuidString.utf8)
        guard bytes.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == bytes.count,
              fsync(descriptor) == 0 else {
            throw AcceptanceValidationError.nonceConsumptionFailed
        }
    }

    private static func writeReceipt(
        _ receipt: AcceptanceExecutionReceipt,
        in runDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let url = receiptURL(receipt.nonce, in: runDirectory)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AcceptanceValidationError.receiptAlreadyExists }
        defer { close(descriptor) }
        guard data.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == data.count,
              fsync(descriptor) == 0 else {
            throw AcceptanceValidationError.receiptWriteFailed
        }
    }

    private static func readReceipt(
        _ nonce: UUID,
        in runDirectory: URL
    ) throws -> AcceptanceExecutionReceipt {
        let url = receiptURL(nonce, in: runDirectory)
        try validateNode(url, type: .regularFile, permissions: 0o600, uid: getuid())
        return try JSONDecoder().decode(
            AcceptanceExecutionReceipt.self,
            from: Data(contentsOf: url)
        )
    }

    private static func receiptURL(_ nonce: UUID, in runDirectory: URL) -> URL {
        runDirectory.appendingPathComponent("execution-\(nonce.uuidString).receipt.json")
    }
}

final class AcceptanceReporter: @unchecked Sendable {
    private let reportURL: URL
    private let planSHA256: String
    private let nonce: UUID
    private let lock = NSLock()

    init(reportURL: URL, planSHA256: String, nonce: UUID) {
        self.reportURL = reportURL
        self.planSHA256 = planSHA256
        self.nonce = nonce
    }

    func record(event: String, fields: [String: String] = [:]) {
        lock.withLock {
            var payload = fields
            payload["event"] = event
            payload["nonce"] = nonce.uuidString
            payload["planSHA256"] = planSHA256
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return
            }
            let descriptor = open(reportURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            _ = "\n".utf8CString.withUnsafeBytes { write(descriptor, $0.baseAddress, 1) }
            _ = fsync(descriptor)
        }
    }

    func snapshotData() -> Data {
        lock.withLock {
            (try? Data(contentsOf: reportURL)) ?? Data()
        }
    }

    func hitFinalizationFault(
        _ point: ArtifactFinalizationFault,
        manifest: ArtifactManifest
    ) -> Never {
        record(event: "acceptance.finalizationFault.hit", fields: [
            "point": point.rawValue,
            "operationID": manifest.activeOperationID.uuidString,
            "artifactID": manifest.id.uuidString,
            "commitSequence": String(manifest.commitSequence),
            "commitPhase": manifest.commitPhase.rawValue,
            "status": manifest.status.rawValue,
            "temporaryExists": String(FileManager.default.fileExists(atPath: manifest.temporaryURL.path)),
            "canonicalExists": String(FileManager.default.fileExists(atPath: manifest.canonicalURL.path))
        ])
        _exit(86)
    }
}

private struct AcceptanceExecutionReceipt: Codable {
    let nonce: UUID
    let mode: AcceptanceMode
    let artifactRoot: String
    let bundleVersion: String
    let teamID: String
    let executableCDHash: String
    let planSHA256: String
}

private enum AcceptanceNodeType {
    case directory
    case regularFile
}

enum AcceptanceValidationError: LocalizedError, Equatable {
    case invalidArgument
    case invalidPlanLocation
    case invalidFileMetadata
    case expiredPlan
    case signingIdentityUnavailable
    case executableIdentityMismatch
    case invalidModeFields
    case invalidRecoveryPhase
    case invalidArtifactRoot
    case symlinkNotAllowed
    case nonEmptyExecutionRoot
    case recoveryReceiptMismatch
    case nonceAlreadyConsumed
    case nonceConsumptionFailed
    case receiptAlreadyExists
    case receiptWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidArgument: "--acceptance-plan 参数无效"
        case .invalidPlanLocation: "acceptance plan 路径不在专用 run 目录"
        case .invalidFileMetadata: "acceptance plan/目录 owner、权限或类型无效"
        case .expiredPlan: "acceptance plan 已过期或有效期超过 10 分钟"
        case .signingIdentityUnavailable: "无法读取当前可执行文件签名身份"
        case .executableIdentityMismatch: "acceptance plan 与当前签名二进制不匹配"
        case .invalidModeFields: "acceptance mode 与 fault 字段不匹配"
        case .invalidRecoveryPhase: "acceptance recovery phase 缺少合法前序 nonce"
        case .invalidArtifactRoot: "acceptance artifactRoot 越界或指向受保护路径"
        case .symlinkNotAllowed: "acceptance 路径不允许 symlink"
        case .nonEmptyExecutionRoot: "execute phase 不允许使用非空 artifactRoot"
        case .recoveryReceiptMismatch: "recovery root 与前序 execution receipt 不匹配"
        case .nonceAlreadyConsumed: "acceptance nonce 已消费"
        case .nonceConsumptionFailed: "acceptance nonce 无法持久化"
        case .receiptAlreadyExists: "acceptance execution receipt 已存在"
        case .receiptWriteFailed: "acceptance execution receipt 无法持久化"
        }
    }
}
