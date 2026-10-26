import CoreGraphics
import XCTest
@testable import DisplayMonitor

final class MenuBarDuplicatePhysicalRootsTests: XCTestCase {
    private let anchor = MenuBarAnchorIdentity(
        bundleIdentifier: "example.monitor", title: "Monitor", accessibilityIdentifier: "monitor.anchor")
    private var applications: [RunningAppSnapshot] {
        [.init(bundleIdentifier: "com.apple.MenuBarAgent", name: "MenuBarAgent", processIdentifier: 500),
         .init(bundleIdentifier: "example.monitor", name: "Monitor", processIdentifier: 100),
         .init(bundleIdentifier: "example.left", name: "Left", processIdentifier: 200),
         .init(bundleIdentifier: "example.other", name: "Other", processIdentifier: 300)]
    }

    func testEquivalentDuplicateWindowsWithSharedOpaqueOwnersCountEachPhysicalItemOnce() throws {
        let snapshot = fixture()
        XCTAssertTrue(snapshot.isComplete)
        let result = try XCTUnwrap(current(snapshot))
        XCTAssertEqual(result.items.count, 6)
        XCTAssertEqual(result.coverage.expectedDisplayIDs, [1, 2, 5])
        XCTAssertEqual(try result.validatedLayouts().map(\.displayID), [1, 2, 5])
        XCTAssertEqual(try result.collapseTargetBundleIdentifiers(
            protectionPolicy: .init(ownBundleIdentifier: anchor.bundleIdentifier)), ["example.left"])
        XCTAssertNotNil(MenuBarPhysicalInventoryEvidence(snapshot: snapshot, inventory: result))
        XCTAssertEqual(snapshot.model.nodes.filter(\.isOpaqueApplicationProxy).count, 2,
            "All four roots share the same two opaque owner references.")
    }

    func testEquivalentDuplicateWindowsMayUseIndependentOpaqueOwnerNodes() throws {
        var value = fixture()
        for (index, owner) in [(0, Int32(200)), (1, Int32(100))] {
            value = replacing(value, path: [3, index], children: .value([.node(path: [3, index, 0])]))
            value = snapshot(nodes: value.model.nodes + [node([3, index, 0], pid: owner, opaque: true)])
        }
        let inventory = try XCTUnwrap(current(value))
        XCTAssertEqual(inventory.items.count, 6)
        XCTAssertNotNil(MenuBarPhysicalInventoryEvidence(snapshot: value, inventory: inventory))
    }

    func testEquivalentWindowOrderDoesNotChangePhysicalCountsOrTargets() throws {
        let snapshot = fixture()
        let reordered = replacing(snapshot, path: [], children: .value([
            .node(path: [3]), .node(path: [1]), .node(path: [0]), .node(path: [2])]))
        let first = try XCTUnwrap(current(snapshot))
        let second = try XCTUnwrap(current(reordered))
        XCTAssertEqual(second.items.count, first.items.count)
        XCTAssertEqual(Set(second.items.map(\.displayID)), Set(first.items.map(\.displayID)))
        XCTAssertEqual(try second.collapseTargetBundleIdentifiers(
            protectionPolicy: .init(ownBundleIdentifier: anchor.bundleIdentifier)), ["example.left"])
    }

    func testConflictingPositionOwnerIdentifierOrProxySemanticsRejectBothProofPaths() throws {
        let original = fixture()
        let inventory = try XCTUnwrap(current(original))
        let variants = [
            replacing(original, path: [3, 0], frame: .value(rect(x: 1_821, y: 985, width: 20))),
            replacing(original, path: [3, 0], children: .value([.reference(firstPath: [0, 1, 0])])),
            replacing(original, path: [3, 0], identifier: .value("unexpected.identifier")),
            replacing(original, path: [3, 0], pid: 200, role: .value("AXButton"), children: .value([])),
            replacing(original, path: [3], frame: .value(rect(x: 1_800, y: 985, width: 999))),
        ]
        for snapshot in variants {
            assertRejected(snapshot, inventory: inventory)
        }
    }

