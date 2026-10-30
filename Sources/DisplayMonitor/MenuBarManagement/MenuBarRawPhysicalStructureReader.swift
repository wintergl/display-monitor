import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

enum MenuBarRawPhysicalRead<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case absent
    case failed
}

struct MenuBarRawPhysicalRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct MenuBarRawPhysicalPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct MenuBarRawPhysicalSize: Equatable, Sendable {
    let width: Double
    let height: Double
}

struct MenuBarRawPhysicalDisplay: Equatable, Sendable {
    let id: UInt32
    let bounds: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>
}

enum MenuBarRawPhysicalChild: Equatable, Sendable {
    case node(path: [Int])
    case reference(firstPath: [Int])
}

struct MenuBarRawPhysicalNode: Equatable, Sendable {
    let path: [Int]
    let processIdentifier: MenuBarRawPhysicalRead<Int32>
    let role: MenuBarRawPhysicalRead<String>
    let identifier: MenuBarRawPhysicalRead<String>
    let frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>
    let position: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint>
    let size: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize>
    let children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]>
    /// Foreign AXApplication roots are opaque ownership references, not an
    /// invitation to read unrelated windows, menus, or document contents.
    var isOpaqueApplicationProxy: Bool = false
}

struct MenuBarRawPhysicalStructureModel: Equatable, Sendable {
    let providerProcessIdentifier: MenuBarRawPhysicalRead<Int32>
    let displays: [MenuBarRawPhysicalDisplay]
    let nodes: [MenuBarRawPhysicalNode]
}

struct MenuBarRawPhysicalGraphNodeID: Hashable, Sendable {
    let rawValue: Int
}

struct MenuBarRawPhysicalGraphNode: Equatable, Sendable {
    let id: MenuBarRawPhysicalGraphNodeID
    let processIdentifier: MenuBarRawPhysicalRead<Int32>
    let role: MenuBarRawPhysicalRead<String>
    let identifier: MenuBarRawPhysicalRead<String>
    let frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>
    let position: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint>
    let size: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize>
    let children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalGraphNodeID]>
    var isOpaqueApplicationProxy: Bool = false
}

struct MenuBarRawPhysicalStructureGraph: Equatable, Sendable {
    let rootID: MenuBarRawPhysicalGraphNodeID
    let nodes: [MenuBarRawPhysicalGraphNode]
}

/// Converts unordered graph storage into the original deterministic DFS model.
/// First paths and references are assigned only here, after every read finishes.
enum MenuBarRawPhysicalCanonicalGraphBuilder {
    static func makeModel(
        providerProcessIdentifier: MenuBarRawPhysicalRead<Int32>,
        displays: [MenuBarRawPhysicalDisplay],
        graph: MenuBarRawPhysicalStructureGraph,
        maxNodeCount: Int = .max,
        maxDepth: Int = .max,
        shouldContinue: () -> Bool = { true }
    ) -> MenuBarRawPhysicalStructureModel? {
        guard maxNodeCount > 0,
              maxDepth >= 0,
              graph.nodes.count <= maxNodeCount,
              shouldContinue() else { return nil }
        let grouped = Dictionary(grouping: graph.nodes, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else { return nil }
        let nodesByID = grouped.mapValues { $0[0] }
        guard nodesByID[graph.rootID] != nil else { return nil }

        var firstPaths: [MenuBarRawPhysicalGraphNodeID: [Int]] = [:]
        guard let nodes = canonicalNodes(
            id: graph.rootID,
            path: [],
            nodesByID: nodesByID,
            firstPaths: &firstPaths,
            maxDepth: maxDepth,
            shouldContinue: shouldContinue
        ), firstPaths.count == nodesByID.count,
           shouldContinue() else { return nil }
        return MenuBarRawPhysicalStructureModel(
            providerProcessIdentifier: providerProcessIdentifier,
            displays: displays,
            nodes: nodes
        )
    }

    private static func canonicalNodes(
        id: MenuBarRawPhysicalGraphNodeID,
        path: [Int],
        nodesByID: [MenuBarRawPhysicalGraphNodeID: MenuBarRawPhysicalGraphNode],
        firstPaths: inout [MenuBarRawPhysicalGraphNodeID: [Int]],
        maxDepth: Int,
        shouldContinue: () -> Bool
    ) -> [MenuBarRawPhysicalNode]? {
        guard shouldContinue(),
              path.count <= maxDepth,
              firstPaths[id] == nil,
              let source = nodesByID[id] else { return nil }
        firstPaths[id] = path

        let children: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]>
        var descendants: [MenuBarRawPhysicalNode] = []
        switch source.children {
        case .absent:
            children = .absent
        case .failed:
            children = .failed
        case .value(let childIDs):
            var edges: [MenuBarRawPhysicalChild] = []
            edges.reserveCapacity(childIDs.count)
            for (index, childID) in childIDs.enumerated() {
                guard shouldContinue() else { return nil }
                let childPath = path + [index]
                if let firstPath = firstPaths[childID] {
                    edges.append(.reference(firstPath: firstPath))
                    continue
                }
                guard nodesByID[childID] != nil,
                      let childNodes = canonicalNodes(
                          id: childID,
                          path: childPath,
                          nodesByID: nodesByID,
                          firstPaths: &firstPaths,
                          maxDepth: maxDepth,
                          shouldContinue: shouldContinue
                      ) else { return nil }
                edges.append(.node(path: childPath))
                descendants.append(contentsOf: childNodes)
            }
            children = .value(edges)
        }

        let node = MenuBarRawPhysicalNode(
            path: path,
            processIdentifier: source.processIdentifier,
            role: source.role,
            identifier: source.identifier,
            frame: source.frame,
            position: source.position,
            size: source.size,
            children: children,
            isOpaqueApplicationProxy: source.isOpaqueApplicationProxy
        )
        return [node] + descendants
    }
}

