import XCTest
@testable import DisplayMonitor

final class MenuBarRawPhysicalStructureGraphTests: XCTestCase {
    func testNodeStorageAndCompletionOrderDoNotChangeCanonicalModel() throws {
        let nodes = treeNodes()
        let forward = try XCTUnwrap(model(nodes: nodes))
        let reverse = try XCTUnwrap(model(nodes: nodes.reversed()))
        let scrambled = try XCTUnwrap(model(nodes: [nodes[3], nodes[0], nodes[4], nodes[2], nodes[1]]))

        XCTAssertEqual(reverse, forward)
        XCTAssertEqual(scrambled, forward)
    }

    func testCanonicalOutputUsesDFSPreorderAndOrderedAdjacency() throws {
        let result = try XCTUnwrap(model(nodes: treeNodes()))

        XCTAssertEqual(result.nodes.map(\.path), [
            [],
            [0],
            [0, 0],
            [0, 0, 0],
            [1],
        ])
        XCTAssertEqual(result.nodes.compactMap(identifier), [
            "root", "left", "deep", "shared", "right",
        ])
        XCTAssertEqual(result.nodes[0].children, .value([
            .node(path: [0]),
            .node(path: [1]),
        ]))
    }

    func testDeepLeftPathWinsFirstPathWhenBFSWouldSeeShallowRightFirst() throws {
        // A breadth-first reader discovers `shared` from right before it reads
        // deep's children. Canonicalization must retain the original DFS path.
        let result = try XCTUnwrap(model(nodes: treeNodes()))
        let shared = try XCTUnwrap(result.nodes.first {
            identifier($0) == "shared"
        })
        let right = try XCTUnwrap(result.nodes.first {
            identifier($0) == "right"
        })

        XCTAssertEqual(shared.path, [0, 0, 0])
        XCTAssertEqual(right.children, .value([
            .reference(firstPath: [0, 0, 0]),
        ]))
        XCTAssertEqual(result.nodes.filter { identifier($0) == "shared" }.count, 1)
    }

    func testCycleAndRepeatedIdentityBecomeReferencesWithoutDuplicateNodes() throws {
        let root = node(0, "root", children: .value([id(1), id(1)]))
        let child = node(1, "child", children: .value([id(0), id(1)]))
        let result = try XCTUnwrap(model(nodes: [child, root]))

        XCTAssertEqual(result.nodes.map(\.path), [[], [0]])
        XCTAssertEqual(result.nodes[0].children, .value([
            .node(path: [0]),
            .reference(firstPath: [0]),
        ]))
        XCTAssertEqual(result.nodes[1].children, .value([
            .reference(firstPath: []),
            .reference(firstPath: [0]),
        ]))
    }

    func testChangingOrderedAdjacencyChangesCanonicalPathsAndOutput() throws {
        let root = node(0, "root", children: .value([id(1), id(2)]))
        let first = node(1, "first")
        let second = node(2, "second")
        let original = try XCTUnwrap(model(nodes: [root, first, second]))
        let reorderedRoot = node(0, "root", children: .value([id(2), id(1)]))
        let reordered = try XCTUnwrap(model(nodes: [first, reorderedRoot, second]))

        XCTAssertEqual(original.nodes.compactMap(identifier), ["root", "first", "second"])
        XCTAssertEqual(reordered.nodes.compactMap(identifier), ["root", "second", "first"])
        XCTAssertNotEqual(reordered, original)
    }

    func testDuplicateNodeIdentityReturnsNil() {
        let duplicateRoot = node(0, "duplicate-root")

        XCTAssertNil(model(nodes: [node(0, "root"), duplicateRoot]))
    }

    func testMissingRootOrChildReturnsNil() {
        XCTAssertNil(model(nodes: [node(1, "orphan")]))
        XCTAssertNil(model(nodes: [
            node(0, "root", children: .value([id(99)])),
        ]))
    }

    func testUnreachableNodeReturnsNil() {
        XCTAssertNil(model(nodes: [
            node(0, "root"),
            node(1, "unreachable"),
        ]))
    }

    func testCanonicalDepthLimitUsesDFSPathInsteadOfBFSDiscoveryDepth() throws {
        // Every chain node is also a direct root child, so a BFS reader assigns
        // each one depth 1. DFS still reaches the last node through 33 edges.
        let withinLimit = shortCircuitedChain(lastNodeID: 32)
        let beyondLimit = shortCircuitedChain(lastNodeID: 33)

        let accepted = try XCTUnwrap(model(nodes: withinLimit, maxDepth: 32))
        XCTAssertEqual(
            accepted.nodes.first { identifier($0) == "node-32" }?.path.count,
            32
        )
        XCTAssertNil(model(nodes: beyondLimit, maxDepth: 32))
    }