    func testMissingItemUnknownLeafAndDuplicateWithinOneRootCannotBeDeduplicatedAway() throws {
        let original = fixture()
        let inventory = try XCTUnwrap(current(original))
        let missing = replacing(original, path: [3], children: .value([.node(path: [3, 1])]),
            removing: [[3, 0]])
        let unknown = replacing(original, path: [3, 0], role: .value("AXUnknown"), children: .value([]))
        let duplicate = replacing(original, path: [3], children: .value([
            .node(path: [3, 0]), .node(path: [3, 1]), .reference(firstPath: [3, 0])]))
        let repeatedItem = node([3, 2], pid: 500,
            frame: .value(rect(x: 1_820, y: 985, width: 20)),
            children: .value([.reference(firstPath: [0, 0, 0])]))
        let extraNode = snapshot(nodes: original.model.nodes + [repeatedItem])
        let duplicateKey = replacing(extraNode, path: [3], children: .value([
            .node(path: [3, 0]), .node(path: [3, 1]), .node(path: [3, 2])]))
        for snapshot in [missing, unknown, duplicate, duplicateKey] {
            assertRejected(snapshot, inventory: inventory)
        }
    }

    func testCrossDisplayItemCycleFailedReadAndUnreachableNodeRemainRejected() throws {
        let original = fixture()
        let inventory = try XCTUnwrap(current(original))
        let crossDisplay = replacing(original, path: [3, 0], frame: .value(rect(x: 20, y: 0, width: 20)))
        let cycle = replacing(original, path: [3, 0], children: .value([.reference(firstPath: [3])]))
        let failed = replacing(original, path: [3, 0], identifier: .failed)
        var orphanNodes = original.model.nodes
        orphanNodes.append(node([99], pid: 300, role: .value("AXButton"),
            frame: .value(rect(x: 90, y: 0, width: 20))))
        let orphan = snapshot(nodes: orphanNodes)
        for value in [crossDisplay, cycle, failed, orphan] {
            assertRejected(value, inventory: inventory)
        }
    }

    func testAdditionalMenuBarAliasMayReferenceAlreadyProvenSystemItems() throws {
        let original = fixture()
        var nodes = original.model.nodes
        // A system item is duplicated with its complete display-2 window,
        // then re-exposed through a separate local AXMenuBar alias root.
        for root in [2, 3] {
            nodes.append(node([root, 2], pid: 500, role: .value("AXButton"),
                frame: .value(rect(x: 1_900, y: 985, width: 20))))
        }
        nodes.append(node([4], pid: 500, role: .value("AXMenuBar"),
            frame: .value(rect(x: 1_900, y: 985, width: 20)),
            children: .value([.reference(firstPath: [2, 2]), .reference(firstPath: [3, 2])])))
        var value = snapshot(nodes: nodes)
        for root in [2, 3] {
            value = replacing(value, path: [root], children: .value([
                .node(path: [root, 0]), .node(path: [root, 1]), .node(path: [root, 2])]))
        }
        value = replacing(value, path: [], children: .value((0..<5).map { .node(path: [$0]) }))
        let inventory = try XCTUnwrap(current(value))
        XCTAssertEqual(inventory.items.count, 7)
        XCTAssertEqual(inventory.items.filter { $0.displayID == 2 }.count, 3)
        XCTAssertNotNil(MenuBarPhysicalInventoryEvidence(snapshot: value, inventory: inventory))
    }

    func testAliasCannotIntroducePhysicalItemsOpaqueOwnersOrUnknownLeavesOutsideWindows() throws {
        let original = fixture()
        let inventory = try XCTUnwrap(current(original))
        let hiddenNodes = [
            node([4, 0], pid: 300, role: .value("AXButton"),
                frame: .value(rect(x: 1_900, y: 985, width: 20))),
            node([4, 0], pid: 100, opaque: true),
            node([4, 0], pid: 500, role: .value("AXUnknown")),
        ]
        for hidden in hiddenNodes {
            let alias = node([4], pid: 500, role: .value("AXMenuBar"),
                children: .value([.node(path: [4, 0])]))
            let value = replacing(snapshot(nodes: original.model.nodes + [alias, hidden]),
                path: [], children: .value((0..<5).map { .node(path: [$0]) }))
            assertRejected(value, inventory: inventory)
        }
    }

    func testInventoryCannotOmitOrAddAnItemAfterEquivalentRootsAreProven() throws {
        let value = fixture()
        let inventory = try XCTUnwrap(current(value))
        for items in [Array(inventory.items.dropLast()), inventory.items + [inventory.items[0]]] {
            let changed = AnchoredMenuBarInventory(items: items,
                coverage: .init(expectedDisplayIDs: [1, 2, 5],
                    observedCandidateCount: items.count, resolvedItemCount: items.count), anchorIdentity: anchor)
            XCTAssertNil(MenuBarPhysicalInventoryEvidence(snapshot: value, inventory: changed))
        }
    }

