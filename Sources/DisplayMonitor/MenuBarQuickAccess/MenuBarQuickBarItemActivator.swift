import ApplicationServices
import CoreGraphics
import Foundation

/// The result of a user-initiated quick-bar proxy activation.
///
/// This type deliberately carries only value data. AX elements never cross the
/// detached task boundary and the caller can decide whether and when to restore
/// the persistent menu-bar visibility assertion.
enum MenuBarQuickBarActivationResult: Equatable, Sendable {
    case activated(targetID: String)
    case notFound(message: String)
    case failed(message: String)
    case cancelled

    var succeeded: Bool {
        if case .activated = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .activated:
            return "已打开原应用菜单。"
        case .notFound(let message), .failed(let message):
            return message
        case .cancelled:
            return "已取消打开菜单栏项目。"
        }
    }
}

enum MenuBarQuickBarPhysicalWaitResult: Equatable, Sendable {
    case target(MenuBarOrderItem)
    case ambiguous
    case timedOut
    case cancelled
}

/// Polls a caller-supplied physical inventory without knowing anything about
/// AX. Passing the remaining total budget into every scan keeps an individual
/// discovery from exceeding the activation deadline. The injected budget and
/// sleep closures also make the reveal wait deterministic in unit tests.
enum MenuBarQuickBarPhysicalScanWaiter {
    static func wait(
        for proxy: MenuBarQuickBarItem,
        pollInterval: Duration = .milliseconds(120),
        remainingBudget: @escaping @Sendable () async -> Duration,
        scan: @escaping @Sendable (_ remainingBudget: Duration) async -> [MenuBarOrderItem],
        sleep: @escaping @Sendable (_ duration: Duration) async throws -> Void
    ) async -> MenuBarQuickBarPhysicalWaitResult {
        while !Task.isCancelled {
            let remaining = await remainingBudget()
            guard remaining > .zero else { return .timedOut }

            let physicalItems = await scan(remaining)
            guard !Task.isCancelled else { return .cancelled }
            switch MenuBarQuickBarTargetResolver.resolve(proxy, in: physicalItems) {
            case .target(let target):
                return .target(target)
            case .ambiguous:
                return .ambiguous
            case .notFound:
                break
            }

            let remainingAfterScan = await remainingBudget()
            guard remainingAfterScan > .zero else { return .timedOut }
            do {
                try await sleep(min(pollInterval, remainingAfterScan))
            } catch {
                return .cancelled
            }
        }
        return .cancelled
    }
}

/// Resolves and activates the real status item represented by a quick-bar proxy.
///
/// Callers must first release the native hiding assertion and allow MenuBarAgent
/// to redraw. Activation then performs a fresh discovery, requires an exact
/// id/PID/bundle/title match, hit-tests the latest frame, re-checks ownership,
/// and finally invokes AXPress. There is intentionally no CGEvent fallback: an
/// unchecked global click could hit a different item if the menu bar moves.
enum MenuBarQuickBarItemActivator {
    @MainActor
    static func activate(_ item: MenuBarQuickBarItem) async -> MenuBarQuickBarActivationResult {
        let applications = MenuBarOrderExecutor.applicationSnapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let anchorIdentity = MenuBarManagementCoordinator.anchorIdentity
        let protectionPolicy = MenuBarTargetProtectionPolicy(
            ownBundleIdentifier: AppConstants.bundleIdentifier
        )

        let worker = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return MenuBarQuickBarActivationResult.cancelled }
            guard AXIsProcessTrusted() else {
                return .failed(message: "需要辅助功能权限才能打开这个菜单栏项目。")
            }

