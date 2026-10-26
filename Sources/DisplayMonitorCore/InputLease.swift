import Foundation

public enum InputLeaseOwner: String, CaseIterable, Codable, Hashable, Sendable {
    case captureWorkflow
    case stillCaptureSelection
    case scrollCapture
    case recordingSelection
    case recordingCapture
    case annotationEditing
    case menuBarShelfManagement
    case shortcutSafety
    case directPointer

    public var label: String {
        switch self {
        case .captureWorkflow: return "截图工作流"
        case .stillCaptureSelection: return "截图选区"
        case .scrollCapture: return "滚动截图"
        case .recordingSelection: return "录屏选区"
        case .recordingCapture: return "区域录屏"
        case .annotationEditing: return "标注编辑"
        case .menuBarShelfManagement: return "菜单栏管理"
        case .shortcutSafety: return "快捷键"
        case .directPointer: return "直控"
        }
    }
}

/// An opaque, coordinator-issued identity. The nonce makes an old token from
/// the same owner and operation unusable after a lease is released or replaced.
public struct InputLeaseToken: Codable, Equatable, Hashable, Sendable {
    public var owner: InputLeaseOwner
    public var operationID: UUID
    public var nonce: UUID

    public init(owner: InputLeaseOwner, operationID: UUID, nonce: UUID = UUID()) {
        self.owner = owner
        self.operationID = operationID
        self.nonce = nonce
    }
}

public enum InputLeaseReleaseReason: String, Codable, Sendable {
    case completed
    case cancelled
    case applicationTermination
    case permissionRevoked
    case recoveryTakeover
}

public struct InputLease: Codable, Equatable, Sendable {
    public var token: InputLeaseToken
    public var acquiredAt: Date
    public var releasedAt: Date?
    public var releaseReason: InputLeaseReleaseReason?

    public init(token: InputLeaseToken, acquiredAt: Date = Date()) {
        self.token = token
        self.acquiredAt = acquiredAt
    }

    public var owner: InputLeaseOwner { token.owner }
}

/// Pure state for the main-actor coordinator. It deliberately rejects same
/// owner re-entry: the caller must keep and release its exact issued token.
public struct InputLeaseRegistry: Equatable, Sendable {
    public private(set) var activeLease: InputLease?

    public init(activeLease: InputLease? = nil) {
        self.activeLease = activeLease
    }

    public mutating func acquire(
        owner: InputLeaseOwner,
        operationID: UUID = UUID(),
        at date: Date = Date()
    ) -> InputLeaseToken? {
        guard activeLease == nil else {
            return nil
        }
        let token = InputLeaseToken(owner: owner, operationID: operationID)
        activeLease = InputLease(token: token, acquiredAt: date)
        return token
    }

    /// Atomically hands an active interaction to another owner while keeping
    /// the same operation identity. The old token becomes invalid immediately;
    /// there is never a lease-free gap in which another workflow can enter.
    public mutating func transfer(
        _ token: InputLeaseToken,
        to owner: InputLeaseOwner,
        at date: Date = Date()
    ) -> InputLeaseToken? {
        guard activeLease?.token == token else {
            return nil
        }
        let replacement = InputLeaseToken(
            owner: owner,
            operationID: token.operationID
        )
        activeLease = InputLease(token: replacement, acquiredAt: date)
        return replacement
    }

    @discardableResult
    public mutating func release(
        _ token: InputLeaseToken,
        reason: InputLeaseReleaseReason = .completed,
        at date: Date = Date()
    ) -> Bool {
        guard activeLease?.token == token else {
            return false
        }
        activeLease = nil
        return true
    }

    /// Restricted callers use this only for application termination,
    /// permission revocation, or a recovery takeover. Normal business paths
    /// must call `release(_:reason:)` with their exact token.
    @discardableResult
    public mutating func releaseAll(
        reason: InputLeaseReleaseReason
    ) -> InputLease? {
        let previous = activeLease
        activeLease = nil
        return previous
    }
}