    private func current(_ snapshot: MenuBarRawPhysicalStructureSnapshot) -> AnchoredMenuBarInventory? {
        MenuBarPhysicalInventoryEvidence.currentInventory(snapshot: snapshot,
            applicationsBefore: applications, applicationsAfter: applications, anchor: anchor,
            ownedStatusItems: .init(processIdentifier: 100, mainEntryVisible: true, visibleItemCount: 1))
    }

    private func assertRejected(_ snapshot: MenuBarRawPhysicalStructureSnapshot,
        inventory: AnchoredMenuBarInventory, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(current(snapshot), file: file, line: line)
        XCTAssertNil(MenuBarPhysicalInventoryEvidence(snapshot: snapshot, inventory: inventory), file: file, line: line)
    }

    private func rect(x: Double, y: Double, width: Double, height: Double = 30) -> MenuBarRawPhysicalRect {
        .init(x: x, y: y, width: width, height: height)
    }

    private func fixture() -> MenuBarRawPhysicalStructureSnapshot {
        var nodes = [node([], pid: 500, role: .value("AXApplication"), children: .value(
            (0..<4).map { .node(path: [$0]) }))]
        for (root, x, y) in [(0, 0.0, 0.0), (1, 1_800.0, -95.0),
                             (2, 1_800.0, 985.0), (3, 1_800.0, 985.0)] {
            nodes.append(node([root], pid: 500, role: .value("AXWindow"),
                frame: .value(rect(x: x, y: y, width: 1_000)), children: .value([
                    .node(path: [root, 0]), .node(path: [root, 1])])))
            for (index, owner) in [(0, Int32(200)), (1, Int32(100))] {
                let child: MenuBarRawPhysicalChild = root == 0
                    ? .node(path: [0, index, 0]) : .reference(firstPath: [0, index, 0])
                nodes.append(node([root, index], pid: 500,
                    frame: .value(rect(x: x + Double(20 + index * 40), y: y, width: 20)),
                    children: .value([child])))
                if root == 0 {
                    nodes.append(node([0, index, 0], pid: owner, opaque: true))
                }
            }
        }
        return snapshot(nodes: nodes)
    }

    private func snapshot(nodes: [MenuBarRawPhysicalNode]) -> MenuBarRawPhysicalStructureSnapshot {
        .init(model: .init(providerProcessIdentifier: .value(500), displays: [
            .init(id: 1, bounds: .value(rect(x: 0, y: 0, width: 1_000, height: 900))),
            .init(id: 2, bounds: .value(rect(x: 1_800, y: 985, width: 1_000, height: 1_080))),
            .init(id: 5, bounds: .value(rect(x: 1_800, y: -95, width: 1_000, height: 1_080))),
        ], nodes: nodes))
    }

    private func node(_ path: [Int], pid: Int32,
        role: MenuBarRawPhysicalRead<String> = .absent,
        frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> = .absent,
        children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]> = .absent,
        opaque: Bool = false) -> MenuBarRawPhysicalNode {
        .init(path: path, processIdentifier: .value(pid), role: role, identifier: .absent,
            frame: frame, position: .absent, size: .absent, children: children,
            isOpaqueApplicationProxy: opaque)
    }

    private func replacing(_ original: MenuBarRawPhysicalStructureSnapshot, path: [Int],
        pid: Int32? = nil, role: MenuBarRawPhysicalRead<String>? = nil,
        identifier: MenuBarRawPhysicalRead<String>? = nil,
        frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>? = nil,
        children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]>? = nil,
        removing: [[Int]] = []) -> MenuBarRawPhysicalStructureSnapshot {
        snapshot(nodes: original.model.nodes.filter { !removing.contains($0.path) }.map { old in
            guard old.path == path else { return old }
            return .init(path: old.path, processIdentifier: pid.map { .value($0) } ?? old.processIdentifier,
                role: role ?? old.role, identifier: identifier ?? old.identifier, frame: frame ?? old.frame,
                position: old.position, size: old.size, children: children ?? old.children,
                isOpaqueApplicationProxy: old.isOpaqueApplicationProxy)
        })
    }
}