            // Releasing the visibility assertion is synchronous, while
            // MenuBarAgent lays the real item out asynchronously. Wait for a
            // fresh physical hit-test to prove that the exact item is visible
            // before invoking AXPress. Never reuse the proxy's old frame.
            let clock = ContinuousClock()
            let totalBudget = Duration.seconds(3)
            let startedAt = clock.now
            let waitResult = await MenuBarQuickBarPhysicalScanWaiter.wait(
                for: item,
                remainingBudget: {
                    let elapsed = startedAt.duration(to: clock.now)
                    return elapsed >= totalBudget ? .zero : totalBudget - elapsed
                },
                scan: { remaining in
                    let discovery = AnchoredMenuBarDiscovery.scan(
                        applications: applications,
                        anchorIdentity: anchorIdentity,
                        ownPID: ownPID,
                        protectionPolicy: protectionPolicy,
                        timeBudget: MenuBarQuickBarItemActivator.timeInterval(remaining)
                    )
                    return discovery.physicalItems
                },
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
            switch waitResult {
            case .target(let target):
                guard !Task.isCancelled else { return .cancelled }
                return press(target)
            case .ambiguous:
                return .failed(message: "读取到了多个同名项目，已停止操作以避免点错。")
            case .timedOut:
                return .notFound(message: "真实图标展开后仍未出现在菜单栏中，已停止操作以避免点错。")
            case .cancelled:
                return .cancelled
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }

    private static func press(_ target: MenuBarOrderItem) -> MenuBarQuickBarActivationResult {
        guard target.frame.origin.x.isFinite,
              target.frame.origin.y.isFinite,
              target.frame.width.isFinite,
              target.frame.height.isFinite,
              target.frame.width > 0,
              target.frame.height > 0 else {
            return .failed(message: "这个菜单栏项目的位置无效，请重新读取。")
        }

        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard hitError == .success, let hitElement else {
            return .failed(message: "已经找到项目，但系统没有返回可操作的菜单栏元素（AX \(hitError.rawValue)）。")
        }

        var hitPID: pid_t = 0
        let pidError = AXUIElementGetPid(hitElement, &hitPID)
        guard pidError == .success, hitPID == target.processIdentifier else {
            let actual = pidError == .success && hitPID > 0 ? String(hitPID) : "未知"
            return .failed(
                message: "图标位置已发生变化（预期 PID \(target.processIdentifier)，实际 \(actual)），已停止操作以避免点到其他项目。"
            )
        }

        var current: AXUIElement? = hitElement
        for _ in 0..<5 {
            guard !Task.isCancelled else { return .cancelled }
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, 0.25)

            if supportsPress(element),
               matchesIdentity(element, target: target),
               matchesFrame(element, target: target) {
                guard !Task.isCancelled else { return .cancelled }
                let pressError = AXUIElementPerformAction(element, kAXPressAction as CFString)
                return pressError == .success
                    ? .activated(targetID: target.id)
                    : .failed(message: "系统拒绝了这次菜单栏点击（AX \(pressError.rawValue)），请重试。")
            }

            guard let parent = elementAttribute(element, kAXParentAttribute) else { break }
            var parentPID: pid_t = 0
            guard AXUIElementGetPid(parent, &parentPID) == .success,
                  parentPID == target.processIdentifier else { break }
            current = parent
        }

        return .failed(message: "图标身份或位置已变化，已停止操作以避免点到同一应用的其他项目。")
    }

    private static func matchesIdentity(
        _ element: AXUIElement,
        target: MenuBarOrderItem
    ) -> Bool {
        if let expectedIdentifier = target.accessibilityIdentifier,
           !expectedIdentifier.isEmpty {
            return stringAttribute(element, kAXIdentifierAttribute) == expectedIdentifier
        }
        let expectedTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedTitle.isEmpty else { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
            .compactMap { stringAttribute(element, $0) }
            .contains(expectedTitle)
    }

    private static func matchesFrame(
        _ element: AXUIElement,
        target: MenuBarOrderItem
    ) -> Bool {
        guard let liveFrame = frameAttribute(element) else { return false }
        let tolerance: CGFloat = 2
        return target.frame.insetBy(dx: -tolerance, dy: -tolerance).intersects(liveFrame)
    }

    private static func supportsPress(_ element: AXUIElement) -> Bool {
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success,
              let actions = rawActions as? [String] else { return false }
        return actions.contains(kAXPressAction)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
              let value = rawValue as? String else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &rawSize
              ) == .success,
              let rawPosition,
              let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(rawValue, to: AXUIElement.self)
    }
}

enum MenuBarQuickBarTargetResolution: Equatable, Sendable {
    case target(MenuBarOrderItem)
    case notFound
    case ambiguous
}

enum MenuBarQuickBarTargetResolver {
    static func resolve(
        _ proxy: MenuBarQuickBarItem,
        in physicalItems: [MenuBarOrderItem]
    ) -> MenuBarQuickBarTargetResolution {
        let matches = physicalItems.filter { candidate in
            guard candidate.processIdentifier == proxy.processIdentifier,
                  candidate.bundleIdentifier == proxy.bundleIdentifier else { return false }
            if let identifier = proxy.accessibilityIdentifier,
               !identifier.isEmpty {
                return candidate.accessibilityIdentifier == identifier
            }
            return candidate.id == proxy.id && candidate.title == proxy.itemTitle
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .target(matches[0])
        default: return .ambiguous
        }
    }
}
