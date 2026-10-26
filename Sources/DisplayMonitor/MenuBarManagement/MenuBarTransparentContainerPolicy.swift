import CoreGraphics
import Foundation

enum MenuBarContainerGeometrySlotShape: Equatable, Hashable, Sendable {
    case absent
    case present
    case failed
    case wrongType
}

enum MenuBarContainerChildrenShape: Equatable, Hashable, Sendable {
    case nonEmpty
    case empty
    case absent
    case failed
}

enum MenuBarTransparentContainerEvidence: Equatable, Hashable, Sendable {
    case roleDoubleAbsent
    case roleNotDoubleAbsent
    case geometryAllAbsent
    case geometryPresent
    case geometryFailed
    case geometryWrongType
    case childrenNonEmpty
    case childrenEmpty
    case childrenAbsent
    case childrenFailed
    case inheritedFrame
    case insideKnownItem
    case nonMenuBarAgentSource
    case eligibleToRecurse
}

struct MenuBarTransparentContainerEvaluation: Equatable, Sendable {
    let isEligibleToRecurse: Bool
    let evidence: Set<MenuBarTransparentContainerEvidence>
}

enum MenuBarTransparentContainerPolicy {
    static func evaluate(
        bulkRoleFailure: MenuBarAXMandatoryStringFailure,
        fallbackRoleFailure: MenuBarAXMandatoryStringFailure,
        geometry: [MenuBarContainerGeometrySlotShape],
        children: MenuBarContainerChildrenShape,
        hasInheritedFrame: Bool,
        insideKnownItem: Bool,
        isMenuBarAgentSource: Bool
    ) -> MenuBarTransparentContainerEvaluation {
        var evidence: Set<MenuBarTransparentContainerEvidence> = []
        let roleDoubleAbsent = bulkRoleFailure == .absent && fallbackRoleFailure == .absent
        evidence.insert(roleDoubleAbsent ? .roleDoubleAbsent : .roleNotDoubleAbsent)

        if geometry.count == 3 && geometry.allSatisfy({ $0 == .absent }) {
            evidence.insert(.geometryAllAbsent)
        } else {
            if geometry.contains(.present) { evidence.insert(.geometryPresent) }
            if geometry.contains(.failed) { evidence.insert(.geometryFailed) }
            if geometry.contains(.wrongType) { evidence.insert(.geometryWrongType) }
        }

        switch children {
        case .nonEmpty: evidence.insert(.childrenNonEmpty)
        case .empty: evidence.insert(.childrenEmpty)
        case .absent: evidence.insert(.childrenAbsent)
        case .failed: evidence.insert(.childrenFailed)
        }
        if hasInheritedFrame { evidence.insert(.inheritedFrame) }
        if insideKnownItem { evidence.insert(.insideKnownItem) }
        if !isMenuBarAgentSource { evidence.insert(.nonMenuBarAgentSource) }

        let isEligibleToRecurse = roleDoubleAbsent
            && evidence.contains(.geometryAllAbsent)
            && children == .nonEmpty
            && !hasInheritedFrame
            && !insideKnownItem
            && isMenuBarAgentSource
        if isEligibleToRecurse { evidence.insert(.eligibleToRecurse) }
        return MenuBarTransparentContainerEvaluation(
            isEligibleToRecurse: isEligibleToRecurse,
            evidence: evidence
        )
    }
}

enum MenuBarPhysicalMenuBarRootEvidence: Equatable, Hashable, Sendable {
    case providerBundleMismatch
    case providerPIDUnavailable
    case providerPIDMismatch
    case frameUnavailable
    case invalidFrame
    case displayUnresolved
    case outsideTopBand
    case childrenNonEmpty
    case childrenEmpty
    case childrenAbsent
    case childrenFailed
    case eligibleToTraverse
}

struct MenuBarPhysicalMenuBarRootEvaluation: Equatable, Sendable {
    let isEligibleToTraverse: Bool
    let displayIndex: Int?
    let evidence: Set<MenuBarPhysicalMenuBarRootEvidence>
}

enum MenuBarPhysicalMenuBarRootPolicy {
    static func evaluate(
        providerBundleIdentifier: String,
        expectedProviderPID: Int32,
        actualProviderPID: Int32?,
        frame: CGRect?,
        displayBounds: [CGRect],
        children: MenuBarContainerChildrenShape
    ) -> MenuBarPhysicalMenuBarRootEvaluation {
        var evidence: Set<MenuBarPhysicalMenuBarRootEvidence> = []
        if providerBundleIdentifier != "com.apple.MenuBarAgent" {
            evidence.insert(.providerBundleMismatch)
        }
        let validActualProviderPID = actualProviderPID.flatMap { $0 > 0 ? $0 : nil }
        if expectedProviderPID <= 0 || validActualProviderPID == nil {
            evidence.insert(.providerPIDUnavailable)
        } else if let validActualProviderPID {
            if validActualProviderPID != expectedProviderPID {
                evidence.insert(.providerPIDMismatch)
            }
        }

        var matchedDisplayIndex: Int?
        if let frame {
            if frame.origin.x.isFinite, frame.origin.y.isFinite,
               frame.width.isFinite, frame.height.isFinite,
               frame.width > 0, frame.height > 0 {
                let horizontalTolerance: CGFloat = 2
                let horizontalMatches = displayBounds.indices.filter { index in
                    let bounds = displayBounds[index]
                    return frame.minX >= bounds.minX - horizontalTolerance
                        && frame.maxX <= bounds.maxX + horizontalTolerance
                }
                let topBandMatches = horizontalMatches.filter { index in
                    let bounds = displayBounds[index]
                    return abs(frame.minY - bounds.minY) <= 1
                        && frame.height <= 80
                        && frame.maxY <= bounds.minY + 82
                }
                if topBandMatches.count == 1 {
                    matchedDisplayIndex = topBandMatches[0]
                } else if topBandMatches.count > 1 || horizontalMatches.isEmpty {
                    evidence.insert(.displayUnresolved)
                } else {
                    evidence.insert(.outsideTopBand)
                }
            } else {
                evidence.insert(.invalidFrame)
            }
        } else {
            evidence.insert(.frameUnavailable)
        }

        switch children {
        case .nonEmpty: evidence.insert(.childrenNonEmpty)
        case .empty: evidence.insert(.childrenEmpty)
        case .absent: evidence.insert(.childrenAbsent)
        case .failed: evidence.insert(.childrenFailed)
        }

        let isEligibleToTraverse = providerBundleIdentifier == "com.apple.MenuBarAgent"
            && expectedProviderPID > 0
            && validActualProviderPID == expectedProviderPID
            && matchedDisplayIndex != nil
            && children == .nonEmpty
        if isEligibleToTraverse { evidence.insert(.eligibleToTraverse) }
        return MenuBarPhysicalMenuBarRootEvaluation(
            isEligibleToTraverse: isEligibleToTraverse,
            displayIndex: matchedDisplayIndex,
            evidence: evidence
        )
    }
}

enum MenuBarPhysicalRootDisplayPolicy {
    static func itemBelongsToRoot(
        expectedDisplayID: UInt32,
        actualDisplayID: UInt32?
    ) -> Bool {
        actualDisplayID == expectedDisplayID
    }

    static func rootDisplayIsUnique(
        displayID: UInt32,
        qualifiedRootDisplayIDs: Set<UInt32>
    ) -> Bool {
        !qualifiedRootDisplayIDs.contains(displayID)
    }
}
