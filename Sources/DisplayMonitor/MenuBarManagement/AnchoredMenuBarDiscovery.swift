import ApplicationServices
import CoreGraphics
import Foundation

enum MenuBarPhysicalGuardDiagnosticReason: String, CaseIterable, Hashable, Sendable {
    case rootChildrenUnavailable
    case rootChildrenMalformed
    case rootChildRoleUnavailable
    case rootChildApplicationProxy
    case rootChildMenuBarProxy
    case rootChildMenuProxy
    case rootChildGroupProxy
    case rootChildButtonProxy
    case rootChildMenuBarItemProxy
    case rootChildMenuExtraProxy
    case rootChildUnknownProxy
    case rootChildUnexpectedRole
    case rootChildFrameUnavailable
    case rootWindowDisplayUnresolved
    case nodeBatchUnavailable
    case roleBulkAbsent
    case roleBulkFailed
    case roleBulkWrongType
    case roleRecoveredBySingleRead
    case roleFallbackAbsent
    case roleFallbackFailed
    case roleFallbackWrongType
    case roleFallbackDeadlineExceeded
    case roleRecoveredContainerSkipped
    case anonymousWrapperRoleDoubleAbsent
    case anonymousWrapperGeometryAllAbsent
    case anonymousWrapperGeometryPresent
    case anonymousWrapperGeometryFailed
    case anonymousWrapperGeometryWrongType
    case anonymousWrapperChildrenNonEmpty
    case anonymousWrapperChildrenEmpty
    case anonymousWrapperChildrenAbsent
    case anonymousWrapperChildrenFailed
    case anonymousWrapperInheritedFrame
    case anonymousWrapperInsideKnownItem
    case anonymousWrapperNonMenuBarAgentSource
    case anonymousWrapperEligibleToRecurse
    case rootMenuBarProviderBundleMismatch
    case rootMenuBarProviderPIDUnavailable
    case rootMenuBarProviderPIDMismatch
    case rootMenuBarFrameUnavailable
    case rootMenuBarInvalidFrame
    case rootMenuBarDisplayUnresolved
    case rootMenuBarOutsideTopBand
    case rootMenuBarChildrenNonEmpty
    case rootMenuBarChildrenEmpty
    case rootMenuBarChildrenAbsent
    case rootMenuBarChildrenFailed
    case rootMenuBarEligibleToTraverse
    case rootMenuBarDuplicateDisplay
    case nodeChildrenUndecodable
    case itemOwnerUnavailable
    case itemFrameUnavailable
    case itemDisplayUnresolved
    case itemPhysicalRootDisplayMismatch
    case unrecognizedLeafApplication
    case unrecognizedLeafWindow
    case unrecognizedLeafGroup
    case unrecognizedLeafButton
    case unrecognizedLeafMenuBarItem
    case unrecognizedLeafMenuExtra
    case unrecognizedLeafMenuBar
    case unrecognizedLeafMenu
    case unrecognizedLeafUnknown
    case unrecognizedLeafOther
}

/// Aggregate-only evidence for a rejected physical guard. The reason keys are
/// deliberately fixed and never include an application's identity, PID,
/// accessibility metadata or geometry.
struct MenuBarPhysicalGuardDiagnostics: Equatable, Sendable {
    private(set) var counts: [MenuBarPhysicalGuardDiagnosticReason: Int] = [:]

    var totalCount: Int { counts.values.reduce(0, +) }

    var summary: String {
        let parts = counts
            .filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    mutating func record(
        _ reason: MenuBarPhysicalGuardDiagnosticReason,
        count: Int = 1
    ) {
        guard count > 0 else { return }
        counts[reason, default: 0] += count
    }
}

struct AnchoredMenuBarDiscoveryResult: Sendable {
    let inventory: AnchoredMenuBarInventory
    /// Items currently hosted by MenuBarAgent's physical menu-bar windows.
    /// An application's AXExtrasMenuBar can retain stale top-edge geometry
    /// while an assessment assertion has already removed its visible item.
    let physicalItems: [MenuBarOrderItem]
    let messages: [String]
    let physicalGuardDiagnostics: MenuBarPhysicalGuardDiagnostics

    init(
        inventory: AnchoredMenuBarInventory,
        physicalItems: [MenuBarOrderItem],
        messages: [String],
        physicalGuardDiagnostics: MenuBarPhysicalGuardDiagnostics = .init()
    ) {
        self.inventory = inventory
        self.physicalItems = physicalItems
        self.messages = messages
        self.physicalGuardDiagnostics = physicalGuardDiagnostics
    }
}

/// Fail-closed read of the complete physical menu-bar inventory.
/// This includes the controller and protected
/// system items because both sides of the fixed divider must be accounted for.
enum AnchoredMenuBarDiscovery {
    private enum ScanMode: Equatable {
        case full
        case physicalGuard
    }

    static func scan(
        applications: [RunningAppSnapshot],
        anchorIdentity: MenuBarAnchorIdentity,
        ownPID: Int32,
        protectionPolicy: MenuBarTargetProtectionPolicy,
        timeBudget: TimeInterval = 4.0
    ) -> AnchoredMenuBarDiscoveryResult {
        var scanner = Scanner(
            applications: applications,
            anchorIdentity: anchorIdentity,
            ownPID: ownPID,
            protectionPolicy: protectionPolicy,
            timeBudget: timeBudget,
            mode: .full
        )
        return scanner.run()
    }

    static func scanPhysicalGuard(
        applications: [RunningAppSnapshot],
        anchorIdentity: MenuBarAnchorIdentity,
        ownPID: Int32,
        protectionPolicy: MenuBarTargetProtectionPolicy,
        timeBudget: TimeInterval = 0.18
    ) -> AnchoredMenuBarDiscoveryResult {
        var scanner = Scanner(
            applications: applications,
            anchorIdentity: anchorIdentity,
            ownPID: ownPID,
            protectionPolicy: protectionPolicy,
            timeBudget: timeBudget,
            mode: .physicalGuard
        )
        return scanner.run()
    }

