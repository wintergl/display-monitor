import XCTest
@testable import DisplayMonitor

final class MenuBarRawPhysicalStructureReaderTests: XCTestCase {
    func testIdenticalModelsProduceTheSameCompleteRevision() {
        let first = snapshot()
        let second = snapshot()

        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.nodeCount, 2)
        XCTAssertEqual(first.diagnostics.summary, "none")
        XCTAssertEqual(first.revision, second.revision)
    }

    func testProviderAndNodePIDChangesAffectRevision() {
        XCTAssertNotEqual(
            snapshot(model: model(providerPID: 42)).revision,
            snapshot(model: model(providerPID: 43)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childPID: 42)).revision,
            snapshot(model: model(childPID: 43)).revision
        )
    }

    func testRoleAndIdentifierValueAbsentAndExactValueAffectRevision() {
        XCTAssertNotEqual(
            snapshot(model: model(childRole: .value("AXButton"))).revision,
            snapshot(model: model(childRole: .absent)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childRole: .value("AXButton"))).revision,
            snapshot(model: model(childRole: .value("AXUnknown"))).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childIdentifier: .value("status.item"))).revision,
            snapshot(model: model(childIdentifier: .absent)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childIdentifier: .value("status.item"))).revision,
            snapshot(model: model(childIdentifier: .value("status.item.2"))).revision
        )
    }

    func testEveryGeometryFieldAndExactBitChangeAffectsRevision() {
        let rect = MenuBarRawPhysicalRect(x: 10, y: 0, width: 20, height: 24)
        let changedRect = MenuBarRawPhysicalRect(
            x: 10.nextUp,
            y: 0,
            width: 20,
            height: 24
        )
        XCTAssertNotEqual(
            snapshot(model: model(childFrame: .value(rect))).revision,
            snapshot(model: model(childFrame: .absent)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childFrame: .value(rect))).revision,
            snapshot(model: model(childFrame: .value(changedRect))).revision
        )

        let point = MenuBarRawPhysicalPoint(x: 10, y: 0)
        XCTAssertNotEqual(
            snapshot(model: model(childPosition: .value(point))).revision,
            snapshot(model: model(childPosition: .absent)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childPosition: .value(point))).revision,
            snapshot(model: model(childPosition: .value(.init(x: 11, y: 0)))).revision
        )

        let size = MenuBarRawPhysicalSize(width: 20, height: 24)
        XCTAssertNotEqual(
            snapshot(model: model(childSize: .value(size))).revision,
            snapshot(model: model(childSize: .absent)).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(childSize: .value(size))).revision,
            snapshot(model: model(childSize: .value(.init(width: 21, height: 24)))).revision
        )
    }

    func testChildrenAbsentEmptyOrderAndReferenceTargetAreDistinct() {
        let root = rootNode(children: .absent)
        let emptyRoot = rootNode(children: .value([]))
        XCTAssertNotEqual(
            snapshot(model: model(nodes: [root])).revision,
            snapshot(model: model(nodes: [emptyRoot])).revision
        )

        let ordered = rootNode(children: .value([
            .node(path: [0]),
            .reference(firstPath: []),
        ]))
        let reordered = rootNode(children: .value([
            .reference(firstPath: []),
            .node(path: [0]),
        ]))
        XCTAssertNotEqual(
            snapshot(model: model(nodes: [ordered, childNode()])).revision,
            snapshot(model: model(nodes: [reordered, childNode()])).revision
        )

        let differentReference = rootNode(children: .value([
            .node(path: [0]),
            .reference(firstPath: [0]),
        ]))
        XCTAssertNotEqual(
            snapshot(model: model(nodes: [ordered, childNode()])).revision,
            snapshot(model: model(nodes: [differentReference, childNode()])).revision
        )
    }

    func testNodeAdditionRemovalAndNodeOrderAffectRevision() {
        let root = rootNode(children: .value([.node(path: [0])]))
        let child = childNode()
        XCTAssertNotEqual(
            snapshot(model: model(nodes: [root])).revision,
            snapshot(model: model(nodes: [root, child])).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(nodes: [root, child])).revision,
            snapshot(model: model(nodes: [child, root])).revision
        )
    }

    func testDisplayIDBoundsAndOrderAffectRevision() {
        let first = display(id: 1, x: 0)
        let second = display(id: 2, x: 1_512)
        XCTAssertNotEqual(
            snapshot(model: model(displays: [first])).revision,
            snapshot(model: model(displays: [display(id: 9, x: 0)])).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(displays: [first])).revision,
            snapshot(model: model(displays: [display(id: 1, x: 1)])).revision
        )
        XCTAssertNotEqual(
            snapshot(model: model(displays: [first, second])).revision,
            snapshot(model: model(displays: [second, first])).revision
        )
    }

    func testFailureTokenAndDiagnosticsMakeSnapshotIncompleteAndChangeRevision() {
        let complete = snapshot()
        let failedField = snapshot(model: model(childRole: .failed))
        XCTAssertFalse(failedField.isComplete)
        XCTAssertNotEqual(complete.revision, failedField.revision)

        var diagnostics = MenuBarRawPhysicalStructureDiagnostics()
        diagnostics.record(.roleReadFailed, count: 2)
        diagnostics.record(.deadlineExceeded)
        diagnostics.record(.roleReadFailed, count: 0)
        let incomplete = snapshot(diagnostics: diagnostics)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.diagnostics.totalCount, 3)
        XCTAssertEqual(
            incomplete.diagnostics.summary,
            "deadlineExceeded=1,roleReadFailed=2"
        )
        XCTAssertNotEqual(complete.revision, incomplete.revision)
    }

    func testAbsentOptionalFieldsRemainCompleteButRequiredPIDDoesNot() {
        let optionalAbsent = snapshot(model: model(
            childRole: .absent,
            childIdentifier: .absent,
            childFrame: .absent,
            childPosition: .absent,
            childSize: .absent,
            childChildren: .absent
        ))
        XCTAssertTrue(optionalAbsent.isComplete)

        let missingProvider = snapshot(model: MenuBarRawPhysicalStructureModel(
            providerProcessIdentifier: .absent,
            displays: [display()],
            nodes: [rootNode(children: .absent)]
        ))
        XCTAssertFalse(missingProvider.isComplete)
        XCTAssertFalse(snapshot(model: model(childPID: 0)).isComplete)
    }

    private func snapshot(
        model: MenuBarRawPhysicalStructureModel? = nil,
        diagnostics: MenuBarRawPhysicalStructureDiagnostics = .init()
    ) -> MenuBarRawPhysicalStructureSnapshot {
        MenuBarRawPhysicalStructureSnapshot(
            model: model ?? self.model(),
            diagnostics: diagnostics
        )
    }

    private func model(
        providerPID: Int32 = 42,
        displays: [MenuBarRawPhysicalDisplay]? = nil,
        nodes: [MenuBarRawPhysicalNode]? = nil,
        childPID: Int32 = 42,
        childRole: MenuBarRawPhysicalRead<String> = .value("AXButton"),
        childIdentifier: MenuBarRawPhysicalRead<String> = .value("status.item"),
        childFrame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> = .value(
            .init(x: 10, y: 0, width: 20, height: 24)
        ),
        childPosition: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint> = .value(
            .init(x: 10, y: 0)
        ),
        childSize: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize> = .value(
            .init(width: 20, height: 24)
        ),
        childChildren: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]> = .absent
    ) -> MenuBarRawPhysicalStructureModel {
        MenuBarRawPhysicalStructureModel(
            providerProcessIdentifier: .value(providerPID),
            displays: displays ?? [display()],
            nodes: nodes ?? [
                rootNode(children: .value([.node(path: [0])])),
                childNode(
                    pid: childPID,
                    role: childRole,
                    identifier: childIdentifier,
                    frame: childFrame,
                    position: childPosition,
                    size: childSize,
                    children: childChildren
                ),
            ]
        )
    }

    private func display(
        id: UInt32 = 1,
        x: Double = 0
    ) -> MenuBarRawPhysicalDisplay {
        MenuBarRawPhysicalDisplay(
            id: id,
            bounds: .value(.init(x: x, y: 0, width: 1_512, height: 982))
        )
    }

    private func rootNode(
        children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]>
    ) -> MenuBarRawPhysicalNode {
        MenuBarRawPhysicalNode(
            path: [],
            processIdentifier: .value(42),
            role: .value("AXApplication"),
            identifier: .absent,
            frame: .absent,
            position: .absent,
            size: .absent,
            children: children
        )
    }

    private func childNode(
        pid: Int32 = 42,
        role: MenuBarRawPhysicalRead<String> = .value("AXButton"),
        identifier: MenuBarRawPhysicalRead<String> = .value("status.item"),
        frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> = .value(
            .init(x: 10, y: 0, width: 20, height: 24)
        ),
        position: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint> = .value(
            .init(x: 10, y: 0)
        ),
        size: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize> = .value(
            .init(width: 20, height: 24)
        ),
        children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]> = .absent
    ) -> MenuBarRawPhysicalNode {
        MenuBarRawPhysicalNode(
            path: [0],
            processIdentifier: .value(pid),
            role: role,
            identifier: identifier,
            frame: frame,
            position: position,
            size: size,
            children: children
        )
    }
}
