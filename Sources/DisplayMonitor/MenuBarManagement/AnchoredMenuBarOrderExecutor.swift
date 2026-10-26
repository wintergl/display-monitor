import ApplicationServices
import CoreGraphics
import Foundation

struct AnchoredOrderExecutionResult: Sendable {
    let success: Bool
    let message: String
    let verifiedInventory: AnchoredMenuBarInventory?
}

enum AnchoredMenuBarOrderExecutor {
    @MainActor
    static func applicationSnapshot() -> [RunningAppSnapshot] {
        MenuBarOrderExecutor.applicationSnapshot()
    }

    static func apply(
        desiredIDs: [String],
        seedItems: [MenuBarOrderItem],
        displayID: UInt32,
        anchorIdentity: MenuBarAnchorIdentity,
        ownPID: Int32,
        protectionPolicy: MenuBarTargetProtectionPolicy,
        movableItemIDs requestedMovableItemIDs: Set<String>,
        cancellation: OrderCancellation,
        progress: @escaping @Sendable (String) -> Void
    ) async -> AnchoredOrderExecutionResult {
        do {
            progress("预检：完整性、固定分界、权限、恢复记录和拖动源。")
            guard ownPID > 0,
                  protectionPolicy.ownBundleIdentifier == anchorIdentity.bundleIdentifier else {
                throw OrderFailure("当前进程身份或分界保护策略无效，尚未发送输入。")
            }
            let seedAnchors = seedItems.filter(anchorIdentity.matches)
            guard seedAnchors.count == 1, let anchorID = seedAnchors.first?.id else {
                throw OrderFailure("读取结果中没有唯一分界，尚未发送输入。")
            }
            let unprotectedSeedIDs = Set(seedItems.filter {
                $0.id != anchorID
                    && protectionPolicy.reason(
                        bundleIdentifier: $0.bundleIdentifier,
                        applicationName: $0.applicationName
                    ) == nil
            }.map(\.id))
            let seedMovableIDs = requestedMovableItemIDs
            guard seedMovableIDs.isSubset(of: unprotectedSeedIDs) else {
                throw OrderFailure("指定的拖动源包含分界或受保护项目，尚未发送输入。")
            }
            _ = try AnchoredMenuBarPlanner.nextMove(
                current: seedItems,
                desiredIDs: desiredIDs,
                anchorID: anchorID,
                movableItemIDs: seedMovableIDs
            )
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                throw OrderFailure("读取或模拟拖动权限未就绪，尚未发送输入。")
            }

            let deadline = ProcessInfo.processInfo.systemUptime + 45
            let seedIDs = seedItems.sorted(by: itemOrder).map(\.id)
            var previousOrder: [String]?
            var unchangedReads = 0

            for step in 0..<32 {
                try checkCancellation(cancellation)
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw OrderFailure("排序达到时间上限，已停止；恢复记录仍保留。")
                }
                let apps = await MenuBarOrderExecutor.applicationSnapshot()
                guard apps.contains(where: {
                    $0.processIdentifier == ownPID
                        && $0.bundleIdentifier == anchorIdentity.bundleIdentifier
                }) else {
                    throw OrderFailure("当前进程身份已变化，尚未继续排序。")
                }
                guard !apps.contains(where: {
                    $0.processIdentifier != ownPID
                        && $0.bundleIdentifier == anchorIdentity.bundleIdentifier
                }) else {
                    throw OrderFailure("检测到多个 Display Monitor 实例，尚未继续排序。")
                }
                guard !apps.contains(where: {
                    MenuBarTargetProtectionPolicy.isKnownManager(
                        bundleIdentifier: $0.bundleIdentifier,
                        name: $0.name
                    )
                }) else {
                    throw OrderFailure("检测到其他菜单栏管理器，排序已停止。")
                }

                let read = AnchoredMenuBarDiscovery.scan(
                    applications: apps,
                    anchorIdentity: anchorIdentity,
                    ownPID: ownPID,
                    protectionPolicy: protectionPolicy
                )
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw OrderFailure("排序达到时间上限；本次读取完成后已停止，没有继续发送拖动输入。恢复记录仍保留。")
                }
                let layouts = try read.inventory.validatedLayouts()
                guard let layout = layouts.first(where: { $0.displayID == displayID }) else {
                    throw OrderFailure("目标显示器的固定分界已经消失，已停止。")
                }
                let current = layout.orderedItems
                let currentIDs = current.map(\.id)
                guard Set(currentIDs) == Set(desiredIDs), currentIDs.count == desiredIDs.count else {
                    throw OrderFailure("菜单栏项目集合已变化，尚未继续移动。请重新读取。")
                }
                if step == 0 && currentIDs != seedIDs {
                    throw OrderFailure("应用前菜单栏顺序已变化，尚未发送输入。请重新读取。")
                }
                progress("第 \(step + 1) 次读取：" + current.map {
                    "\($0.applicationName)(x=\(Int($0.frame.minX)))"
                }.joined(separator: " → "))