    static func unexpectedRootChildReason(
        for role: String
    ) -> MenuBarPhysicalGuardDiagnosticReason {
        switch role {
        case kAXApplicationRole: return .rootChildApplicationProxy
        case kAXMenuBarRole: return .rootChildMenuBarProxy
        case kAXMenuRole: return .rootChildMenuProxy
        case kAXGroupRole: return .rootChildGroupProxy
        case kAXButtonRole: return .rootChildButtonProxy
        case kAXMenuBarItemRole: return .rootChildMenuBarItemProxy
        case "AXMenuExtra": return .rootChildMenuExtraProxy
        case "AXUnknown": return .rootChildUnknownProxy
        default: return .rootChildUnexpectedRole
        }
    }

    private struct Scanner {
        private struct Display {
            let id: CGDirectDisplayID
            let bounds: CGRect
        }

        private struct Candidate {
            let item: MenuBarOrderItem
            let source: Int // 0 = application extras, 1 = MenuBarAgent
        }

        private let applications: [RunningAppSnapshot]
        private let owners: [Int32: RunningAppSnapshot]
        private let anchorIdentity: MenuBarAnchorIdentity
        private let ownPID: Int32
        private let protectionPolicy: MenuBarTargetProtectionPolicy
        private let mode: ScanMode
        private let deadline: TimeInterval
        private var phaseDeadline: TimeInterval = .greatestFiniteMagnitude
        private var displays: [Display] = []
        private var candidates: [Candidate] = []
        private var physicallyHitApplicationItemIDs: Set<String> = []
        private var messages: [String] = []
        private var visited: [CFHashCode: [AXUIElement]] = [:]
        /// A physical AXMenuBar root must be traversed under its stricter rules even
        /// if the same element was already reached through a general AXWindow tree.
        private var physicalRootVisited: [CFHashCode: [AXUIElement]] = [:]
        /// Only validated AXMenuBar roots claim this set. AXWindow roots use the
        /// ordinary path and intentionally do not count as duplicate menu-bar roots.
        private var qualifiedPhysicalRootDisplayIDs: Set<UInt32> = []
        private var readableDisplayIDs: Set<UInt32> = []
        private var nodes = 0
        private var unknownOwnershipCount = 0
        private var unexplainedSkippedItemCount = 0
        private var skippedItemDetails: [String] = []
        private var physicalGuardDiagnostics = MenuBarPhysicalGuardDiagnostics()
        private var excludedOffBarItemCount = 0
        private var excludedOffBarItemDetails: [String] = []
        private var menuBarAgentWindowDetails: [String] = []
        private var hitLimit = false
        private let nodeLimit = 1_800

