import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct MenuBarQuickBarMenuWindow: Equatable, Sendable {
    let id: CGWindowID
    let ownerPID: Int32
    let layer: Int
    let bounds: CGRect
}

struct MenuBarQuickBarMenuTargetIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let launchDate: Date?
}

enum MenuBarQuickBarMenuObservation: Equatable, Sendable {
    case sample(
        target: MenuBarQuickBarMenuTargetIdentity,
        menuWindowIDs: Set<CGWindowID>
    )
    case targetUnavailable
    case unreadable
}

enum MenuBarQuickBarMenuTrackingDecision: Equatable, Sendable {
    case continueWaiting
    case confirmedClosed
    case stopUnconfirmed
}

/// A conservative state machine for restoring the persistent hiding assertion.
///
/// A close is accepted only after a newly opened, AX-confirmed menu window has
/// been observed and then disappears for multiple consecutive samples. Missing
/// process identity or unreadable system state always fails closed by leaving
/// the menu bar expanded.
struct MenuBarQuickBarMenuTracker: Sendable {
    private let target: MenuBarQuickBarMenuTargetIdentity
    private let baselineMenuWindowIDs: Set<CGWindowID>
    private let requiredClosedSamples: Int
    private(set) var didObserveOpen = false
    private var consecutiveClosedSamples = 0

    init?(
        baseline: MenuBarQuickBarMenuObservation,
        requiredClosedSamples: Int = 2
    ) {
        guard case .sample(let target, let menuWindowIDs) = baseline,
              requiredClosedSamples >= 2 else { return nil }
        self.target = target
        baselineMenuWindowIDs = menuWindowIDs
        self.requiredClosedSamples = requiredClosedSamples
    }

    mutating func ingest(
        _ observation: MenuBarQuickBarMenuObservation
    ) -> MenuBarQuickBarMenuTrackingDecision {
        guard case .sample(let observedTarget, let observedMenuWindowIDs) = observation else {
            return .stopUnconfirmed
        }
        guard observedTarget == target else { return .stopUnconfirmed }

        let newlyVisibleMenuWindowIDs = observedMenuWindowIDs
            .subtracting(baselineMenuWindowIDs)
        if !newlyVisibleMenuWindowIDs.isEmpty {
            didObserveOpen = true
            consecutiveClosedSamples = 0
            return .continueWaiting
        }

        guard didObserveOpen else { return .continueWaiting }
        consecutiveClosedSamples += 1
        return consecutiveClosedSamples >= requiredClosedSamples
            ? .confirmedClosed
            : .continueWaiting
    }
}

enum MenuBarQuickBarMenuWindowClassifier {
    static func candidates(
        from windows: [MenuBarQuickBarMenuWindow],
        ownerPID: Int32,
        displayBounds: [CGRect],
        popUpMenuLayer: Int = Int(CGWindowLevelForKey(.popUpMenuWindow)),
        maximumTopGap: CGFloat = 80
    ) -> [MenuBarQuickBarMenuWindow] {
        windows.filter { window in
            guard window.ownerPID == ownerPID,
                  window.layer == popUpMenuLayer,
                  window.bounds.width > 0,
                  window.bounds.height > 0,
                  window.bounds.origin.x.isFinite,
                  window.bounds.origin.y.isFinite,
                  window.bounds.width.isFinite,
                  window.bounds.height.isFinite else { return false }

            return displayBounds.contains { display in
                let overlapsHorizontally = window.bounds.maxX > display.minX
                    && window.bounds.minX < display.maxX
                let beginsNearTop = window.bounds.minY >= display.minY - 1
                    && window.bounds.minY <= display.minY + maximumTopGap
                return overlapsHorizontally && beginsNearTop
            }
        }
    }
}

enum MenuBarQuickBarMenuObservationReader {
    static func read(
        ownerPID: Int32,
        expectedBundleIdentifier: String
    ) -> MenuBarQuickBarMenuObservation {
        guard AXIsProcessTrusted() else { return .unreadable }
        guard let application = NSRunningApplication(processIdentifier: ownerPID),
              !application.isTerminated,
              application.bundleIdentifier?.caseInsensitiveCompare(
                expectedBundleIdentifier
              ) == .orderedSame else {
            return .targetUnavailable
        }
        let target = MenuBarQuickBarMenuTargetIdentity(
            processIdentifier: ownerPID,
            bundleIdentifier: application.bundleIdentifier ?? expectedBundleIdentifier,
            launchDate: application.launchDate
        )

        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .unreadable
        }
        let windows = rawWindows.compactMap(window(from:))
        let displayBounds = onlineDisplayBounds()
        guard !displayBounds.isEmpty else { return .unreadable }