enum MenuBarRawPhysicalStructureFailureReason: String, CaseIterable, Hashable, Sendable {
    case providerMissing
    case providerAmbiguous
    case providerPIDInvalid
    case activeDisplaysUnavailable
    case activeDisplayBoundsInvalid
    case rootPIDMismatch
    case nodePIDReadFailed
    case nodePIDInvalid
    case roleReadFailed
    case roleWrongType
    case identifierReadFailed
    case identifierWrongType
    case frameReadFailed
    case frameWrongType
    case frameNonFinite
    case positionReadFailed
    case positionWrongType
    case positionNonFinite
    case sizeReadFailed
    case sizeWrongType
    case sizeNonFinite
    case childrenReadFailed
    case childrenWrongType
    case deadlineExceeded
    case cancelled
    case nodeLimitExceeded
    case depthLimitExceeded
    case graphMalformed
}

struct MenuBarRawPhysicalStructureDiagnostics: Equatable, Sendable {
    private(set) var counts: [MenuBarRawPhysicalStructureFailureReason: Int] = [:]

    var totalCount: Int { counts.values.reduce(0, +) }

    var summary: String {
        let parts = counts
            .filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    mutating func record(
        _ reason: MenuBarRawPhysicalStructureFailureReason,
        count: Int = 1
    ) {
        guard count > 0 else { return }
        counts[reason, default: 0] += count
    }

    mutating func merge(_ other: Self) {
        for (reason, count) in other.counts {
            record(reason, count: count)
        }
    }
}

struct MenuBarRawPhysicalStructureSnapshot: Equatable, Sendable {
    // In-memory only. The revision remains a temporal fence; semantic physical
    // evidence must be independently constructed from these typed fields.
    let model: MenuBarRawPhysicalStructureModel
    let revision: String
    let isComplete: Bool
    let nodeCount: Int
    let diagnostics: MenuBarRawPhysicalStructureDiagnostics
    let offscreenReplicaEvidence: [MenuBarOffscreenReplicaEvidence]

    init(
        model: MenuBarRawPhysicalStructureModel,
        diagnostics: MenuBarRawPhysicalStructureDiagnostics = .init(),
        offscreenReplicaEvidence: [MenuBarOffscreenReplicaEvidence] = []
    ) {
        self.model = model
        revision = MenuBarRawPhysicalStructureRevision.make(
            model: model,
            diagnostics: diagnostics
        )
        isComplete = diagnostics.totalCount == 0 && model.hasNoFailedReads
        nodeCount = model.nodes.count
        self.diagnostics = diagnostics
        self.offscreenReplicaEvidence = offscreenReplicaEvidence
    }
}

private extension MenuBarRawPhysicalStructureModel {
    var hasNoFailedReads: Bool {
        guard case .value(let providerPID) = providerProcessIdentifier,
              providerPID > 0,
              !nodes.isEmpty else { return false }
        guard !displays.isEmpty,
              displays.allSatisfy({ display in
                  if case .value = display.bounds { return true }
                  return false
              }) else { return false }
        return nodes.allSatisfy { node in
            let validProxy = !node.isOpaqueApplicationProxy || (
                !node.path.isEmpty && node.children == .absent && node.identifier == .absent
                    && node.frame == .absent && node.position == .absent && node.size == .absent
                    && (node.role == .absent || node.role == .value(kAXApplicationRole))
            )
            return validProxy && hasValidPID(node.processIdentifier)
                && !isFailed(node.role)
                && !isFailed(node.identifier)
                && !isFailed(node.frame)
                && !isFailed(node.position)
                && !isFailed(node.size)
                && !isFailed(node.children)
        }
    }