        init(
            applications: [RunningAppSnapshot],
            anchorIdentity: MenuBarAnchorIdentity,
            ownPID: Int32,
            protectionPolicy: MenuBarTargetProtectionPolicy,
            timeBudget: TimeInterval,
            mode: ScanMode
        ) {
            self.applications = applications
            self.anchorIdentity = anchorIdentity
            self.ownPID = ownPID
            self.protectionPolicy = protectionPolicy
            self.mode = mode
            deadline = ProcessInfo.processInfo.systemUptime + max(0, timeBudget)
            owners = Dictionary(applications.filter {
                $0.processIdentifier > 0 && !$0.bundleIdentifier.isEmpty
            }.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        }

        private var hasTime: Bool {
            !Task.isCancelled
                && ProcessInfo.processInfo.systemUptime < min(deadline, phaseDeadline)
        }

        mutating func run() -> AnchoredMenuBarDiscoveryResult {
            loadDisplays()
            guard configurationIsSafe else {
                return failClosedResult(
                    message: "菜单栏分界身份或保护策略无效；已保持展开。"
                )
            }
            if sessionIsLocked {
                return failClosedResult(
                    message: "系统当前处于锁屏状态；已保持展开，解锁后会自动重新读取菜单栏。"
                )
            }
            guard AXIsProcessTrusted(), !displays.isEmpty else {
                let reason = displays.isEmpty
                    ? "无法读取显示器范围，已保持展开。"
                    : "没有辅助功能读取权限，已保持展开。"
                return failClosedResult(message: reason)
            }

            // Read every application's explicit status-item bar first. This is
            // the only reliable place where the provider PID is already known.
            if mode == .full {
                phaseDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 2.0)
                for app in applications where hasTime && nodes < nodeLimit {
                    guard app.processIdentifier > 0, !app.bundleIdentifier.isEmpty else { continue }
                    let root = AXUIElementCreateApplication(app.processIdentifier)
                    configureTimeout(root)
                    guard let extras = element(root, kAXExtrasMenuBarAttribute) else { continue }
                    walk(
                        extras,
                        depth: 0,
                        structuralPath: [],
                        extrasOwner: app,
                        groupFrame: nil,
                        source: 0,
                        insideKnownItem: false
                    )
                }
            }

            // MenuBarAgent is also required: it exposes the containing windows,
            // including protected items and display coverage that app scans miss.
            phaseDeadline = deadline
            for app in applications where hasTime && nodes < nodeLimit {
                guard app.bundleIdentifier == "com.apple.MenuBarAgent" else { continue }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                configureTimeout(root, maximum: 0.25)
                // On macOS 27 MenuBarAgent's canonical tree is exposed by
                // AXChildren (AXApplication → AXWindow → item groups). After
                // a visibility restriction cycle AXWindows may instead return
                // AXApplication proxy nodes with no children or geometry.
                var windows: [AXUIElement] = []
                var lastChildrenError: AXError = .success
                for attempt in 0..<3 where hasTime {
                    let (childrenError, rawChildren) = MenuBarAXAttributeBatch.copyAttributeValue(
                        element: root, attribute: kAXChildrenAttribute)
                    lastChildrenError = childrenError
                    if let rawChildren,
                       CFGetTypeID(rawChildren) == CFArrayGetTypeID(),
                       let objects = rawChildren as? [AnyObject] {
                        windows = objects.compactMap { object in
                            guard CFGetTypeID(object) == AXUIElementGetTypeID() else {
                                markStrictPhysicalTreeIncomplete(
                                    .rootChildrenMalformed,
                                    detail: "MenuBarAgent AXChildren 含非 AXUIElement 项。"
                                )
                                return nil
                            }
                            return unsafeDowncast(object, to: AXUIElement.self)
                        }
                    }
                    if !windows.isEmpty { break }
                    guard attempt < 2 else { continue }
                    let remaining = min(deadline, phaseDeadline) - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 { Thread.sleep(forTimeInterval: min(0.15, remaining)) }
                }
                if windows.isEmpty {
                    markStrictPhysicalTreeIncomplete(
                        .rootChildrenUnavailable,
                        detail: "MenuBarAgent 没有返回可读取的根子节点。"
                    )
                    menuBarAgentWindowDetails.append(
                        "MenuBarAgent PID \(app.processIdentifier) 连续 3 次没有返回 AXChildren 菜单栏窗口；"
                            + "AXError=\(lastChildrenError.rawValue)。"
                    )
                }
                for window in windows where hasTime {
                    configureTimeout(window, maximum: 0.25)
                    guard let role = string(window, kAXRoleAttribute) else {
                        if menuBarAgentWindowDetails.count < 12 {
                            menuBarAgentWindowDetails.append(
                                "MenuBarAgent 子节点缺少有效窗口 role。"
                            )
                        }
                        markStrictPhysicalTreeIncomplete(
                            .rootChildRoleUnavailable,
                            detail: "MenuBarAgent 根节点存在 role 不可读的代理。"
                        )
                        continue
                    }
                    guard role == kAXWindowRole else {
                        if menuBarAgentWindowDetails.count < 12 {
                            menuBarAgentWindowDetails.append(
                                "MenuBarAgent 子节点不是窗口：role=\(role)。"
                            )
                        }
                        if role == kAXMenuBarRole {
                            if traversePhysicalMenuBarRootIfValid(window, provider: app) {
                                physicalGuardDiagnostics.record(.rootChildMenuBarProxy)
                                continue
                            }
                        }
                        markStrictPhysicalTreeIncomplete(
                            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: role),
                            detail: role == kAXMenuBarRole
                                ? "MenuBarAgent 的物理 AXMenuBar 根无法完整验证。"
                                : "MenuBarAgent 根节点存在非窗口代理。"
                        )
                        continue
                    }
                    guard let windowFrame = frame(window) else {
                        if menuBarAgentWindowDetails.count < 12 {
                            menuBarAgentWindowDetails.append(
                                "MenuBarAgent 窗口子节点缺少有效 frame。"
                            )
                        }
                        markStrictPhysicalTreeIncomplete(
                            .rootChildFrameUnavailable,
                            detail: "MenuBarAgent 窗口代理缺少有效 frame。"
                        )
                        continue
                    }
                    guard let windowDisplay = display(containing: windowFrame),
                          abs(windowFrame.minY - windowDisplay.bounds.minY) <= 1,
                          windowFrame.height <= 80,
                          windowFrame.width >= windowDisplay.bounds.width / 2 else {
                        if menuBarAgentWindowDetails.count < 12 {
                            menuBarAgentWindowDetails.append(
                                String(
                                    format: "未采用 MenuBarAgent 窗口：frame=(%.1f, %.1f, %.1f, %.1f)。",
                                    windowFrame.origin.x,
                                    windowFrame.origin.y,
                                    windowFrame.width,
                                    windowFrame.height
                                )
                            )
                        }
                        markStrictPhysicalTreeIncomplete(
                            .rootWindowDisplayUnresolved,
                            detail: "MenuBarAgent 根节点存在无法归属显示器的窗口。"
                        )
                        continue
                    }
                    readableDisplayIDs.insert(UInt32(windowDisplay.id))
                    walk(
                        window,
                        depth: 0,
                        structuralPath: [],
                        extrasOwner: nil,
                        groupFrame: nil,
                        source: 1,
                        insideKnownItem: false
                    )
                }
            }

            let merged = mergePhysicalDuplicates(candidates)
            // An application's AXExtrasMenuBar may keep reporting its old frame
            // after assessment mode has removed the visible status item. Treat
            // that application item as physically present only when a system-wide
            // hit test at its current frame still resolves to the owning PID.
            // MenuBarAgent candidates are already read from its live window tree
            // and remain the source for system-owned items.
            let physicalCandidates = candidates.filter {
                $0.source == 1 || physicallyHitApplicationItemIDs.contains($0.item.id)
            }
            let physicalItems = mergePhysicalDuplicates(physicalCandidates)
                .map(\.item)
                .sorted(by: itemOrder)
            let grouped = Dictionary(grouping: merged, by: { $0.item.id })
            let ambiguousIdentityCount = grouped.values
                .filter { $0.count > 1 }
                .reduce(0) { $0 + $1.count }
            let items = grouped.values.compactMap { group in
                group.count == 1 ? group[0].item : nil
            }.sorted(by: itemOrder)

            let allDisplayIDs = displays.map { UInt32($0.id) }.sorted()
            // macOS exposes empty MenuBarAgent windows on secondary displays,
            // while the physical status items live only on the currently
            // populated menu bar. Empty readable windows are not layouts and
            // therefore do not need their own copy of the single NSStatusItem.
            // If a second display contains any physical item it remains in the
            // set and validation still requires an anchor there.
            let expectedDisplayIDs = Array(Set(items.map(\.displayID))).sorted()
            let unreadableDisplayIDs = allDisplayIDs.filter { !readableDisplayIDs.contains($0) }
            let emptyReadableDisplayIDs = allDisplayIDs.filter {
                readableDisplayIDs.contains($0) && !expectedDisplayIDs.contains($0)
            }
            let observedCandidateCount = items.count + ambiguousIdentityCount
                + unknownOwnershipCount + unexplainedSkippedItemCount
            let scanEndedEarly = !hasTime || hitLimit
            let coverage = MenuBarInventoryCoverage(
                expectedDisplayIDs: expectedDisplayIDs,
                observedCandidateCount: observedCandidateCount,
                resolvedItemCount: items.count,
                unknownOwnershipCount: unknownOwnershipCount,
                ambiguousIdentityCount: ambiguousIdentityCount,
                unexplainedSkippedItemCount: unexplainedSkippedItemCount,
                unreadableDisplayIDs: unreadableDisplayIDs,
                didTimeOut: scanEndedEarly
            )