        let candidates = MenuBarQuickBarMenuWindowClassifier.candidates(
            from: windows,
            ownerPID: ownerPID,
            displayBounds: displayBounds
        )
        guard !candidates.isEmpty else {
            return .sample(target: target, menuWindowIDs: [])
        }

        var confirmedMenuWindowIDs: Set<CGWindowID> = []
        var hadUnreadableCandidate = false
        for candidate in candidates {
            switch verifyAXMenu(window: candidate, ownerPID: ownerPID) {
            case .menu:
                confirmedMenuWindowIDs.insert(candidate.id)
            case .notMenu:
                break
            case .unreadable:
                hadUnreadableCandidate = true
            }
        }
        if confirmedMenuWindowIDs.isEmpty, hadUnreadableCandidate {
            return .unreadable
        }
        return .sample(target: target, menuWindowIDs: confirmedMenuWindowIDs)
    }

    private enum AXMenuVerification {
        case menu
        case notMenu
        case unreadable
    }

    private static func window(from dictionary: [String: Any]) -> MenuBarQuickBarMenuWindow? {
        guard let id = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let ownerPID = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
            return nil
        }
        return MenuBarQuickBarMenuWindow(
            id: id,
            ownerPID: ownerPID,
            layer: layer,
            bounds: bounds
        )
    }

    private static func onlineDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// Verifies only AX roles and ownership; no menu labels or contents are read.
    private static func verifyAXMenu(
        window: MenuBarQuickBarMenuWindow,
        ownerPID: Int32
    ) -> AXMenuVerification {
        let insetX = min(max(4, window.bounds.width * 0.1), window.bounds.width / 2)
        let insetY = min(max(4, window.bounds.height * 0.1), window.bounds.height / 2)
        let points = [
            CGPoint(x: window.bounds.midX, y: window.bounds.midY),
            CGPoint(x: window.bounds.minX + insetX, y: window.bounds.minY + insetY),
            CGPoint(x: window.bounds.maxX - insetX, y: window.bounds.maxY - insetY),
        ]
        var hadReadableOwnedHit = false
        for point in points {
            var hitElement: AXUIElement?
            let hitError = AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(),
                Float(point.x),
                Float(point.y),
                &hitElement
            )
            guard hitError == .success, let hitElement else { continue }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hitElement, &hitPID) == .success,
                  hitPID == ownerPID else { continue }
            hadReadableOwnedHit = true
            if elementIsMenuOrMenuItem(hitElement, ownerPID: ownerPID) {
                return .menu
            }
        }
        return hadReadableOwnedHit ? .notMenu : .unreadable
    }

    private static func elementIsMenuOrMenuItem(
        _ element: AXUIElement,
        ownerPID: Int32
    ) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            AXUIElementSetMessagingTimeout(candidate, 0.1)
            guard elementPID(candidate) == ownerPID else { return false }
            if let role = stringAttribute(candidate, kAXRoleAttribute),
               role == kAXMenuRole || role == kAXMenuItemRole {
                return true
            }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    private static func elementPID(_ element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }
}

@MainActor
enum MenuBarQuickBarMenuCloseWaiter {
    static func wait(
        baseline: MenuBarQuickBarMenuObservation,
        pollInterval: Duration = .milliseconds(150),
        remainingBudget: @escaping () async -> Duration,
        openingRemainingBudget: @escaping () async -> Duration,
        observe: @escaping () async -> MenuBarQuickBarMenuObservation,
        sleep: @escaping (_ duration: Duration) async throws -> Void
    ) async -> Bool {
        guard var tracker = MenuBarQuickBarMenuTracker(baseline: baseline) else {
            return false
        }

        while !Task.isCancelled {
            let remaining = await remainingBudget()
            guard remaining > .zero else { return false }
            if !tracker.didObserveOpen {
                guard await openingRemainingBudget() > .zero else { return false }
            }

            let decision = tracker.ingest(await observe())
            guard !Task.isCancelled else { return false }
            switch decision {
            case .confirmedClosed:
                return true
            case .stopUnconfirmed:
                return false
            case .continueWaiting:
                break
            }

            let remainingAfterObservation = await remainingBudget()
            guard remainingAfterObservation > .zero else { return false }
            if !tracker.didObserveOpen {
                guard await openingRemainingBudget() > .zero else { return false }
            }
            do {
                try await sleep(min(pollInterval, remainingAfterObservation))
            } catch {
                return false
            }
        }
        return false
    }
}
