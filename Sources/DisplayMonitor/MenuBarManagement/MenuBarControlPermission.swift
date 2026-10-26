// The SDK declares kAXTrustedCheckOptionPrompt as a mutable C global even
// though it is an API option key. Access stays inside this MainActor adapter.
@preconcurrency import ApplicationServices
import CoreGraphics

public struct MenuBarControlPermissionStatus: Equatable, Sendable {
    public let accessibilityGranted: Bool
    public let eventPostingGranted: Bool

    public init(accessibilityGranted: Bool, eventPostingGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.eventPostingGranted = eventPostingGranted
    }

    public var canSort: Bool { accessibilityGranted && eventPostingGranted }
}

public enum MenuBarControlPermissionRequest: Equatable, Sendable {
    case none
    case accessibility
    case eventPosting
}

public struct MenuBarControlPermissionResponse: Sendable {
    public let status: MenuBarControlPermissionStatus
    public let requested: MenuBarControlPermissionRequest

    public init(status: MenuBarControlPermissionStatus, requested: MenuBarControlPermissionRequest) {
        self.status = status
        self.requested = requested
    }
}

/// Requests are explicit user actions; construction and snapshots never request access.
@MainActor
public struct MenuBarControlPermissionClient {
    private let checkAccessibility: () -> Bool
    private let requestAccessibility: () -> Bool
    private let checkEventPosting: () -> Bool
    private let requestEventPosting: () -> Bool

    public init(
        checkAccessibility: @escaping () -> Bool,
        requestAccessibility: @escaping () -> Bool,
        checkEventPosting: @escaping () -> Bool,
        requestEventPosting: @escaping () -> Bool
    ) {
        self.checkAccessibility = checkAccessibility
        self.requestAccessibility = requestAccessibility
        self.checkEventPosting = checkEventPosting
        self.requestEventPosting = requestEventPosting
    }

    public static var system: MenuBarControlPermissionClient {
        MenuBarControlPermissionClient(
            checkAccessibility: { AXIsProcessTrusted() },
            requestAccessibility: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            checkEventPosting: { CGPreflightPostEventAccess() },
            requestEventPosting: { CGRequestPostEventAccess() }
        )
    }

    public func snapshot() -> MenuBarControlPermissionStatus {
        MenuBarControlPermissionStatus(
            accessibilityGranted: checkAccessibility(),
            eventPostingGranted: checkEventPosting()
        )
    }

    /// One click requests at most one permission. Request return values are not grants:
    /// in particular, the accessibility prompt completes asynchronously.
    public func request() -> MenuBarControlPermissionResponse {
        let before = snapshot()
        let requested: MenuBarControlPermissionRequest
        if !before.accessibilityGranted {
            requested = .accessibility
            _ = requestAccessibility()
        } else if !before.eventPostingGranted {
            requested = .eventPosting
            _ = requestEventPosting()
        } else {
            requested = .none
        }
        return MenuBarControlPermissionResponse(status: snapshot(), requested: requested)
    }
}
