import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarTransparentContainerPolicyTests: XCTestCase {
    private let allGeometryAbsent: [MenuBarContainerGeometrySlotShape] = [
        .absent, .absent, .absent,
    ]

    func testAnonymousWrapperIsEligibleOnlyForTheCompleteNonvisualShape() {
        let evaluation = MenuBarTransparentContainerPolicy.evaluate(
            bulkRoleFailure: .absent,
            fallbackRoleFailure: .absent,
            geometry: allGeometryAbsent,
            children: .nonEmpty,
            hasInheritedFrame: false,
            insideKnownItem: false,
            isMenuBarAgentSource: true
        )

        XCTAssertTrue(evaluation.isEligibleToRecurse)
        XCTAssertEqual(
            evaluation.evidence,
            [.roleDoubleAbsent, .geometryAllAbsent, .childrenNonEmpty, .eligibleToRecurse]
        )
    }

    func testAnonymousWrapperRejectsEveryNonAbsentRoleOutcome() {
        let failures: [MenuBarAXMandatoryStringFailure] = [
            .failed, .wrongType, .deadlineExceeded,
        ]

        for failure in failures {
            let bulkRejected = evaluate(bulkRoleFailure: failure)
            let fallbackRejected = evaluate(fallbackRoleFailure: failure)

            XCTAssertFalse(bulkRejected.isEligibleToRecurse)
            XCTAssertTrue(bulkRejected.evidence.contains(.roleNotDoubleAbsent))
            XCTAssertFalse(fallbackRejected.isEligibleToRecurse)
            XCTAssertTrue(fallbackRejected.evidence.contains(.roleNotDoubleAbsent))
        }
    }

    func testAnonymousWrapperRejectsAnyGeometryValueFailureOrWrongType() {
        let shapes: [MenuBarContainerGeometrySlotShape] = [.present, .failed, .wrongType]
        let expectedEvidence: [
            MenuBarContainerGeometrySlotShape: MenuBarTransparentContainerEvidence
        ] = [
            .present: .geometryPresent,
            .failed: .geometryFailed,
            .wrongType: .geometryWrongType,
        ]

        for shape in shapes {
            for index in 0..<3 {
                var geometry = allGeometryAbsent
                geometry[index] = shape
                let evaluation = evaluate(geometry: geometry)

                XCTAssertFalse(evaluation.isEligibleToRecurse)
                XCTAssertFalse(evaluation.evidence.contains(.geometryAllAbsent))
                XCTAssertTrue(evaluation.evidence.contains(expectedEvidence[shape]!))
            }
        }
        XCTAssertFalse(evaluate(geometry: []).isEligibleToRecurse)
        XCTAssertFalse(evaluate(geometry: [.absent, .absent]).isEligibleToRecurse)
    }

    func testAnonymousWrapperRejectsIncompleteOrEmptyChildren() {
        let shapes: [MenuBarContainerChildrenShape] = [.empty, .absent, .failed]
        let expectedEvidence: [
            MenuBarContainerChildrenShape: MenuBarTransparentContainerEvidence
        ] = [
            .empty: .childrenEmpty,
            .absent: .childrenAbsent,
            .failed: .childrenFailed,
        ]

        for shape in shapes {
            let evaluation = evaluate(children: shape)
            XCTAssertFalse(evaluation.isEligibleToRecurse)
            XCTAssertTrue(evaluation.evidence.contains(expectedEvidence[shape]!))
        }
    }

    func testAnonymousWrapperRejectsInheritedKnownItemAndNonAgentContexts() {
        let inherited = evaluate(hasInheritedFrame: true)
        XCTAssertFalse(inherited.isEligibleToRecurse)
        XCTAssertTrue(inherited.evidence.contains(.inheritedFrame))
        let knownItem = evaluate(insideKnownItem: true)
        XCTAssertFalse(knownItem.isEligibleToRecurse)
        XCTAssertTrue(knownItem.evidence.contains(.insideKnownItem))
        let nonAgent = evaluate(isMenuBarAgentSource: false)
        XCTAssertFalse(nonAgent.isEligibleToRecurse)
        XCTAssertTrue(nonAgent.evidence.contains(.nonMenuBarAgentSource))
    }

    func testNarrowPhysicalMenuBarRootIsEligibleWithoutHalfDisplayWidth() {
        let evaluation = evaluateRoot()

        XCTAssertTrue(evaluation.isEligibleToTraverse)
        XCTAssertEqual(evaluation.displayIndex, 0)
        XCTAssertEqual(
            evaluation.evidence,
            [.childrenNonEmpty, .eligibleToTraverse]
        )
    }

    func testPhysicalMenuBarRootRejectsOutOfBoundsAndOffTopFrames() {
        let outOfBounds = evaluateRoot(frame: CGRect(x: 1_450, y: 0, width: 100, height: 32))
        XCTAssertFalse(outOfBounds.isEligibleToTraverse)
        XCTAssertTrue(outOfBounds.evidence.contains(.displayUnresolved))

        let offTop = evaluateRoot(frame: CGRect(x: 1_200, y: 12, width: 300, height: 32))
        XCTAssertFalse(offTop.isEligibleToTraverse)
        XCTAssertTrue(offTop.evidence.contains(.outsideTopBand))

        let zeroWidth = evaluateRoot(frame: CGRect(x: 1_200, y: 0, width: 0, height: 32))
        XCTAssertFalse(zeroWidth.isEligibleToTraverse)
        XCTAssertTrue(zeroWidth.evidence.contains(.invalidFrame))
    }

    func testPhysicalMenuBarRootRejectsAmbiguousMirroredDisplays() {
        let bounds = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let evaluation = evaluateRoot(displayBounds: [bounds, bounds])

        XCTAssertFalse(evaluation.isEligibleToTraverse)
        XCTAssertNil(evaluation.displayIndex)
        XCTAssertTrue(evaluation.evidence.contains(.displayUnresolved))
    }

    func testPhysicalMenuBarRootRejectsEmptyAbsentOrFailedFreshChildren() {
        let shapes: [MenuBarContainerChildrenShape] = [.empty, .absent, .failed]
        let expectedEvidence: [MenuBarContainerChildrenShape: MenuBarPhysicalMenuBarRootEvidence] = [
            .empty: .childrenEmpty,
            .absent: .childrenAbsent,
            .failed: .childrenFailed,
        ]

        for shape in shapes {
            let evaluation = evaluateRoot(children: shape)
            XCTAssertFalse(evaluation.isEligibleToTraverse)
            XCTAssertTrue(evaluation.evidence.contains(expectedEvidence[shape]!))
        }
    }

    func testPhysicalMenuBarRootRequiresExactBundleAndProviderPID() {
        let wrongBundle = evaluateRoot(providerBundleIdentifier: "com.example.MenuBarAgent")
        XCTAssertFalse(wrongBundle.isEligibleToTraverse)
        XCTAssertTrue(wrongBundle.evidence.contains(.providerBundleMismatch))

        let missingPID = evaluateRoot(actualProviderPID: nil)
        XCTAssertFalse(missingPID.isEligibleToTraverse)
        XCTAssertTrue(missingPID.evidence.contains(.providerPIDUnavailable))

        let wrongPID = evaluateRoot(actualProviderPID: 99)
        XCTAssertFalse(wrongPID.isEligibleToTraverse)
        XCTAssertTrue(wrongPID.evidence.contains(.providerPIDMismatch))

        let invalidExpectedPID = evaluateRoot(expectedProviderPID: 0, actualProviderPID: 0)
        XCTAssertFalse(invalidExpectedPID.isEligibleToTraverse)
        XCTAssertTrue(invalidExpectedPID.evidence.contains(.providerPIDUnavailable))

        let invalidActualPID = evaluateRoot(actualProviderPID: -1)
        XCTAssertFalse(invalidActualPID.isEligibleToTraverse)
        XCTAssertTrue(invalidActualPID.evidence.contains(.providerPIDUnavailable))
    }

    func testPhysicalRootItemMustRemainOnItsRootDisplay() {
        XCTAssertTrue(MenuBarPhysicalRootDisplayPolicy.itemBelongsToRoot(
            expectedDisplayID: 7,
            actualDisplayID: 7
        ))
        XCTAssertFalse(MenuBarPhysicalRootDisplayPolicy.itemBelongsToRoot(
            expectedDisplayID: 7,
            actualDisplayID: 8
        ))
        XCTAssertFalse(MenuBarPhysicalRootDisplayPolicy.itemBelongsToRoot(
            expectedDisplayID: 7,
            actualDisplayID: nil
        ))
    }

    func testOnlyOneQualifiedPhysicalRootMayClaimADisplay() {
        XCTAssertTrue(MenuBarPhysicalRootDisplayPolicy.rootDisplayIsUnique(
            displayID: 7,
            qualifiedRootDisplayIDs: []
        ))
        XCTAssertFalse(MenuBarPhysicalRootDisplayPolicy.rootDisplayIsUnique(
            displayID: 7,
            qualifiedRootDisplayIDs: [7]
        ))
        XCTAssertTrue(MenuBarPhysicalRootDisplayPolicy.rootDisplayIsUnique(
            displayID: 8,
            qualifiedRootDisplayIDs: [7]
        ))
    }

    private func evaluate(
        bulkRoleFailure: MenuBarAXMandatoryStringFailure = .absent,
        fallbackRoleFailure: MenuBarAXMandatoryStringFailure = .absent,
        geometry: [MenuBarContainerGeometrySlotShape]? = nil,
        children: MenuBarContainerChildrenShape = .nonEmpty,
        hasInheritedFrame: Bool = false,
        insideKnownItem: Bool = false,
        isMenuBarAgentSource: Bool = true
    ) -> MenuBarTransparentContainerEvaluation {
        MenuBarTransparentContainerPolicy.evaluate(
            bulkRoleFailure: bulkRoleFailure,
            fallbackRoleFailure: fallbackRoleFailure,
            geometry: geometry ?? allGeometryAbsent,
            children: children,
            hasInheritedFrame: hasInheritedFrame,
            insideKnownItem: insideKnownItem,
            isMenuBarAgentSource: isMenuBarAgentSource
        )
    }

    private func evaluateRoot(
        providerBundleIdentifier: String = "com.apple.MenuBarAgent",
        expectedProviderPID: Int32 = 42,
        actualProviderPID: Int32? = 42,
        frame: CGRect? = CGRect(x: 1_200, y: 0, width: 300, height: 32),
        displayBounds: [CGRect] = [CGRect(x: 0, y: 0, width: 1_512, height: 982)],
        children: MenuBarContainerChildrenShape = .nonEmpty
    ) -> MenuBarPhysicalMenuBarRootEvaluation {
        MenuBarPhysicalMenuBarRootPolicy.evaluate(
            providerBundleIdentifier: providerBundleIdentifier,
            expectedProviderPID: expectedProviderPID,
            actualProviderPID: actualProviderPID,
            frame: frame,
            displayBounds: displayBounds,
            children: children
        )
    }
}