            if !unreadableDisplayIDs.isEmpty {
                messages.append("显示器 \(unreadableDisplayIDs.map(String.init).joined(separator: "、")) 没有读到完整菜单栏窗口。")
                messages.append(contentsOf: menuBarAgentWindowDetails)
            }
            if !emptyReadableDisplayIDs.isEmpty {
                messages.append("显示器 \(emptyReadableDisplayIDs.map(String.init).joined(separator: "、")) 的菜单栏窗口当前没有物理状态项，不参与本次布局。")
            }
            if unknownOwnershipCount > 0 {
                messages.append("有 \(unknownOwnershipCount) 个物理项目无法确认所属应用。")
            }
            if ambiguousIdentityCount > 0 {
                messages.append("有 \(ambiguousIdentityCount) 个项目身份重复，不能安全排序或收起。")
            }
            if unexplainedSkippedItemCount > 0 {
                messages.append("有 \(unexplainedSkippedItemCount) 个项目缺少坐标或显示器归属。")
                messages.append(contentsOf: skippedItemDetails)
            }
            if excludedOffBarItemCount > 0 {
                messages.append("已排除 \(excludedOffBarItemCount) 个位于菜单栏区域之外的隐藏状态项。")
                messages.append(contentsOf: excludedOffBarItemDetails)
            }
            if scanEndedEarly { messages.append("扫描达到时间或节点上限，清单不完整。") }
            if coverage.isComplete {
                messages.append("菜单栏清单完整：\(items.count) 个项目，\(expectedDisplayIDs.count) 块显示器。")
            } else {
                messages.append("菜单栏清单不完整；收起与排序保持禁用。")
            }
            return AnchoredMenuBarDiscoveryResult(
                inventory: AnchoredMenuBarInventory(items: items, coverage: coverage, anchorIdentity: anchorIdentity),
                physicalItems: physicalItems,
                messages: messages,
                physicalGuardDiagnostics: physicalGuardDiagnostics
            )
        }

        private mutating func loadDisplays() {
            var ids = [CGDirectDisplayID](repeating: 0, count: 64)
            var count: UInt32 = 0
            let error = ids.withUnsafeMutableBufferPointer { buffer in
                CGGetActiveDisplayList(UInt32(buffer.count), buffer.baseAddress, &count)
            }
            guard error == .success else { return }
            displays = ids.prefix(Int(count)).map { Display(id: $0, bounds: CGDisplayBounds($0)) }
        }

        private var configurationIsSafe: Bool {
            guard ownPID > 0,
                  !anchorIdentity.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !anchorIdentity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  protectionPolicy.ownBundleIdentifier == anchorIdentity.bundleIdentifier,
                  protectionPolicy.reason(
                    bundleIdentifier: anchorIdentity.bundleIdentifier,
                    applicationName: nil
                  ) != nil else { return false }
            return applications.contains {
                $0.processIdentifier == ownPID
                    && $0.bundleIdentifier == anchorIdentity.bundleIdentifier
            }
        }

        private func failClosedResult(message: String) -> AnchoredMenuBarDiscoveryResult {
            let displayIDs = displays.map { UInt32($0.id) }.sorted()
            let coverage = MenuBarInventoryCoverage(
                expectedDisplayIDs: displayIDs,
                observedCandidateCount: 0,
                resolvedItemCount: 0,
                unreadableDisplayIDs: displayIDs,
                didTimeOut: false
            )
            return AnchoredMenuBarDiscoveryResult(
                inventory: AnchoredMenuBarInventory(
                    items: [],
                    coverage: coverage,
                    anchorIdentity: anchorIdentity
                ),
                physicalItems: [],
                messages: [message]
            )
        }

