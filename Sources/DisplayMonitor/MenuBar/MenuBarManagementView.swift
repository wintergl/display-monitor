import SwiftUI

private enum MenuBarManagementSection: String, CaseIterable, Identifiable {
    case collapse
    case order

    var id: Self { self }

    var title: String {
        switch self {
        case .collapse: return "收起"
        case .order: return "排序"
        }
    }
}

struct MenuBarManagementView: View {
    @ObservedObject var model: MenuBarManagementCoordinator
    @State private var section: MenuBarManagementSection = .collapse
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    appearanceSettings
                    availabilityCard

                    Picker("功能", selection: $section) {
                        ForEach(MenuBarManagementSection.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if section == .collapse {
                        collapseContent
                    } else {
                        orderContent
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshPermissions()
        }
        .onChange(of: section) { section in
            if section == .order { model.prepareForOrderEditing() }
        }
        .confirmationDialog(
            "恢复上次应用前顺序？",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("恢复上次应用前顺序") {
                model.restoreOrder()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移动真实菜单栏图标。\(model.recoverySummary)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text("菜单栏整理")
                    .font(.title2.weight(.semibold))
                Text("以 Display Monitor 图标为固定分界：左侧为收起区，右侧始终可见。草稿只有点“应用排序”后才会移动真实图标。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("入口图标样式")
                Spacer()
                Image(systemName: model.iconStyle.symbolName)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Picker("入口图标样式", selection: Binding(
                    get: { model.iconStyle },
                    set: { model.setIconStyle($0) }
                )) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbolName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("menu-bar-icon-style")
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动隐藏时长")
                    Text("临时展开后等待多久再收起（1–300 秒）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("秒", value: Binding(
                    get: { model.autoHideDelaySeconds },
                    set: { model.setAutoHideDelaySeconds($0) }
                ), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityLabel("自动隐藏秒数")
                Stepper(value: Binding(
                    get: { model.autoHideDelaySeconds },
                    set: { model.setAutoHideDelaySeconds($0) }
                ), in: MenuBarAutoHideDelay.range) {
                    Text("秒")
                }
                .fixedSize()
                .accessibilityLabel("自动隐藏时长，秒")
                .accessibilityIdentifier("menu-bar-auto-hide-delay")
                Button("恢复默认") {
                    model.setAutoHideDelaySeconds(MenuBarAutoHideDelay.defaultSeconds)
                }
                .disabled(model.autoHideDelaySeconds == MenuBarAutoHideDelay.defaultSeconds)
            }
            Text("时长在开启“默认长期收起左侧图标”后生效；操作菜单时暂缓隐藏。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                availabilityTitle,
                systemImage: model.isCollapseAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(model.isCollapseAvailable ? .green : .orange)

            Text(model.featureAvailabilityMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(
                "启用菜单栏整理",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(!model.isFeatureAvailable)

            Text("启用后会先重新读取真实菜单栏；校验通过后，默认长期收起分界左侧的第三方图标。排序仍只在点“应用排序”后执行。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                permissionLabel("读取图标", granted: model.permissionStatus.accessibilityGranted)
                permissionLabel("模拟拖动", granted: model.permissionStatus.eventPostingGranted)
                Spacer()
                if !model.permissionStatus.canSort {
                    Button("检查并申请权限") {
                        model.requestNextPermission()
                    }
                    .accessibilityLabel("检查并申请菜单栏权限")
                    .disabled(!model.isFeatureAvailable)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
    }

    private var collapseContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(
                "默认长期收起左侧图标",
                isOn: Binding(
                    get: { model.wantsPersistentCollapse },
                    set: { model.setPersistentCollapseDesired($0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(!model.isEnabled || !model.isCollapseAvailable)

            Text("开启后，临时展开 \(model.autoHideDelaySeconds) 秒且鼠标离开顶部、没有正在操作菜单时自动收起；关闭后保持展开。再次点击入口可立即收起。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("左键 Display Monitor 图标时")
                    .font(.subheadline.weight(.semibold))
                Picker(
                    "隐藏图标显示方式",
                    selection: Binding(
                        get: { model.primaryPresentationMode },
                        set: { model.setPrimaryPresentationMode($0) }
                    )
                ) {
                    Text("在顶部菜单栏展开").tag(MenuBarPrimaryPresentationMode.nativeMenuBar)
                    Text("在图标下方显示快捷栏").tag(MenuBarPrimaryPresentationMode.quickBar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.isEnabled)

                Text(presentationModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "悬停在入口时显示图标条",
                    isOn: Binding(
                        get: { model.showQuickBarOnHover },
                        set: { model.setShowQuickBarOnHover($0) }
                    )
                )
                .disabled(!model.isEnabled || model.primaryPresentationMode != .quickBar)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(collapseStatusTitle)
                        .font(.headline)
                    Text(model.collapseSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isCollapsed || model.isPreparingCollapse ? "临时展开" : "立即重新收起") {
                    model.toggleCollapseFromSettings()
                }
                .accessibilityLabel(model.isCollapsed || model.isPreparingCollapse ? "临时展开左侧图标" : "立即重新收起左侧图标")
                .accessibilityIdentifier("menu-bar-collapse-toggle")
                .buttonStyle(.borderedProminent)
                .disabled(!model.canToggleCollapse)
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                regionSummary(
                    title: "收起区",
                    subtitle: "最近读取的真实分界左侧",
                    items: model.actualLeft,
                    color: .blue
                )
                regionSummary(
                    title: "常显区",
                    subtitle: "最近读取的真实分界右侧",
                    items: model.actualRight,
                    color: .green
                )
            }

            if model.hasChanges {
                Label("排序草稿尚未应用。收起仍按上次读取的真实分组计算。", systemImage: "pencil.and.list.clipboard")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let reason = model.collapseBlockingReason, !model.isCollapsed {
                Label(reason, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
    }

    private var presentationModeHelp: String {
        switch model.primaryPresentationMode {
        case .nativeMenuBar:
            return "左键后释放隐藏，让真实图标回到顶部；再次左键即可重新收起。"
        case .quickBar:
            return "左键后在入口下方显示代理图标。点某项时会临时展开并由对应的真实顶部图标打开原生菜单。"
        }
    }

    @ViewBuilder
    private var orderContent: some View {
        HStack {
            if model.displayIDs.count > 1 {
                Picker("菜单栏", selection: Binding(
                    get: { model.selectedDisplayID },
                    set: { model.selectDisplay($0) }
                )) {
                    ForEach(model.displayIDs, id: \.self) { displayID in
                        Text(model.displayName(displayID)).tag(displayID)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }
            Spacer()
            Button("重新读取") { model.readInventory() }
                .accessibilityLabel("重新读取菜单栏图标")
                .accessibilityIdentifier("menu-bar-order-read")
                .disabled(!model.canReadInventory)
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("草稿顺序").font(.headline)
                    Text("从上到下对应菜单栏从左到右")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.hasChanges ? "未应用" : "与真实顺序一致")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.hasChanges ? .orange : .secondary)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    orderRegionHeader("收起区 · 固定分界左侧", color: .blue)
                    orderRows(model.draftLeft, isLeft: true)
                    anchorRow
                    orderRegionHeader("常显区 · 固定分界右侧", color: .green)
                    orderRows(model.draftRight, isLeft: false)
                }
            }
            .frame(minHeight: 170, maxHeight: 280)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }

        Text("每次移动后都会重新读取真实菜单栏。若顺序没有变化、图标身份变化或你移动鼠标，排序会立即停止，恢复记录会保留。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.message)
                    .font(.callout)
                    .lineLimit(2)
                if let reason = activeBlockingReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isApplying {
                Button("停止排序") {
                    model.cancel(reason: "用户停止排序，正在释放输入。")
                }
                .accessibilityLabel("停止菜单栏排序")
            } else if section == .collapse {
                Button("读取图标") { model.readInventory(preferCurrentPhysical: true) }
                    .accessibilityLabel("读取菜单栏图标")
                    .accessibilityIdentifier("menu-bar-collapse-read")
                    .disabled(!model.canReadInventory)
                Button("调整左右分组…") {
                    section = .order
                }
                .accessibilityLabel("调整菜单栏左右分组")
                .disabled(!model.isEnabled)
            } else {
                Button("恢复应用前顺序…") {
                    confirmRestore = true
                }
                .accessibilityLabel("恢复上次应用前菜单栏顺序")
                .disabled(!model.canRestoreOrder)
                Button("放弃草稿") { model.discardDraft() }
                    .accessibilityLabel("放弃菜单栏排序草稿")
                    .accessibilityIdentifier("menu-bar-order-discard")
                    .disabled(!model.hasChanges || model.isBusy)
                Button("应用排序") { model.applyDraft() }
                .accessibilityLabel("应用菜单栏排序")
                .accessibilityIdentifier("menu-bar-order-apply")
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApplyDraft)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var collapseStatusTitle: String {
        if model.isPreparingCollapse { return "正在准备收起" }
        if model.isCollapsed { return "左侧图标已收起" }
        return "左侧图标保持展开"
    }

    private var availabilityTitle: String {
        if !model.isFeatureAvailable { return "当前不可使用" }
        if !model.isCollapseAvailable { return "排序能力已就绪" }
        return "系统能力已就绪"
    }

    private var activeBlockingReason: String? {
        if model.isApplying { return nil }
        if section == .collapse {
            return model.collapseBlockingReason ?? model.readBlockingReason
        }
        return model.applyBlockingReason
    }

    private func permissionLabel(_ title: String, granted: Bool) -> some View {
        Label(
            "\(title)：\(granted ? "已授权" : "未授权")",
            systemImage: granted ? "checkmark.circle.fill" : "circle.dashed"
        )
        .font(.caption)
        .foregroundStyle(granted ? .green : .secondary)
    }

    private func regionSummary(
        title: String,
        subtitle: String,
        items: [MenuBarOrderItem],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(items.count) 项")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("暂无项目")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                Text(items.map(\.applicationName).joined(separator: "、"))
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func orderRegionHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.06))
    }

    @ViewBuilder
    private func orderRows(_ items: [MenuBarOrderItem], isLeft: Bool) -> some View {
        if items.isEmpty {
            Text("暂无可排序项目")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 46)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                orderRow(item, index: index, count: items.count, isLeft: isLeft)
                if index < items.count - 1 { Divider().padding(.leading, 38) }
            }
        }
    }

    private var anchorRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.anchorTitle)
                    .font(.callout.weight(.semibold))
                Text("固定分界 · 不移动 · 保持可见")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Display Monitor，固定分界，不可隐藏")
    }

    private func orderRow(
        _ item: MenuBarOrderItem,
        index: Int,
        count: Int,
        isLeft: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.applicationName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if item.title != item.applicationName {
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.canMove(item) {
                Button {
                    model.moveWithinSide(item.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0 || model.isBusy)
                .help("向前移动")

                Button {
                    model.moveWithinSide(item.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == count - 1 || model.isBusy)
                .help("向后移动")

                Button {
                    model.moveAcross(item.id)
                } label: {
                    Image(systemName: isLeft ? "arrow.right" : "arrow.left")
                }
                .disabled(model.isBusy)
                .help(isLeft ? "移到常显区" : "移到收起区")
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("系统项目或本程序项目保持固定")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(item.applicationName)，\(item.title)，\(isLeft ? "收起区" : "常显区")，第 \(index + 1) 项，\(model.hasChanges ? "草稿未应用" : "真实顺序")"
        )
    }
}