    private func isFailed<Value>(
        _ read: MenuBarRawPhysicalRead<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .failed = read { return true }
        return false
    }

    private func hasValidPID(_ read: MenuBarRawPhysicalRead<Int32>) -> Bool {
        if case .value(let pid) = read { return pid > 0 }
        return false
    }
}

/// Synchronous worker API. Callers are responsible for invoking it from their
/// detached worker after capturing the applications value snapshot on MainActor.
/// Every CG/AX read and revision calculation stays inside this single deadline.
enum MenuBarRawPhysicalStructureReader {
    private final class ElementHandle: @unchecked Sendable {
        let element: AXUIElement

        init(_ element: AXUIElement) {
            self.element = element
        }
    }

    private struct PendingNode: Sendable {
        let sequence: Int
        let id: MenuBarRawPhysicalGraphNodeID
        let element: ElementHandle
        let depth: Int
    }

    private enum WorkerChildren: @unchecked Sendable {
        case value([ElementHandle])
        case absent
        case failed
    }

    private struct WorkerResult: Sendable {
        let sequence: Int
        let id: MenuBarRawPhysicalGraphNodeID
        let depth: Int
        let processIdentifier: MenuBarRawPhysicalRead<Int32>
        let role: MenuBarRawPhysicalRead<String>
        let identifier: MenuBarRawPhysicalRead<String>
        let frame: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>
        let position: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint>
        let size: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize>
        let children: WorkerChildren
        let diagnostics: MenuBarRawPhysicalStructureDiagnostics
        let hitDeadline: Bool
        var isOpaqueApplicationProxy: Bool = false
    }

    private final class ResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [WorkerResult] = []

        func append(_ value: WorkerResult) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func sortedValues() -> [WorkerResult] {
            lock.lock()
            defer { lock.unlock() }
            return values.sorted { $0.sequence < $1.sequence }
        }
    }

    static func read(
        applications: [RunningAppSnapshot],
        timeBudget: TimeInterval = 0.18,
        frontmostProcessIdentifier: Int32? = nil
    ) -> MenuBarRawPhysicalStructureSnapshot {
        var scanner = Scanner(
            applications: applications,
            timeBudget: min(max(0, timeBudget), 0.18),
            frontmostProcessIdentifier: frontmostProcessIdentifier
        )
        return scanner.run()
    }

    private struct Scanner {
        private enum IdentityLookup {
            case found(MenuBarRawPhysicalGraphNodeID)
            case notFound
            case failed
        }

        private let applications: [RunningAppSnapshot]
        private let frontmostProcessIdentifier: Int32?
        private let deadline: TimeInterval
        private let nodeLimit = 1_800
        private let depthLimit = 32
        // Fixed upper bound proven against the expanded 64-67 node tree. Each
        // chunk still joins completely before the coordinator mutates the graph.
        private let workerLimit = 8
        private var visited: [
            CFHashCode: [(element: ElementHandle, id: MenuBarRawPhysicalGraphNodeID)]
        ] = [:]
        private var nextID = 1
        private var nextSequence = 1
        private var diagnostics = MenuBarRawPhysicalStructureDiagnostics()
        private var recordedTerminalReasons: Set<
            MenuBarRawPhysicalStructureFailureReason
        > = []

        init(applications: [RunningAppSnapshot], timeBudget: TimeInterval, frontmostProcessIdentifier: Int32?) {
            self.applications = applications
            self.frontmostProcessIdentifier = frontmostProcessIdentifier
            deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        }

        mutating func run() -> MenuBarRawPhysicalStructureSnapshot {
            let displays = readDisplays()
            let providers = applications.filter {
                $0.bundleIdentifier == "com.apple.MenuBarAgent"
            }
            guard providers.count == 1 else {
                diagnostics.record(
                    providers.isEmpty ? .providerMissing : .providerAmbiguous
                )
                return snapshot(model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: providers.isEmpty ? .absent : .failed,
                    displays: displays,
                    nodes: []
                ))
            }