        private var sessionIsLocked: Bool {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
            return (session["CGSSessionScreenIsLocked"] as? Bool) == true
                || (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
        }

        private mutating func walk(
            _ node: AXUIElement,
            depth: Int,
            structuralPath: [Int],
            extrasOwner: RunningAppSnapshot?,
            groupFrame: CGRect?,
            source: Int,
            insideKnownItem: Bool,
            expectedPhysicalRootDisplayID: UInt32? = nil
        ) {
            guard hasTime else { return }
            guard depth <= 18, nodes < nodeLimit else { hitLimit = true; return }
            let hash = CFHash(node)
            if expectedPhysicalRootDisplayID != nil {
                guard !(physicalRootVisited[hash] ?? []).contains(where: { CFEqual($0, node) }) else {
                    return
                }
                physicalRootVisited[hash, default: []].append(node)
            } else {
                guard !(visited[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
                visited[hash, default: []].append(node)
            }
            nodes += 1
            configureTimeout(node, maximum: source == 1 ? 0.25 : 0.05)
            // One IPC obtains the structural/geometry fields for this node.
            // Values and per-attribute errors retain their original slots.
            var requestedAttributes = [
                kAXRoleAttribute, "AXFrame", kAXPositionAttribute,
                kAXSizeAttribute, kAXChildrenAttribute,
            ]
            let requiresStrictPhysicalStructure = mode == .physicalGuard
                || expectedPhysicalRootDisplayID != nil
            if requiresStrictPhysicalStructure {
                requestedAttributes.append(kAXIdentifierAttribute)
            }
            let attributes = MenuBarAXAttributeBatch.read(
                element: node,
                attributes: requestedAttributes,
                shouldContinue: { hasTime }
            )
            let role: String
            var roleRecoveredBySingleRead = false
            if requiresStrictPhysicalStructure {
                switch attributes.mandatoryString(
                    element: node,
                    attribute: kAXRoleAttribute,
                    shouldContinue: { hasTime },
                    beforeFallback: {
                        configureTimeout(node, maximum: source == 1 ? 0.25 : 0.05)
                    }
                ) {
                case .batch(let value):
                    role = value
                case .fallback(let value, let bulkFailure):
                    recordRoleBulkFailure(bulkFailure)
                    physicalGuardDiagnostics.record(.roleRecoveredBySingleRead)
                    role = value
                    roleRecoveredBySingleRead = true
                case .failed(let bulkFailure, let fallbackFailure):
                    recordRoleBulkFailure(bulkFailure)
                    if structuralBatchFailed(attributes) {
                        physicalGuardDiagnostics.record(.nodeBatchUnavailable)
                    }
                    if bulkFailure == .absent, fallbackFailure == .absent {
                        let childrenRead = attributes.elements(kAXChildrenAttribute)
                        let decodedChildren: [AXUIElement]?
                        let childrenShape: MenuBarContainerChildrenShape
                        switch childrenRead {
                        case .value(let children):
                            decodedChildren = children
                            childrenShape = children.isEmpty ? .empty : .nonEmpty
                        case .absent:
                            decodedChildren = nil
                            childrenShape = .absent
                        case .failed:
                            decodedChildren = nil
                            childrenShape = .failed
                        }
                        let evaluation = MenuBarTransparentContainerPolicy.evaluate(
                            bulkRoleFailure: bulkFailure,
                            fallbackRoleFailure: fallbackFailure,
                            geometry: containerGeometryShapes(attributes),
                            children: childrenShape,
                            hasInheritedFrame: groupFrame != nil,
                            insideKnownItem: insideKnownItem,
                            isMenuBarAgentSource: source == 1
                        )
                        recordAnonymousWrapperEvidence(evaluation.evidence)
                        if evaluation.isEligibleToRecurse, let decodedChildren {
                            physicalGuardDiagnostics.record(.roleFallbackAbsent)
                            for (index, child) in decodedChildren.enumerated()
                            where hasTime && nodes < nodeLimit {
                                walk(
                                    child,
                                    depth: depth + 1,
                                    structuralPath: structuralPath + [index],
                                    extrasOwner: nil,
                                    groupFrame: nil,
                                    source: source,
                                    insideKnownItem: false,
                                    expectedPhysicalRootDisplayID: expectedPhysicalRootDisplayID
                                )
                            }
                            if nodes >= nodeLimit { hitLimit = true }
                            return
                        }
                    }
                    markStrictPhysicalTreeIncomplete(
                        roleFallbackReason(for: fallbackFailure),
                        detail: "MenuBarAgent 节点的 role 批量槽不可用，单属性重读也未成功。"
                    )
                    return
                }
            } else {
                guard let value = attributes.optionalValue(kAXRoleAttribute) as? String else {
                    return
                }
                role = value
            }
            let isPhysicalRootItemRole = expectedPhysicalRootDisplayID != nil
                && (role == kAXButtonRole || role == kAXMenuBarItemRole || role == "AXMenuExtra")
            if expectedPhysicalRootDisplayID != nil,
               role != kAXGroupRole,
               !isPhysicalRootItemRole {
                markStrictPhysicalTreeIncomplete(
                    unrecognizedLeafReason(for: role),
                    detail: "MenuBarAgent 物理 AXMenuBar 根包含未允许的节点 role。"
                )
                return
            }
            if role == kAXMenuRole || (extrasOwner == nil && role == kAXMenuBarRole) {
                if requiresStrictPhysicalStructure, roleRecoveredBySingleRead {
                    markStrictPhysicalTreeIncomplete(
                        .roleRecoveredContainerSkipped,
                        detail: "MenuBarAgent 节点经单属性重读得到容器 role，现有遍历不能证明其子树可安全忽略。"
                    )
                }
                return
            }

            let ownFrame = frame(attributes)
            let nearestGroupFrame = role == kAXGroupRole ? (ownFrame ?? groupFrame) : groupFrame
            let isExtrasItem = extrasOwner != nil && (role == kAXMenuBarItemRole || role == "AXMenuExtra")
            let isAgentItem = extrasOwner == nil
                && (role == kAXButtonRole || isPhysicalRootItemRole)
                && (expectedPhysicalRootDisplayID != nil
                    ? ownFrame != nil
                    : (groupFrame != nil || (requiresStrictPhysicalStructure && ownFrame != nil)))
            if isExtrasItem || isAgentItem {
                let identifier: String?
                let title: String?
                let description: String?
                if mode == .physicalGuard {
                    identifier = clean(attributes.optionalValue(kAXIdentifierAttribute) as? String)
                    title = nil
                    description = nil
                } else {
                    let metadata = MenuBarAXAttributeBatch.read(
                        element: node,
                        attributes: [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute],
                        shouldContinue: { hasTime }
                    )
                    identifier = clean(metadata.optionalValue(kAXIdentifierAttribute) as? String)
                    title = clean(metadata.optionalValue(kAXTitleAttribute) as? String)
                    description = clean(metadata.optionalValue(kAXDescriptionAttribute) as? String)
                }
                let owner = owner(of: node, extrasOwner: extrasOwner)
                let itemFrame = expectedPhysicalRootDisplayID != nil ? ownFrame : (ownFrame ?? nearestGroupFrame)
                let itemDisplay = itemFrame.flatMap { display(containing: $0) }
                if let expectedPhysicalRootDisplayID,
                   !MenuBarPhysicalRootDisplayPolicy.itemBelongsToRoot(
                       expectedDisplayID: expectedPhysicalRootDisplayID,
                       actualDisplayID: itemDisplay.map { UInt32($0.id) }
                   ) {
                    markStrictPhysicalTreeIncomplete(
                        .itemPhysicalRootDisplayMismatch,
                        detail: "MenuBarAgent 物理 AXMenuBar 根的后代项目无法归属根显示器或跨越到另一块显示器。"
                    )
                } else if let owner, let itemFrame, let display = itemDisplay {
                    let label = title ?? description ?? identifier ?? owner.name
                    let stable = MenuBarStatusItemIdentity.stableComponent(
                        identifier: identifier,
                        structuralPath: structuralPath
                    )
                    let id = MenuBarStatusItemIdentity.orderItemID(
                        displayID: UInt32(display.id),
                        processIdentifier: owner.processIdentifier,
                        bundleIdentifier: owner.bundleIdentifier,
                        stableComponent: stable
                    )
                    let item = MenuBarOrderItem(
                            id: id,
                            bundleIdentifier: owner.bundleIdentifier,
                            applicationName: owner.name,
                            title: label,
                            accessibilityIdentifier: identifier,
                            processIdentifier: owner.processIdentifier,
                            displayID: UInt32(display.id),
                            frame: itemFrame
                        )
                    candidates.append(Candidate(
                        item: item,
                        source: source
                    ))
                    if source == 0, hitTestOwnerPID(at: itemFrame) == owner.processIdentifier {
                        physicallyHitApplicationItemIDs.insert(item.id)
                    }
                } else if let owner, let itemFrame, !overlapsAnyMenuBarBand(itemFrame) {
                    excludedOffBarItemCount += 1
                    let label = title ?? description ?? identifier ?? owner.name
                    excludedOffBarItemDetails.append(
                        String(
                            format: "已排除离屏项：%@ [%@] %@，frame=(%.1f, %.1f, %.1f, %.1f)。",
                            owner.name,
                            owner.bundleIdentifier,
                            label,
                            itemFrame.origin.x,
                            itemFrame.origin.y,
                            itemFrame.width,
                            itemFrame.height
                        )
                    )
                } else if owner == nil {
                    unknownOwnershipCount += 1
                    if mode == .physicalGuard {
                        physicalGuardDiagnostics.record(.itemOwnerUnavailable)
                    }
                } else {
                    if mode == .physicalGuard {
                        markPhysicalGuardIncomplete(
                            itemFrame == nil ? .itemFrameUnavailable : .itemDisplayUnresolved,
                            detail: itemFrame == nil
                                ? "MenuBarAgent 项缺少有效 frame。"
                                : "MenuBarAgent 项无法唯一归属显示器。"
                        )
                    } else {
                        let owner = owner!
                        unexplainedSkippedItemCount += 1
                        let identifier = identifier ?? "<无 identifier>"
                        let title = title ?? "<无 title>"
                        let description = description ?? "<无 description>"
                        let geometry: String
                        if let itemFrame {
                            geometry = String(
                                format: "frame=(%.1f, %.1f, %.1f, %.1f)，未匹配到唯一显示器",
                                itemFrame.origin.x,
                                itemFrame.origin.y,
                                itemFrame.width,
                                itemFrame.height
                            )
                        } else {
                            geometry = "节点和最近分组都没有有效 frame"
                        }
                        skippedItemDetails.append(
                            "跳过详情：source=\(source)，owner=\(owner.name) [\(owner.bundleIdentifier)]，"
                                + "role=\(role)，identifier=\(identifier)，title=\(title)，"
                                + "description=\(description)，\(geometry)。"
                        )
                    }
                }
            }

            let children: [AXUIElement]
            if requiresStrictPhysicalStructure {
                switch attributes.elements(kAXChildrenAttribute) {
                case .value(let value):
                    children = value
                case .absent:
                    children = []
                case .failed:
                    markStrictPhysicalTreeIncomplete(
                        .nodeChildrenUndecodable,
                        detail: "MenuBarAgent 节点的 AXChildren 无法完整解码。"
                    )
                    children = []
                }
            } else {
                children = elements(attributes.optionalValue(kAXChildrenAttribute))
            }
            if requiresStrictPhysicalStructure,
               extrasOwner == nil,
               !insideKnownItem,
               !isAgentItem,
               children.isEmpty,
               (nearestGroupFrame != nil || ownFrame != nil || role == kAXApplicationRole) {
                markStrictPhysicalTreeIncomplete(
                    unrecognizedLeafReason(for: role),
                    detail: "MenuBarAgent 菜单栏分组含无法识别的物理叶节点。"
                )
            }

            for (index, child) in children.enumerated()
            where hasTime && nodes < nodeLimit {
                walk(
                    child,
                    depth: depth + 1,
                    structuralPath: structuralPath + [index],
                    extrasOwner: extrasOwner,
                    groupFrame: nearestGroupFrame,
                    source: source,
                    insideKnownItem: insideKnownItem || isAgentItem,
                    expectedPhysicalRootDisplayID: expectedPhysicalRootDisplayID
                )
            }
            if nodes >= nodeLimit { hitLimit = true }
        }

        private mutating func markPhysicalGuardIncomplete(
            _ reason: MenuBarPhysicalGuardDiagnosticReason,
            detail: String
        ) {
            unexplainedSkippedItemCount += 1
            physicalGuardDiagnostics.record(reason)
            if skippedItemDetails.count < 12 {
                skippedItemDetails.append(detail)
            }
        }

        private mutating func markFullScanIncomplete(detail: String) {
            unexplainedSkippedItemCount += 1
            if skippedItemDetails.count < 12 {
                skippedItemDetails.append(detail)
            }
        }

        private mutating func markStrictPhysicalTreeIncomplete(
            _ reason: MenuBarPhysicalGuardDiagnosticReason,
            detail: String
        ) {
            if mode == .physicalGuard {
                markPhysicalGuardIncomplete(reason, detail: detail)
            } else {
                physicalGuardDiagnostics.record(reason)
                markFullScanIncomplete(detail: detail)
            }
        }

        private func unrecognizedLeafReason(
            for role: String
        ) -> MenuBarPhysicalGuardDiagnosticReason {
            switch role {
            case kAXApplicationRole: return .unrecognizedLeafApplication
            case kAXWindowRole: return .unrecognizedLeafWindow
            case kAXGroupRole: return .unrecognizedLeafGroup
            case kAXButtonRole: return .unrecognizedLeafButton
            case kAXMenuBarItemRole: return .unrecognizedLeafMenuBarItem
            case "AXMenuExtra": return .unrecognizedLeafMenuExtra
            case kAXMenuBarRole: return .unrecognizedLeafMenuBar
            case kAXMenuRole: return .unrecognizedLeafMenu
            case "AXUnknown": return .unrecognizedLeafUnknown
            default: return .unrecognizedLeafOther
            }
        }

        private mutating func recordRoleBulkFailure(
            _ failure: MenuBarAXMandatoryStringFailure
        ) {
            switch failure {
            case .absent:
                physicalGuardDiagnostics.record(.roleBulkAbsent)
            case .failed, .deadlineExceeded:
                physicalGuardDiagnostics.record(.roleBulkFailed)
            case .wrongType:
                physicalGuardDiagnostics.record(.roleBulkWrongType)
            }
        }

        private func roleFallbackReason(
            for failure: MenuBarAXMandatoryStringFailure
        ) -> MenuBarPhysicalGuardDiagnosticReason {
            switch failure {
            case .absent: return .roleFallbackAbsent
            case .failed: return .roleFallbackFailed
            case .wrongType: return .roleFallbackWrongType
            case .deadlineExceeded: return .roleFallbackDeadlineExceeded
            }
        }

        private func containerGeometryShapes(
            _ attributes: MenuBarAXAttributeBatch
        ) -> [MenuBarContainerGeometrySlotShape] {
            [
                attributes.geometrySlotShape("AXFrame", expectedType: .cgRect),
                attributes.geometrySlotShape(kAXPositionAttribute, expectedType: .cgPoint),
                attributes.geometrySlotShape(kAXSizeAttribute, expectedType: .cgSize),
            ]
        }

        private mutating func recordAnonymousWrapperEvidence(
            _ evidence: Set<MenuBarTransparentContainerEvidence>
        ) {
            for item in evidence {
                switch item {
                case .roleDoubleAbsent:
                    physicalGuardDiagnostics.record(.anonymousWrapperRoleDoubleAbsent)
                case .roleNotDoubleAbsent:
                    break
                case .geometryAllAbsent:
                    physicalGuardDiagnostics.record(.anonymousWrapperGeometryAllAbsent)
                case .geometryPresent:
                    physicalGuardDiagnostics.record(.anonymousWrapperGeometryPresent)
                case .geometryFailed:
                    physicalGuardDiagnostics.record(.anonymousWrapperGeometryFailed)
                case .geometryWrongType:
                    physicalGuardDiagnostics.record(.anonymousWrapperGeometryWrongType)
                case .childrenNonEmpty:
                    physicalGuardDiagnostics.record(.anonymousWrapperChildrenNonEmpty)
                case .childrenEmpty:
                    physicalGuardDiagnostics.record(.anonymousWrapperChildrenEmpty)
                case .childrenAbsent:
                    physicalGuardDiagnostics.record(.anonymousWrapperChildrenAbsent)
                case .childrenFailed:
                    physicalGuardDiagnostics.record(.anonymousWrapperChildrenFailed)
                case .inheritedFrame:
                    physicalGuardDiagnostics.record(.anonymousWrapperInheritedFrame)
                case .insideKnownItem:
                    physicalGuardDiagnostics.record(.anonymousWrapperInsideKnownItem)
                case .nonMenuBarAgentSource:
                    physicalGuardDiagnostics.record(.anonymousWrapperNonMenuBarAgentSource)
                case .eligibleToRecurse:
                    physicalGuardDiagnostics.record(.anonymousWrapperEligibleToRecurse)
                }
            }
        }

        private mutating func traversePhysicalMenuBarRootIfValid(
            _ element: AXUIElement,
            provider: RunningAppSnapshot
        ) -> Bool {
            configureTimeout(element, maximum: 0.25)
            let rootFrame = frame(element)
            let childrenRead = MenuBarAXAttributeBatch.freshElements(
                element: element,
                attribute: kAXChildrenAttribute,
                shouldContinue: { hasTime },
                beforeRead: { configureTimeout(element, maximum: 0.25) }
            )
            let childrenShape: MenuBarContainerChildrenShape
            let decodedChildren: [AXUIElement]?
            switch childrenRead {
            case .value(let children):
                decodedChildren = children
                childrenShape = children.isEmpty ? .empty : .nonEmpty
            case .absent:
                decodedChildren = nil
                childrenShape = .absent
            case .failed:
                decodedChildren = nil
                childrenShape = .failed
            }
            var actualProviderPID: pid_t = 0
            let resolvedProviderPID: Int32? = AXUIElementGetPid(element, &actualProviderPID) == .success
                && actualProviderPID > 0 ? actualProviderPID : nil
            let evaluation = MenuBarPhysicalMenuBarRootPolicy.evaluate(
                providerBundleIdentifier: provider.bundleIdentifier,
                expectedProviderPID: provider.processIdentifier,
                actualProviderPID: resolvedProviderPID,
                frame: rootFrame,
                displayBounds: displays.map(\.bounds),
                children: childrenShape
            )
            recordPhysicalMenuBarRootEvidence(evaluation.evidence)
            guard evaluation.isEligibleToTraverse,
                  let displayIndex = evaluation.displayIndex,
                  displays.indices.contains(displayIndex),
                  let decodedChildren,
                  !decodedChildren.isEmpty,
                  hasTime else { return false }

            let rootDisplayID = UInt32(displays[displayIndex].id)
            guard MenuBarPhysicalRootDisplayPolicy.rootDisplayIsUnique(
                displayID: rootDisplayID,
                qualifiedRootDisplayIDs: qualifiedPhysicalRootDisplayIDs
            ) else {
                markStrictPhysicalTreeIncomplete(
                    .rootMenuBarDuplicateDisplay,
                    detail: "同一显示器出现多个合格的物理 AXMenuBar 根。"
                )
                return true
            }
            qualifiedPhysicalRootDisplayIDs.insert(rootDisplayID)

            let hash = CFHash(element)
            if (physicalRootVisited[hash] ?? []).contains(where: { CFEqual($0, element) }) {
                return true
            }
            guard nodes < nodeLimit else {
                hitLimit = true
                return false
            }
            physicalRootVisited[hash, default: []].append(element)
            nodes += 1
            readableDisplayIDs.insert(rootDisplayID)
            for (index, child) in decodedChildren.enumerated()
            where hasTime && nodes < nodeLimit {
                walk(
                    child,
                    depth: 1,
                    structuralPath: [index],
                    extrasOwner: nil,
                    groupFrame: nil,
                    source: 1,
                    insideKnownItem: false,
                    expectedPhysicalRootDisplayID: rootDisplayID
                )
            }
            if nodes >= nodeLimit { hitLimit = true }
            return true
        }

        private mutating func recordPhysicalMenuBarRootEvidence(
            _ evidence: Set<MenuBarPhysicalMenuBarRootEvidence>
        ) {
            for item in evidence {
                switch item {
                case .providerBundleMismatch:
                    physicalGuardDiagnostics.record(.rootMenuBarProviderBundleMismatch)
                case .providerPIDUnavailable:
                    physicalGuardDiagnostics.record(.rootMenuBarProviderPIDUnavailable)
                case .providerPIDMismatch:
                    physicalGuardDiagnostics.record(.rootMenuBarProviderPIDMismatch)
                case .frameUnavailable:
                    physicalGuardDiagnostics.record(.rootMenuBarFrameUnavailable)
                case .invalidFrame:
                    physicalGuardDiagnostics.record(.rootMenuBarInvalidFrame)
                case .displayUnresolved:
                    physicalGuardDiagnostics.record(.rootMenuBarDisplayUnresolved)
                case .outsideTopBand:
                    physicalGuardDiagnostics.record(.rootMenuBarOutsideTopBand)
                case .childrenNonEmpty:
                    physicalGuardDiagnostics.record(.rootMenuBarChildrenNonEmpty)
                case .childrenEmpty:
                    physicalGuardDiagnostics.record(.rootMenuBarChildrenEmpty)
                case .childrenAbsent:
                    physicalGuardDiagnostics.record(.rootMenuBarChildrenAbsent)
                case .childrenFailed:
                    physicalGuardDiagnostics.record(.rootMenuBarChildrenFailed)
                case .eligibleToTraverse:
                    physicalGuardDiagnostics.record(.rootMenuBarEligibleToTraverse)
                }
            }
        }

        private func structuralBatchFailed(
            _ attributes: MenuBarAXAttributeBatch
        ) -> Bool {
            [
                kAXRoleAttribute, "AXFrame", kAXPositionAttribute,
                kAXSizeAttribute, kAXChildrenAttribute,
            ].allSatisfy { attribute in
                if case .failed = attributes.raw(attribute) { return true }
                return false
            }
        }

        private func owner(of node: AXUIElement, extrasOwner: RunningAppSnapshot?) -> RunningAppSnapshot? {
            if let extrasOwner { return extrasOwner }
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success else { return nil }
            return owners[pid]
        }

        private func hitTestOwnerPID(at frame: CGRect) -> Int32? {
            let point = CGPoint(x: frame.midX, y: frame.midY)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(),
                Float(point.x),
                Float(point.y),
                &hit
            ) == .success, let hit else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid > 0 else { return nil }
            return pid
        }

        private func mergePhysicalDuplicates(_ input: [Candidate]) -> [Candidate] {
            var merged: [Candidate] = []
            for candidate in input {
                let duplicate = merged.contains {
                    $0.source != candidate.source
                        && $0.item.processIdentifier == candidate.item.processIdentifier
                        && $0.item.bundleIdentifier == candidate.item.bundleIdentifier
                        && $0.item.displayID == candidate.item.displayID
                        && samePhysicalFrame($0.item.frame, candidate.item.frame)
                }
                if !duplicate { merged.append(candidate) }
            }
            return merged
        }

        private func itemOrder(_ lhs: MenuBarOrderItem, _ rhs: MenuBarOrderItem) -> Bool {
            if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.id < rhs.id
        }

        private func display(containing rect: CGRect) -> Display? {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            let tolerance: CGFloat = 2
            let matches = displays.filter {
                rect.minX >= $0.bounds.minX - tolerance && rect.maxX <= $0.bounds.maxX + tolerance
                    && rect.minY >= $0.bounds.minY - tolerance
                    && rect.maxY <= $0.bounds.minY + 80 + tolerance
            }
            // Mirrored displays share coordinates. Never guess which bar owns an item.
            return matches.count == 1 ? matches[0] : nil
        }

        private func overlapsAnyMenuBarBand(_ rect: CGRect) -> Bool {
            let tolerance: CGFloat = 2
            return displays.contains {
                rect.maxX >= $0.bounds.minX - tolerance
                    && rect.minX <= $0.bounds.maxX + tolerance
                    && rect.maxY >= $0.bounds.minY - tolerance
                    && rect.minY <= $0.bounds.minY + 80 + tolerance
            }
        }

        private func samePhysicalFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
                && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
        }

        private func clean(_ value: String?) -> String? {
            guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
            return result
        }

        private func configureTimeout(_ element: AXUIElement, maximum: TimeInterval = 0.05) {
            guard hasTime else { return }
            let remaining = min(deadline, phaseDeadline) - ProcessInfo.processInfo.systemUptime
            _ = AXUIElementSetMessagingTimeout(element, Float(max(0.001, min(maximum, remaining))))
        }

        private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard hasTime else { return nil }
            let (error, result) = MenuBarAXAttributeBatch.copyAttributeValue(element: element, attribute: attribute)
            return error == .success ? result : nil
        }

