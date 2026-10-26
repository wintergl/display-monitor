import CoreGraphics
import CryptoKit
import ColorSync
import Darwin
import DisplayMonitorCore
import Foundation
import Security

actor CaptureConcurrencyCapabilityProvider: CaptureConcurrencyCapabilityProviding {
    static let policyRevision = "recording-v1"

    private let bundle: Bundle
    private let fileManager: FileManager
    private var provisionalProbe: (combination: CaptureConcurrencyCombination, evidenceID: String)?

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        provisionalProbe: (combination: CaptureConcurrencyCombination, evidenceID: String)? = nil
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.provisionalProbe = provisionalProbe
    }

    func capability(for combination: CaptureConcurrencyCombination) async -> CaptureSlotCapability {
        do {
            let runtimeKey = try makeRuntimeKey(combination: combination)
            let bundled = try loadBundledEvidence()
            let local = try loadLocalEvidence()
            let anchor = try loadLocalHeadAnchor(for: runtimeKey)
            if let provisionalProbe, provisionalProbe.combination == combination {
                let bundledOnly = CaptureConcurrencyEvidenceEvaluator.evaluate(
                    runtimeKey: runtimeKey,
                    bundledEvidence: bundled,
                    localEvidence: [],
                    localHeadAnchor: nil
                )
                if case .denied = bundledOnly {
                    return bundledOnly
                }
                return .allowed(evidenceID: provisionalProbe.evidenceID)
            }
            return CaptureConcurrencyEvidenceEvaluator.evaluate(
                runtimeKey: runtimeKey,
                bundledEvidence: bundled,
                localEvidence: local,
                localHeadAnchor: anchor
            )
        } catch {
            return .unknown("并发采集证据不可用：\(error.localizedDescription)")
        }
    }

    func runtimeKey(
        for combination: CaptureConcurrencyCombination
    ) throws -> CaptureConcurrencyEvidenceKey {
        try makeRuntimeKey(combination: combination)
    }

    func revokeProvisionalProbe(evidenceID: String) {
        guard provisionalProbe?.evidenceID == evidenceID else { return }
        provisionalProbe = nil
    }

    func commitLocalAcceptance(
        combination: CaptureConcurrencyCombination,
        result: CaptureConcurrencyEvidenceResult,
        immutableReportData: Data
    ) throws -> CaptureConcurrencyEvidence {
        let key = try makeRuntimeKey(combination: combination)
        var evidence = try loadLocalEvidence()
        let anchor = try loadLocalHeadAnchor(for: key)
        let exactRecords = evidence.filter { $0.key == key && $0.source == .localAcceptance }
        let generation: Int
        let supersedesEvidenceID: String?
        if let anchor {
            guard exactRecords.contains(where: { $0.evidenceID == anchor.evidenceID }) else {
                throw CapabilityProviderError.localEvidenceChainInvalid
            }
            generation = anchor.generation + 1
            supersedesEvidenceID = anchor.evidenceID
        } else {
            guard exactRecords.isEmpty else {
                throw CapabilityProviderError.localEvidenceChainInvalid
            }
            generation = 1
            supersedesEvidenceID = nil
        }

        let evidenceID = UUID().uuidString
        let reportFileName = "\(evidenceID).jsonl"
        let reportSHA256 = Self.sha256(immutableReportData)
        try ensureLocalEvidenceDirectory()
        let reportURL = localReportsDirectory().appendingPathComponent(reportFileName)
        try atomicOwnerOnlyWrite(immutableReportData, to: reportURL)

        let record = CaptureConcurrencyEvidence(
            evidenceID: evidenceID,
            key: key,
            result: result,
            source: .localAcceptance,
            reportSHA256: reportSHA256,
            reportFileName: reportFileName,
            createdAt: Date(),
            generation: generation,
            supersedesEvidenceID: supersedesEvidenceID
        )
        evidence.append(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try atomicOwnerOnlyWrite(try encoder.encode(evidence), to: try localEvidenceURL())
        let newAnchor = CaptureConcurrencyLocalHeadAnchor(
            key: key,
            evidenceID: evidenceID,
            generation: generation,
            reportSHA256: reportSHA256
        )
        try persistLocalHeadAnchor(newAnchor)
        return record
    }

    private func makeRuntimeKey(
        combination: CaptureConcurrencyCombination
    ) throws -> CaptureConcurrencyEvidenceKey {
        let signing = try signingIdentity()
        return CaptureConcurrencyEvidenceKey(
            policyRevision: Self.policyRevision,
            combination: combination,
            appBundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            executableCDHash: signing.cdHash,
            teamID: signing.teamID,
            osProductVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: systemValue(named: "kern.osversion"),
            hardwareModelIdentifier: systemValue(named: "hw.model"),
            displayTopologyFingerprint: try displayTopologyFingerprint()
        )
    }

    private func signingIdentity() throws -> (teamID: String, cdHash: String?) {
        guard let identity = try? ExecutableSigningIdentity.current(bundle: bundle) else {
            throw CapabilityProviderError.signingIdentityUnavailable
        }
        return (identity.teamID, identity.cdHash)
    }

    private func displayTopologyFingerprint() throws -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw CapabilityProviderError.displayTopologyUnavailable
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            throw CapabilityProviderError.displayTopologyUnavailable
        }
        let descriptors = displayIDs.prefix(Int(count)).map { displayID -> String in
            let uuidReference = CGDisplayCreateUUIDFromDisplayID(displayID)
            let uuid = uuidReference.map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? "unknown"
            let bounds = CGDisplayBounds(displayID)
            let pixelWidth = CGDisplayPixelsWide(displayID)
            let pixelHeight = CGDisplayPixelsHigh(displayID)
            let scale = bounds.width > 0 ? Double(pixelWidth) / bounds.width : 0
            let mirroredDisplay = CGDisplayMirrorsDisplay(displayID)
            return [
                uuid,
                "\(pixelWidth)x\(pixelHeight)",
                String(format: "%.1f,%.1f,%.1f,%.1f", bounds.origin.x, bounds.origin.y, bounds.width, bounds.height),
                String(format: "%.4f", scale),
                String(format: "%.1f", CGDisplayRotation(displayID)),
                "main=\(CGDisplayIsMain(displayID))",
                "mirrored=\(CGDisplayIsInMirrorSet(displayID))",
                "mirrors=\(mirroredDisplay)"
            ].joined(separator: "|")
        }.sorted()
        let digest = SHA256.hash(data: Data(descriptors.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadBundledEvidence() throws -> [CaptureConcurrencyEvidence] {
        guard let url = bundle.url(
            forResource: "capture-concurrency-matrix-v1",
            withExtension: "json"
        ) ?? Bundle.module.url(
            forResource: "capture-concurrency-matrix-v1",
            withExtension: "json"
        ) else {
            return []
        }
        return try decodeEvidence(at: url, requireOwnerOnly: false)
    }

    private func loadLocalEvidence() throws -> [CaptureConcurrencyEvidence] {
        let url = try localEvidenceURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let evidence = try decodeEvidence(at: url, requireOwnerOnly: true)
        for record in evidence where record.source == .localAcceptance {
            guard let fileName = record.reportFileName,
                  fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
                throw CapabilityProviderError.localReportInvalid
            }
            let reportURL = localReportsDirectory().appendingPathComponent(fileName)
            let resourceValues = try reportURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let attributes = try fileManager.attributesOfItem(atPath: reportURL.path)
            guard resourceValues.isRegularFile == true,
                  resourceValues.isSymbolicLink != true,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  Self.sha256(try Data(contentsOf: reportURL)) == record.reportSHA256 else {
                throw CapabilityProviderError.localReportInvalid
            }
        }
        return evidence
    }

    private func decodeEvidence(
        at url: URL,
        requireOwnerOnly: Bool
    ) throws -> [CaptureConcurrencyEvidence] {
        let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard resourceValues.isSymbolicLink != true, resourceValues.isRegularFile == true else {
            throw CapabilityProviderError.invalidEvidenceFile
        }
        if requireOwnerOnly {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw CapabilityProviderError.invalidEvidencePermissions
            }
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder.captureEvidence.decode([CaptureConcurrencyEvidence].self, from: data)
    }

    private func localEvidenceURL() throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CapabilityProviderError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("capture-concurrency-local-v1.json", isDirectory: false)
    }

    private func localEvidenceDirectory() throws -> URL {
        try localEvidenceURL().deletingLastPathComponent()
    }

    private func localReportsDirectory() -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("capture-concurrency-reports-v1", isDirectory: true)
    }

    private func ensureLocalEvidenceDirectory() throws {
        for directory in [try localEvidenceDirectory(), localReportsDirectory()] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    private func atomicOwnerOnlyWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CapabilityProviderError.localEvidenceWriteFailed }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { try? fileManager.removeItem(at: temporary) }
        }
        let wrote = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard wrote == data.count, fsync(descriptor) == 0 else {
            throw CapabilityProviderError.localEvidenceWriteFailed
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw CapabilityProviderError.localEvidenceWriteFailed
        }
        shouldRemove = false
        let directoryDescriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private func persistLocalHeadAnchor(
        _ anchor: CaptureConcurrencyLocalHeadAnchor
    ) throws {
        let account = try evidenceKeyDigest(anchor.key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(anchor)
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(AppConstants.bundleIdentifier).capture-concurrency-head-v1",
            kSecAttrAccount: account
        ]
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CapabilityProviderError.anchorUnavailable(updateStatus)
        }
        var insertion = base
        insertion[kSecValueData] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CapabilityProviderError.anchorUnavailable(addStatus)
        }
    }

    private func loadLocalHeadAnchor(
        for key: CaptureConcurrencyEvidenceKey
    ) throws -> CaptureConcurrencyLocalHeadAnchor? {
        let account = try evidenceKeyDigest(key)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(AppConstants.bundleIdentifier).capture-concurrency-head-v1",
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CapabilityProviderError.anchorUnavailable(status)
        }
        return try JSONDecoder.captureEvidence.decode(
            CaptureConcurrencyLocalHeadAnchor.self,
            from: data
        )
    }

    private func evidenceKeyDigest(_ key: CaptureConcurrencyEvidenceKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(key))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func systemValue(named name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: content, as: UTF8.self)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum CapabilityProviderError: LocalizedError {
    case signingIdentityUnavailable
    case displayTopologyUnavailable
    case invalidEvidenceFile
    case invalidEvidencePermissions
    case applicationSupportUnavailable
    case anchorUnavailable(OSStatus)
    case localEvidenceChainInvalid
    case localReportInvalid
    case localEvidenceWriteFailed

    var errorDescription: String? {
        switch self {
        case .signingIdentityUnavailable: "无法读取当前可执行文件签名身份"
        case .displayTopologyUnavailable: "无法读取当前显示器拓扑"
        case .invalidEvidenceFile: "并发采集证据文件类型无效"
        case .invalidEvidencePermissions: "本机验收证据必须由当前用户所有且权限为 0600"
        case .applicationSupportUnavailable: "无法定位 Application Support"
        case .anchorUnavailable(let status): "无法读取本机验收 head anchor（\(status)）"
        case .localEvidenceChainInvalid: "本机验收 supersedes 链无效"
        case .localReportInvalid: "本机验收报告缺失或摘要不匹配"
        case .localEvidenceWriteFailed: "本机验收证据无法原子写入"
        }
    }
}

private extension JSONDecoder {
    static var captureEvidence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