    func testMaximumNodeCountAcceptsExactBoundaryAndRejectsOneLess() {
        let nodes = treeNodes()

        XCTAssertNotNil(model(nodes: nodes, maxNodeCount: nodes.count))
        XCTAssertNil(model(nodes: nodes, maxNodeCount: nodes.count - 1))
    }

    func testContinuationGateCanStopCanonicalizationMidTraversal() {
        var checks = 0
        let result = model(
            nodes: [
                node(0, "root", children: .value([id(1)])),
                node(1, "child"),
            ],
            shouldContinue: {
                checks += 1
                return checks < 4
            }
        )

        XCTAssertNil(result)
        XCTAssertGreaterThan(checks, 1)
    }

    func testAbsentAndFailedChildrenArePreservedExactly() throws {
        let absent = try XCTUnwrap(model(nodes: [
            node(0, "root", children: .absent),
        ]))
        let failed = try XCTUnwrap(model(nodes: [
            node(0, "root", children: .failed),
        ]))

        XCTAssertEqual(absent.nodes.count, 1)
        XCTAssertEqual(absent.nodes[0].children, .absent)
        XCTAssertEqual(failed.nodes.count, 1)
        XCTAssertEqual(failed.nodes[0].children, .failed)
    }

    func testProviderAndDisplayEvidencePassThroughUnchanged() throws {
        let provider: MenuBarRawPhysicalRead<Int32> = .value(900)
        let displays = [
            MenuBarRawPhysicalDisplay(
                id: 2,
                bounds: .value(.init(x: 1_512, y: 0, width: 1_512, height: 982))
            ),
            MenuBarRawPhysicalDisplay(
                id: 1,
                bounds: .failed
            ),
        ]
        let graph = MenuBarRawPhysicalStructureGraph(
            rootID: id(0),
            nodes: [node(0, "root")]
        )
        let result = try XCTUnwrap(MenuBarRawPhysicalCanonicalGraphBuilder.makeModel(
            providerProcessIdentifier: provider,
            displays: displays,
            graph: graph
        ))

        XCTAssertEqual(result.providerProcessIdentifier, provider)
        XCTAssertEqual(result.displays, displays)
    }

    private func treeNodes() -> [MenuBarRawPhysicalGraphNode] {
        [
            node(0, "root", children: .value([id(1), id(2)])),
            node(1, "left", children: .value([id(3)])),
            node(2, "right", children: .value([id(4)])),
            node(3, "deep", children: .value([id(4)])),
            node(4, "shared"),
        ]
    }

    private func shortCircuitedChain(
        lastNodeID: Int
    ) -> [MenuBarRawPhysicalGraphNode] {
        precondition(lastNodeID > 0)
        var nodes = [node(
            0,
            "root",
            children: .value((1...lastNodeID).map(id))
        )]
        nodes.append(contentsOf: (1...lastNodeID).map { rawID in
            node(
                rawID,
                "node-\(rawID)",
                children: rawID == lastNodeID
                    ? .absent
                    : .value([id(rawID + 1)])
            )
        })
        return nodes
    }

    private func model<S: Sequence>(
        nodes: S,
        rootID: MenuBarRawPhysicalGraphNodeID? = nil,
        maxNodeCount: Int = .max,
        maxDepth: Int = .max,
        shouldContinue: () -> Bool = { true }
    ) -> MenuBarRawPhysicalStructureModel? where S.Element == MenuBarRawPhysicalGraphNode {
        MenuBarRawPhysicalCanonicalGraphBuilder.makeModel(
            providerProcessIdentifier: .value(42),
            displays: [MenuBarRawPhysicalDisplay(
                id: 1,
                bounds: .value(.init(x: 0, y: 0, width: 1_512, height: 982))
            )],
            graph: MenuBarRawPhysicalStructureGraph(
                rootID: rootID ?? id(0),
                nodes: Array(nodes)
            ),
            maxNodeCount: maxNodeCount,
            maxDepth: maxDepth,
            shouldContinue: shouldContinue
        )
    }

    private func node(
        _ rawID: Int,
        _ identifier: String,
        children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalGraphNodeID]> = .absent
    ) -> MenuBarRawPhysicalGraphNode {
        MenuBarRawPhysicalGraphNode(
            id: id(rawID),
            processIdentifier: .value(42),
            role: .value(rawID == 0 ? "AXApplication" : "AXGroup"),
            identifier: .value(identifier),
            frame: .absent,
            position: .absent,
            size: .absent,
            children: children
        )
    }

    private func id(_ rawValue: Int) -> MenuBarRawPhysicalGraphNodeID {
        MenuBarRawPhysicalGraphNodeID(rawValue: rawValue)
    }

    private func identifier(_ node: MenuBarRawPhysicalNode) -> String? {
        guard case .value(let value) = node.identifier else { return nil }
        return value
    }
}