        private func string(_ element: AXUIElement, _ attribute: String) -> String? {
            value(element, attribute) as? String
        }

        private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            elements(value(element, attribute))
        }

        private func elements(_ raw: CFTypeRef?) -> [AXUIElement] {
            guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID(),
                  let objects = raw as? [AnyObject] else { return [] }
            return objects.compactMap {
                guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast($0, to: AXUIElement.self)
            }
        }

        private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }

        private func frame(_ element: AXUIElement) -> CGRect? {
            frame(MenuBarAXAttributeBatch.read(
                element: element,
                attributes: ["AXFrame", kAXPositionAttribute, kAXSizeAttribute],
                shouldContinue: { hasTime }
            ))
        }

        private func frame(_ attributes: MenuBarAXAttributeBatch) -> CGRect? {
            if let raw = attributes.optionalValue("AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
                let axFrame = unsafeDowncast(raw, to: AXValue.self)
                var rect = CGRect.zero
                if AXValueGetType(axFrame) == .cgRect,
                   AXValueGetValue(axFrame, .cgRect, &rect),
                   rect.origin.x.isFinite, rect.origin.y.isFinite,
                   rect.width.isFinite, rect.height.isFinite,
                   rect.width > 0, rect.height > 0 {
                    return rect
                }
            }
            guard let position = attributes.optionalValue(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attributes.optionalValue(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            let p = unsafeDowncast(position, to: AXValue.self)
            let s = unsafeDowncast(size, to: AXValue.self)
            guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions),
                  point.x.isFinite, point.y.isFinite,
                  dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
    }
}