                let currentUnprotectedIDs = Set(current.filter {
                    $0.id != layout.anchorID
                        && protectionPolicy.reason(
                            bundleIdentifier: $0.bundleIdentifier,
                            applicationName: $0.applicationName
                        ) == nil
                }.map(\.id))
                let movableIDs = requestedMovableItemIDs
                guard movableIDs.isSubset(of: currentUnprotectedIDs) else {
                    throw OrderFailure("指定的拖动源已经消失或变为受保护项目，排序已停止。")
                }
                guard let move = try AnchoredMenuBarPlanner.nextMove(
                    current: current,
                    desiredIDs: desiredIDs,
                    anchorID: layout.anchorID,
                    movableItemIDs: movableIDs
                ) else {
                    return AnchoredOrderExecutionResult(
                        success: true,
                        message: "已重新读取并确认分界两侧顺序与草稿完全一致。",
                        verifiedInventory: read.inventory
                    )
                }

                if currentIDs == previousOrder { unchangedReads += 1 } else { unchangedReads = 0 }
                guard unchangedReads < 2 else {
                    throw OrderFailure("连续两次拖动后顺序没有变化，排序已停止；恢复记录仍保留。")
                }
                previousOrder = currentIDs

                guard move.itemID != layout.anchorID,
                      let source = current.first(where: { $0.id == move.itemID }),
                      let reference = current.first(where: { $0.id == move.referenceItemID }),
                      source.displayID == reference.displayID,
                      protectionPolicy.reason(
                        bundleIdentifier: source.bundleIdentifier,
                        applicationName: source.applicationName
                      ) == nil else {
                    throw OrderFailure("规划结果试图移动分界或受保护项目，已阻断。")
                }

                progress("第 \(step + 1) 步：将 \(source.applicationName) 移到 \(reference.applicationName) \(move.placement == .before ? "前面" : "后面")。")
                try await MenuBarCommandDrag.perform(
                    from: source,
                    relativeTo: reference,
                    placement: move.placement,
                    cancellation: cancellation,
                    progress: progress
                )
                progress("拖动已结束，正在重新读取 left / anchor / right；尚未判定成功。")
                try await Task.sleep(for: .milliseconds(450))
            }
            throw OrderFailure("排序达到步骤上限，已停止；恢复记录仍保留。")
        } catch is CancellationError {
            let reason = cancellation.cancellationReason ?? "取消请求或 Esc"
            return AnchoredOrderExecutionResult(
                success: false,
                message: "排序已停止：\(reason)。合成输入已释放，恢复记录仍保留。",
                verifiedInventory: nil
            )
        } catch {
            return AnchoredOrderExecutionResult(
                success: false,
                message: error.localizedDescription,
                verifiedInventory: nil
            )
        }
    }

    private static func checkCancellation(_ cancellation: OrderCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled || CGEventSource.keyState(.hidSystemState, key: 53) {
            throw CancellationError()
        }
    }

    private static func itemOrder(_ lhs: MenuBarOrderItem, _ rhs: MenuBarOrderItem) -> Bool {
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        return lhs.id < rhs.id
    }
}
