import DisplayMonitorCore
import Foundation
import OSLog

/// Serializes product-level ScreenCaptureKit requests. It does not claim a
/// platform slot is safe until a per-OS preflight has passed; real hardware
/// acceptance still remains a separate gate.
@MainActor
final class CaptureResourceCoordinator {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "CaptureResources")
    private let capabilityProvider: any CaptureConcurrencyCapabilityProviding
    private var active: Set<CaptureResourceKind> = []
    private var optionalStillToken: UUID?
    private var pendingAcquisitions = 0
    private var isTerminating = false

    var activeResources: Set<CaptureResourceKind> { active }

    init(
        capabilityProvider: any CaptureConcurrencyCapabilityProviding =
            CaptureConcurrencyCapabilityProvider()
    ) {
        self.capabilityProvider = capabilityProvider
    }

    func acquire(
        _ requested: CaptureResourceKind,
        monitorActive: Bool
    ) async -> CaptureResourceDecision {
        guard !isTerminating else {
            return .rejected("应用正在退出")
        }
        guard optionalStillToken == nil else {
            return .rejected("菜单栏图标采集仍在结束，请稍后重试")
        }
        pendingAcquisitions += 1
        defer { pendingAcquisitions -= 1 }
        let combinations = CaptureResourcePolicy.requiredCombinations(
            requested: requested,
            active: active,
            monitorActive: monitorActive
        )
        var capabilities: [CaptureSlotCapability] = []
        for combination in combinations {
            let capability = await capabilityProvider.capability(for: combination)
            guard !isTerminating, !Task.isCancelled else {
                return .rejected("采集请求已取消")
            }
            capabilities.append(capability)
            logger.info(
                "resource.capability combination=\(combination.rawValue, privacy: .public) result=\(Self.logValue(capability), privacy: .public)"
            )
        }
        let decision = CaptureResourcePolicy.decision(
            requested: requested,
            active: active,
            monitorActive: monitorActive,
            slotCapabilities: capabilities
        )
        if case .granted = decision {
            active.insert(requested)
            logger.info("resource.acquired kind=\(requested.rawValue, privacy: .public)")
        } else {
            logger.info("resource.denied kind=\(requested.rawValue, privacy: .public) result=\(String(describing: decision), privacy: .public)")
        }
        return decision
    }

    func release(_ resource: CaptureResourceKind) {
        guard resource != .still || optionalStillToken == nil else { return }
        guard active.remove(resource) != nil else { return }
        logger.info("resource.released kind=\(resource.rawValue, privacy: .public)")
    }

    /// Optional menu-bar visuals never start while a user capture owns a slot.
    /// A token keeps a late native completion from releasing a newer still.
    func acquireOptionalStill(monitorActive: Bool) -> UUID? {
        guard !isTerminating, active.isEmpty, pendingAcquisitions == 0 else { return nil }
        guard CaptureResourcePolicy.decision(
            requested: .still,
            active: active,
            monitorActive: monitorActive,
            slotCapabilities: []
        ) == .granted else { return nil }
        let token = UUID()
        optionalStillToken = token
        active.insert(.still)
        logger.info("resource.optionalStill.acquired")
        return token
    }

    func releaseOptionalStill(_ token: UUID) {
        guard optionalStillToken == token else { return }
        optionalStillToken = nil
        release(.still)
    }

    func releaseAllForTermination() {
        stopAcceptingRequests()
        let count = active.count
        optionalStillToken = nil
        active.removeAll()
        logger.notice("resource.termination.released count=\(count, privacy: .public)")
    }

    func stopAcceptingRequests() {
        isTerminating = true
    }

    private static func logValue(_ capability: CaptureSlotCapability) -> String {
        switch capability {
        case .notRequired:
            return "notRequired"
        case .unknown(let reason):
            return "unknown reason=\(reason)"
        case .allowed(let evidenceID):
            return "allowed evidenceID=\(evidenceID)"
        case .denied(let reason, let evidenceID):
            return "denied evidenceID=\(evidenceID ?? "none") reason=\(reason)"
        }
    }
}