            let provider = providers[0]
            guard provider.processIdentifier > 0 else {
                diagnostics.record(.providerPIDInvalid)
                return snapshot(model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: .value(provider.processIdentifier),
                    displays: displays,
                    nodes: []
                ))
            }
            guard ensureCanContinue() else {
                return snapshot(model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: .value(provider.processIdentifier),
                    displays: displays,
                    nodes: []
                ))
            }

            let root = ElementHandle(
                AXUIElementCreateApplication(provider.processIdentifier)
            )
            let graph = readGraph(root: root, providerPID: provider.processIdentifier)
            if let root = graph.nodes.first(where: { $0.id == graph.rootID }),
               case .value(let actualPID) = root.processIdentifier,
               actualPID != provider.processIdentifier {
                diagnostics.record(.rootPIDMismatch)
            }
            _ = ensureCanContinue()
            guard let model = MenuBarRawPhysicalCanonicalGraphBuilder.makeModel(
                providerProcessIdentifier: .value(provider.processIdentifier),
                displays: displays,
                graph: graph,
                maxNodeCount: nodeLimit,
                maxDepth: depthLimit,
                shouldContinue: { ensureCanContinue() }
            ) else {
                diagnostics.record(.graphMalformed)
                return snapshot(model: MenuBarRawPhysicalStructureModel(
                    providerProcessIdentifier: .value(provider.processIdentifier),
                    displays: displays,
                    nodes: []
                ))
            }
            return snapshot(model: model)
        }

        private mutating func readGraph(
            root: ElementHandle,
            providerPID: Int32
        ) -> MenuBarRawPhysicalStructureGraph {
            let rootID = MenuBarRawPhysicalGraphNodeID(rawValue: 0)
            visited[CFHash(root.element)] = [(root, rootID)]
            var level = [PendingNode(
                sequence: 0,
                id: rootID,
                element: root,
                depth: 0
            )]
            var graphNodes: [MenuBarRawPhysicalGraphNode] = []

            while !level.isEmpty {
                guard ensureCanContinue() else { break }
                var nextLevel: [PendingNode] = []
                for start in stride(from: 0, to: level.count, by: workerLimit) {
                    guard ensureCanContinue() else { break }
                    let end = min(level.count, start + workerLimit)
                    let chunk = Array(level[start..<end])
                    let collector = ResultCollector()
                    let workerDeadline = deadline
                    for pending in chunk {
                        NodeWorker.prepare(
                            pending.element.element,
                            deadline: workerDeadline
                        )
                    }
                    let group = DispatchGroup()
                    for pending in chunk {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            collector.append(NodeWorker.read(
                                pending,
                                deadline: workerDeadline,
                                providerPID: providerPID
                            ))
                            group.leave()
                        }
                    }
                    group.wait()
                    for result in collector.sortedValues() {
                        diagnostics.merge(result.diagnostics)
                        if result.hitDeadline {
                            recordTerminalReasonOnce(.deadlineExceeded)
                        }
                        let children = resolveChildren(
                            result.children,
                            parentDepth: result.depth,
                            nextLevel: &nextLevel
                        )
                        graphNodes.append(MenuBarRawPhysicalGraphNode(
                            id: result.id,
                            processIdentifier: result.processIdentifier,
                            role: result.role,
                            identifier: result.identifier,
                            frame: result.frame,
                            position: result.position,
                            size: result.size,
                            children: children,
                            isOpaqueApplicationProxy: result.isOpaqueApplicationProxy
                        ))
                    }
                    if Task.isCancelled {
                        recordTerminalReasonOnce(.cancelled)
                        break
                    }
                    guard ensureCanContinue() else { break }
                }
                level = nextLevel
            }
            return MenuBarRawPhysicalStructureGraph(
                rootID: rootID,
                nodes: graphNodes
            )
        }

        private mutating func resolveChildren(
            _ children: WorkerChildren,
            parentDepth: Int,
            nextLevel: inout [PendingNode]
        ) -> MenuBarRawPhysicalRead<[MenuBarRawPhysicalGraphNodeID]> {
            switch children {
            case .absent:
                return .absent
            case .failed:
                return .failed
            case .value(let elements):
                guard !elements.isEmpty else { return .value([]) }
                guard parentDepth < depthLimit else {
                    diagnostics.record(.depthLimitExceeded)
                    return .failed
                }
                var ids: [MenuBarRawPhysicalGraphNodeID] = []
                ids.reserveCapacity(elements.count)
                for element in elements {
                    guard ensureCanContinue() else { return .failed }
                    switch identity(of: element) {
                    case .found(let id):
                        ids.append(id)
                    case .failed:
                        return .failed
                    case .notFound:
                        guard nextID < nodeLimit else {
                            diagnostics.record(.nodeLimitExceeded)
                            return .failed
                        }
                        let id = MenuBarRawPhysicalGraphNodeID(rawValue: nextID)
                        nextID += 1
                        visited[CFHash(element.element), default: []].append(
                            (element, id)
                        )
                        nextLevel.append(PendingNode(
                            sequence: nextSequence,
                            id: id,
                            element: element,
                            depth: parentDepth + 1
                        ))
                        nextSequence += 1
                        ids.append(id)
                    }
                }
                return .value(ids)
            }
        }

        private mutating func identity(
            of element: ElementHandle
        ) -> IdentityLookup {
            let hash = CFHash(element.element)
            guard let candidates = visited[hash] else { return .notFound }
            for candidate in candidates {
                guard ensureCanContinue() else { return .failed }
                if CFEqual(candidate.element.element, element.element) {
                    return .found(candidate.id)
                }
            }
            return .notFound
        }

        private mutating func snapshot(
            model: MenuBarRawPhysicalStructureModel
        ) -> MenuBarRawPhysicalStructureSnapshot {
            guard ensureCanContinue() else {
                return MenuBarRawPhysicalStructureSnapshot(
                    model: model,
                    diagnostics: diagnostics
                )
            }
            let snapshot = MenuBarRawPhysicalStructureSnapshot(
                model: model,
                diagnostics: diagnostics
            )
            guard ensureCanContinue() else {
                return MenuBarRawPhysicalStructureSnapshot(
                    model: model,
                    diagnostics: diagnostics
                )
            }
            guard snapshot.isComplete else { return snapshot }
            let evidence = MenuBarReplicaVisibilityReader.read(
                snapshot: snapshot, applications: applications, deadline: deadline,
                frontmostProcessIdentifier: frontmostProcessIdentifier
            )
            guard !evidence.isEmpty else { return snapshot }
            guard ensureCanContinue() else {
                return MenuBarRawPhysicalStructureSnapshot(model: model, diagnostics: diagnostics)
            }
            return MenuBarRawPhysicalStructureSnapshot(
                model: model, diagnostics: diagnostics, offscreenReplicaEvidence: evidence
            )
        }

        private mutating func readDisplays() -> [MenuBarRawPhysicalDisplay] {
            guard ensureCanContinue() else { return [] }
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success,
                  count > 0 else {
                diagnostics.record(.activeDisplaysUnavailable)
                return []
            }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            var actualCount: UInt32 = 0
            let error = ids.withUnsafeMutableBufferPointer {
                CGGetActiveDisplayList(count, $0.baseAddress, &actualCount)
            }
            guard error == .success, actualCount == count else {
                diagnostics.record(.activeDisplaysUnavailable)
                return []
            }
            var displays: [MenuBarRawPhysicalDisplay] = []
            displays.reserveCapacity(Int(actualCount))
            for id in ids.prefix(Int(actualCount)) {
                guard ensureCanContinue() else { return displays }
                let bounds = CGDisplayBounds(id)
                let values = [
                    Double(bounds.origin.x), Double(bounds.origin.y),
                    Double(bounds.width), Double(bounds.height),
                ]
                guard values.allSatisfy(\.isFinite) else {
                    diagnostics.record(.activeDisplayBoundsInvalid)
                    displays.append(.init(id: id, bounds: .failed))
                    continue
                }
                displays.append(.init(
                    id: id,
                    bounds: .value(.init(
                        x: values[0],
                        y: values[1],
                        width: values[2],
                        height: values[3]
                    ))
                ))
            }
            _ = ensureCanContinue()
            return displays
        }

        private mutating func ensureCanContinue() -> Bool {
            if Task.isCancelled {
                recordTerminalReasonOnce(.cancelled)
                return false
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                recordTerminalReasonOnce(.deadlineExceeded)
                return false
            }
            return true
        }

        private mutating func recordTerminalReasonOnce(
            _ reason: MenuBarRawPhysicalStructureFailureReason
        ) {
            guard recordedTerminalReasons.insert(reason).inserted else { return }
            diagnostics.record(reason)
        }
    }

    private enum NodeWorker {
        static func read(
            _ pending: PendingNode,
            deadline: TimeInterval,
            providerPID: Int32
        ) -> WorkerResult {
            var diagnostics = MenuBarRawPhysicalStructureDiagnostics()
            var hitDeadline = false
            guard canContinue(deadline, hitDeadline: &hitDeadline) else {
                return failed(
                    pending,
                    diagnostics: diagnostics,
                    hitDeadline: hitDeadline
                )
            }
            let pid = readPID(
                pending.element.element,
                deadline: deadline,
                diagnostics: &diagnostics,
                hitDeadline: &hitDeadline
            )
            let cutoff = deadline
            if pending.depth > 0, case .value(let ownerPID) = pid, ownerPID != providerPID {
                return WorkerResult(sequence: pending.sequence, id: pending.id, depth: pending.depth,
                    processIdentifier: pid, role: .absent, identifier: .absent,
                    frame: .absent, position: .absent, size: .absent, children: .absent,
                    diagnostics: diagnostics, hitDeadline: hitDeadline,
                    isOpaqueApplicationProxy: true)
            }
            let attributes = MenuBarAXAttributeBatch.read(
                element: pending.element.element,
                attributes: [
                    kAXRoleAttribute,
                    kAXIdentifierAttribute,
                    "AXFrame",
                    kAXPositionAttribute,
                    kAXSizeAttribute,
                    kAXChildrenAttribute,
                ],
                shouldContinue: {
                    ProcessInfo.processInfo.systemUptime < cutoff
                }
            )
            _ = canContinue(deadline, hitDeadline: &hitDeadline)

            let role = readString(
                attributes.raw(kAXRoleAttribute), failed: .roleReadFailed,
                wrongType: .roleWrongType, diagnostics: &diagnostics
            )
            if pending.depth > 0, role == .value(kAXApplicationRole) {
                return WorkerResult(sequence: pending.sequence, id: pending.id, depth: pending.depth,
                    processIdentifier: pid, role: role, identifier: .absent,
                    frame: .absent, position: .absent, size: .absent, children: .absent,
                    diagnostics: diagnostics, hitDeadline: hitDeadline,
                    isOpaqueApplicationProxy: true)
            }

            return WorkerResult(
                sequence: pending.sequence,
                id: pending.id,
                depth: pending.depth,
                processIdentifier: pid,
                role: role,
                identifier: readString(
                    attributes.raw(kAXIdentifierAttribute),
                    failed: .identifierReadFailed,
                    wrongType: .identifierWrongType,
                    diagnostics: &diagnostics
                ),
                frame: readRect(
                    attributes.raw("AXFrame"),
                    diagnostics: &diagnostics
                ),
                position: readPoint(
                    attributes.raw(kAXPositionAttribute),
                    diagnostics: &diagnostics
                ),
                size: readSize(
                    attributes.raw(kAXSizeAttribute),
                    diagnostics: &diagnostics
                ),
                children: readChildren(
                    attributes.raw(kAXChildrenAttribute),
                    deadline: deadline,
                    diagnostics: &diagnostics,
                    hitDeadline: &hitDeadline
                ),
                diagnostics: diagnostics,
                hitDeadline: hitDeadline
            )
        }

        private static func failed(
            _ pending: PendingNode,
            diagnostics: MenuBarRawPhysicalStructureDiagnostics,
            hitDeadline: Bool
        ) -> WorkerResult {
            WorkerResult(
                sequence: pending.sequence,
                id: pending.id,
                depth: pending.depth,
                processIdentifier: .failed,
                role: .failed,
                identifier: .failed,
                frame: .failed,
                position: .failed,
                size: .failed,
                children: .failed,
                diagnostics: diagnostics,
                hitDeadline: hitDeadline
            )
        }

        private static func readPID(
            _ element: AXUIElement,
            deadline: TimeInterval,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics,
            hitDeadline: inout Bool
        ) -> MenuBarRawPhysicalRead<Int32> {
            guard canContinue(deadline, hitDeadline: &hitDeadline) else {
                return .failed
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else {
                diagnostics.record(.nodePIDReadFailed)
                return .failed
            }
            guard pid > 0 else {
                diagnostics.record(.nodePIDInvalid)
                return .failed
            }
            return .value(pid)
        }

        private static func readString(
            _ read: MenuBarAXAttributeRead<CFTypeRef>,
            failed: MenuBarRawPhysicalStructureFailureReason,
            wrongType: MenuBarRawPhysicalStructureFailureReason,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics
        ) -> MenuBarRawPhysicalRead<String> {
            switch read {
            case .absent:
                return .absent
            case .failed:
                diagnostics.record(failed)
                return .failed
            case .value(let raw):
                guard let value = raw as? String else {
                    diagnostics.record(wrongType)
                    return .failed
                }
                return .value(value)
            }
        }

        private static func readRect(
            _ read: MenuBarAXAttributeRead<CFTypeRef>,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics
        ) -> MenuBarRawPhysicalRead<MenuBarRawPhysicalRect> {
            switch read {
            case .absent:
                return .absent
            case .failed:
                diagnostics.record(.frameReadFailed)
                return .failed
            case .value(let raw):
                guard CFGetTypeID(raw) == AXValueGetTypeID() else {
                    diagnostics.record(.frameWrongType)
                    return .failed
                }
                let value = unsafeDowncast(raw, to: AXValue.self)
                var rect = CGRect.zero
                guard AXValueGetType(value) == .cgRect,
                      AXValueGetValue(value, .cgRect, &rect) else {
                    diagnostics.record(.frameWrongType)
                    return .failed
                }
                let numbers = [
                    Double(rect.origin.x), Double(rect.origin.y),
                    Double(rect.width), Double(rect.height),
                ]
                guard numbers.allSatisfy(\.isFinite) else {
                    diagnostics.record(.frameNonFinite)
                    return .failed
                }
                return .value(.init(
                    x: numbers[0],
                    y: numbers[1],
                    width: numbers[2],
                    height: numbers[3]
                ))
            }
        }

        private static func readPoint(
            _ read: MenuBarAXAttributeRead<CFTypeRef>,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics
        ) -> MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint> {
            switch read {
            case .absent:
                return .absent
            case .failed:
                diagnostics.record(.positionReadFailed)
                return .failed
            case .value(let raw):
                guard CFGetTypeID(raw) == AXValueGetTypeID() else {
                    diagnostics.record(.positionWrongType)
                    return .failed
                }
                let value = unsafeDowncast(raw, to: AXValue.self)
                var point = CGPoint.zero
                guard AXValueGetType(value) == .cgPoint,
                      AXValueGetValue(value, .cgPoint, &point) else {
                    diagnostics.record(.positionWrongType)
                    return .failed
                }
                let x = Double(point.x)
                let y = Double(point.y)
                guard x.isFinite, y.isFinite else {
                    diagnostics.record(.positionNonFinite)
                    return .failed
                }
                return .value(.init(x: x, y: y))
            }
        }

        private static func readSize(
            _ read: MenuBarAXAttributeRead<CFTypeRef>,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics
        ) -> MenuBarRawPhysicalRead<MenuBarRawPhysicalSize> {
            switch read {
            case .absent:
                return .absent
            case .failed:
                diagnostics.record(.sizeReadFailed)
                return .failed
            case .value(let raw):
                guard CFGetTypeID(raw) == AXValueGetTypeID() else {
                    diagnostics.record(.sizeWrongType)
                    return .failed
                }
                let value = unsafeDowncast(raw, to: AXValue.self)
                var size = CGSize.zero
                guard AXValueGetType(value) == .cgSize,
                      AXValueGetValue(value, .cgSize, &size) else {
                    diagnostics.record(.sizeWrongType)
                    return .failed
                }
                let width = Double(size.width)
                let height = Double(size.height)
                guard width.isFinite, height.isFinite else {
                    diagnostics.record(.sizeNonFinite)
                    return .failed
                }
                return .value(.init(width: width, height: height))
            }
        }

        private static func readChildren(
            _ read: MenuBarAXAttributeRead<CFTypeRef>,
            deadline: TimeInterval,
            diagnostics: inout MenuBarRawPhysicalStructureDiagnostics,
            hitDeadline: inout Bool
        ) -> WorkerChildren {
            switch read {
            case .absent:
                return .absent
            case .failed:
                diagnostics.record(.childrenReadFailed)
                return .failed
            case .value(let raw):
                guard CFGetTypeID(raw) == CFArrayGetTypeID(),
                      let objects = raw as? [AnyObject] else {
                    diagnostics.record(.childrenWrongType)
                    return .failed
                }
                var children: [ElementHandle] = []
                children.reserveCapacity(objects.count)
                for object in objects {
                    guard canContinue(deadline, hitDeadline: &hitDeadline) else {
                        return .failed
                    }
                    guard CFGetTypeID(object) == AXUIElementGetTypeID() else {
                        diagnostics.record(.childrenWrongType)
                        return .failed
                    }
                    children.append(ElementHandle(
                        unsafeDowncast(object, to: AXUIElement.self)
                    ))
                }
                return .value(children)
            }
        }

        static func prepare(
            _ element: AXUIElement,
            deadline: TimeInterval
        ) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            _ = AXUIElementSetMessagingTimeout(
                element,
                Float(max(0.001, min(0.05, remaining)))
            )
        }

        private static func canContinue(
            _ deadline: TimeInterval,
            hitDeadline: inout Bool
        ) -> Bool {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                hitDeadline = true
                return false
            }
            return true
        }
    }
}
private enum MenuBarRawPhysicalStructureRevision {
    static func make(
        model: MenuBarRawPhysicalStructureModel,
        diagnostics: MenuBarRawPhysicalStructureDiagnostics
    ) -> String {
        var encoder = CanonicalEncoder()
        encoder.appendString("menu-bar-raw-physical-v2-opaque-app-proxies")
        encoder.appendPID(model.providerProcessIdentifier)
        encoder.appendCount(model.displays.count)
        for display in model.displays {
            encoder.appendUInt64(UInt64(display.id))
            encoder.appendRect(display.bounds)
        }
        encoder.appendCount(model.nodes.count)
        for node in model.nodes {
            encoder.appendUInt64(node.isOpaqueApplicationProxy ? 1 : 0)
            encoder.appendPath(node.path)
            encoder.appendPID(node.processIdentifier)
            encoder.appendStringRead(node.role)
            encoder.appendStringRead(node.identifier)
            encoder.appendRect(node.frame)
            encoder.appendPoint(node.position)
            encoder.appendSize(node.size)
            encoder.appendChildren(node.children)
        }
        let reasons = diagnostics.counts
            .filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        encoder.appendCount(reasons.count)
        for reason in reasons {
            encoder.appendString(reason.key.rawValue)
            encoder.appendCount(reason.value)
        }
        let digest = SHA256.hash(data: encoder.data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalEncoder {
        private(set) var data = Data()

        mutating func appendPID(_ read: MenuBarRawPhysicalRead<Int32>) {
            switch read {
            case .value(let value):
                appendByte(1)
                appendUInt64(UInt64(bitPattern: Int64(value)))
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendStringRead(_ read: MenuBarRawPhysicalRead<String>) {
            switch read {
            case .value(let value):
                appendByte(1)
                appendString(value)
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendRect(
            _ read: MenuBarRawPhysicalRead<MenuBarRawPhysicalRect>
        ) {
            switch read {
            case .value(let value):
                appendByte(1)
                appendDouble(value.x)
                appendDouble(value.y)
                appendDouble(value.width)
                appendDouble(value.height)
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendPoint(
            _ read: MenuBarRawPhysicalRead<MenuBarRawPhysicalPoint>
        ) {
            switch read {
            case .value(let value):
                appendByte(1)
                appendDouble(value.x)
                appendDouble(value.y)
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendSize(
            _ read: MenuBarRawPhysicalRead<MenuBarRawPhysicalSize>
        ) {
            switch read {
            case .value(let value):
                appendByte(1)
                appendDouble(value.width)
                appendDouble(value.height)
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendChildren(
            _ read: MenuBarRawPhysicalRead<[MenuBarRawPhysicalChild]>
        ) {
            switch read {
            case .value(let children):
                appendByte(1)
                appendCount(children.count)
                for child in children {
                    switch child {
                    case .node(let path):
                        appendByte(1)
                        appendPath(path)
                    case .reference(let firstPath):
                        appendByte(2)
                        appendPath(firstPath)
                    }
                }
            case .absent:
                appendByte(2)
            case .failed:
                appendByte(3)
            }
        }

        mutating func appendPath(_ path: [Int]) {
            appendCount(path.count)
            for component in path {
                appendUInt64(UInt64(component))
            }
        }

        mutating func appendString(_ value: String) {
            let bytes = Data(value.utf8)
            appendCount(bytes.count)
            data.append(bytes)
        }

        mutating func appendDouble(_ value: Double) {
            appendUInt64(value.bitPattern)
        }

        mutating func appendCount(_ value: Int) {
            appendUInt64(UInt64(value))
        }

        mutating func appendByte(_ value: UInt8) {
            data.append(value)
        }

        mutating func appendUInt64(_ value: UInt64) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
    }
}
