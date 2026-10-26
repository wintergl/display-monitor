import AppKit
import DisplayMonitorCore
import SwiftUI

enum DisplayMonitorSettingsLayout {
    static let preferredContentSize = CGSize(width: 760, height: 540)
    static let minimumContentSize = CGSize(width: 700, height: 500)
    static let sidebarWidth: CGFloat = 176
}

enum DisplayMonitorSettingsTab: String, CaseIterable, Hashable, Identifiable {
    case shortcuts
    case screenshots
    case menuBar
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .shortcuts:
            return "快捷键"
        case .screenshots:
            return "截图"
        case .menuBar:
            return "菜单栏"
        case .advanced:
            return "高级"
        }
    }

    var systemImage: String {
        switch self {
        case .shortcuts:
            return "keyboard"
        case .screenshots:
            return "camera"
        case .menuBar:
            return "menubar.rectangle"
        case .advanced:
            return "slider.horizontal.3"
        }
    }
}

@MainActor
final class DisplayMonitorSettingsNavigation: ObservableObject {
    @Published var selectedTab: DisplayMonitorSettingsTab

    init(selectedTab: DisplayMonitorSettingsTab = .shortcuts) {
        self.selectedTab = selectedTab
    }
}

struct DisplayMonitorSettingsView: View {
    @ObservedObject var shell: ToolSuiteShell
    // The system Settings scene rebuilds this view when the shell publishes.
    // Keep its selection for the lifetime of this window, including onAppear
    // permission refreshes from the menu-bar pane.
    @StateObject private var navigation: DisplayMonitorSettingsNavigation

    init(
        shell: ToolSuiteShell,
        initialTab: DisplayMonitorSettingsTab = .shortcuts
    ) {
        self.shell = shell
        _navigation = StateObject(
            wrappedValue: DisplayMonitorSettingsNavigation(selectedTab: initialTab)
        )
    }

    init(
        shell: ToolSuiteShell,
        navigation: DisplayMonitorSettingsNavigation
    ) {
        self.shell = shell
        _navigation = StateObject(wrappedValue: navigation)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(
            minWidth: DisplayMonitorSettingsLayout.minimumContentSize.width,
            idealWidth: DisplayMonitorSettingsLayout.preferredContentSize.width,
            minHeight: DisplayMonitorSettingsLayout.minimumContentSize.height,
            idealHeight: DisplayMonitorSettingsLayout.preferredContentSize.height
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Display Monitor")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    Text("偏好设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 18)

            Text("设置")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 7)

            VStack(spacing: 4) {
                ForEach(DisplayMonitorSettingsTab.allCases) { tab in
                    Button {
                        navigation.selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.systemImage)
                                .frame(width: 18)
                            Text(tab.title)
                                .font(.body.weight(navigation.selectedTab == tab ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(navigation.selectedTab == tab ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            navigation.selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-navigation-\(tab.rawValue)")
                    .accessibilityAddTraits(navigation.selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: DisplayMonitorSettingsLayout.sidebarWidth)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedTab {
        case .shortcuts:
            ShortcutSettingsPane(model: shell.monitor, shell: shell)
        case .screenshots:
            ScreenshotSettingsPane(model: shell.monitor, shell: shell)
        case .menuBar:
            MenuBarManagementView(model: shell.menuBarManagement)
        case .advanced:
            AdvancedSettingsPane(model: shell.monitor, shell: shell)
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 42, height: 42)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                content
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let contentPadding: CGFloat
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        contentPadding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content
                .padding(contentPadding)
        }
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
    }
}

private struct ShortcutSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: ToolSuiteShell

    var body: some View {
        SettingsPage(
            title: "全局快捷键",
            subtitle: "点击按键框录制新的组合键。录制期间全局快捷键会临时停用，松开按键后自动恢复。",
            systemImage: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if shell.isShortcutRecording {
                    Label("正在录制快捷键；按 Esc 可取消，本次录制结束前其他快捷键不会响应。", systemImage: "record.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                SettingsCard("快捷键绑定", systemImage: "command", contentPadding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(ToolSuiteCommand.allCases.enumerated()), id: \.element) { index, command in
                            ShortcutSettingsRow(
                                command: command,
                                binding: binding(for: command),
                                registration: model.shortcutRegistrations.first { $0.shortcut == command },
                                isShortcutRecording: shell.isShortcutRecording,
                                onChange: shell.updateShortcutBinding,
                                onRecordingBegan: shell.beginShortcutRecording,
                                onRecordingEnded: shell.finishShortcutRecording
                            )
                            if index < ToolSuiteCommand.allCases.count - 1 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    Button("恢复默认") {
                        shell.restoreDefaultShortcutBindings()
                    }
                    .disabled(shell.isShortcutRecording)

                    Spacer(minLength: 12)

                    if let message = shell.shortcutSettingsMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("点击按键框开始录制，按 Esc 取消。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func binding(for command: ToolSuiteCommand) -> ShortcutBinding {
        model.shortcutBindings.first { $0.command == command }
            ?? ShortcutRegistry.defaultBindings.first { $0.command == command }!
    }
}

private struct ShortcutSettingsRow: View {
    let command: ToolSuiteCommand
    let binding: ShortcutBinding
    let registration: GlobalShortcutRegistration?
    let isShortcutRecording: Bool
    let onChange: (ShortcutBinding) -> Bool
    let onRecordingBegan: () -> Bool
    let onRecordingEnded: (ShortcutRecorderCompletion) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: command.settingsSystemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(command.title)
                    .font(.body.weight(.medium))
                Label(registrationText, systemImage: registrationSystemImage)
                    .font(.caption)
                    .foregroundStyle(registrationColor)
            }

            Spacer(minLength: 16)

            ShortcutRecorderView(
                binding: binding,
                onChange: onChange,
                onRecordingBegan: onRecordingBegan,
                onRecordingEnded: onRecordingEnded
            )
            .frame(width: 126, height: 28)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }

    private var registrationText: String {
        if isShortcutRecording {
            return "录制期间暂停"
        }
        guard let registration else { return "等待注册" }
        return registration.isRegistered ? "已启用" : "不可用（\(registration.statusCode)）"
    }

    private var registrationSystemImage: String {
        if isShortcutRecording {
            return "pause.circle.fill"
        }
        guard let registration else { return "clock.fill" }
        return registration.isRegistered ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var registrationColor: Color {
        if isShortcutRecording {
            return .orange
        }
        guard let registration else { return .secondary }
        return registration.isRegistered ? .green : .red
    }
}

private struct ScreenshotSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: ToolSuiteShell

    var body: some View {
        SettingsPage(
            title: "截图",
            subtitle: "管理截图保存位置与完成后的预览行为。",
            systemImage: "camera"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard("保存位置", systemImage: "folder") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.screenshotSaveDirectoryName)
                                    .font(.body.weight(.semibold))
                                Text(model.screenshotSaveDirectory.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                        }

                        HStack(spacing: 8) {
                            Button("选择文件夹…") {
                                shell.chooseScreenshotSaveDirectory()
                            }
                            Button("在 Finder 中显示") {
                                shell.revealScreenshotSaveDirectory()
                            }
                            Spacer()
                            Button("恢复默认") {
                                shell.resetScreenshotSaveDirectory()
                            }
                            .disabled(model.usesDefaultScreenshotSaveDirectory)
                        }

                        Text("同名文件会自动追加序号，不会覆盖已有截图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard("截图浮窗", systemImage: "rectangle.on.rectangle") {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: "自动显示预览",
                            detail: "截图完成后显示预览浮窗"
                        ) {
                            Toggle("", isOn: autoPresentBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        Divider()
                            .padding(.vertical, 12)

                        SettingsControlRow(
                            title: "跟随当前显示器",
                            detail: "在鼠标所在显示器展示预览"
                        ) {
                            Toggle("", isOn: followsDisplayBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        Divider()
                            .padding(.vertical, 12)

                        SettingsControlRow(
                            title: "定时截图倒计时",
                            detail: "框选区域后等待多久再截图"
                        ) {
                            Picker("", selection: screenshotTimerBinding) {
                                ForEach([3, 5, 10], id: \.self) { seconds in
                                    Text("\(seconds) 秒").tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        Divider()
                            .padding(.vertical, 12)

                        SettingsControlRow(
                            title: "滚动截图方式",
                            detail: "选择滚动内容的采集方式"
                        ) {
                            Picker("", selection: scrollCaptureModeBinding) {
                                ForEach(ScrollCaptureMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                }
            }
        }
    }

    private var autoPresentBinding: Binding<Bool> {
        Binding(
            get: { model.artifactShelfAutoPresent },
            set: { model.setArtifactShelfAutoPresent($0) }
        )
    }

    private var followsDisplayBinding: Binding<Bool> {
        Binding(
            get: { model.artifactShelfFollowsActiveDisplay },
            set: { shell.setArtifactShelfFollowsActiveDisplay($0) }
        )
    }

    private var screenshotTimerBinding: Binding<Int> {
        Binding(
            get: { model.screenshotTimerDelaySeconds },
            set: { model.setScreenshotTimerDelaySeconds($0) }
        )
    }

    private var scrollCaptureModeBinding: Binding<ScrollCaptureMode> {
        Binding(
            get: { model.scrollCaptureMode },
            set: { model.setScrollCaptureMode($0) }
        )
    }
}

private struct AdvancedSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: ToolSuiteShell

    var body: some View {
        SettingsPage(
            title: "高级",
            subtitle: "调整显示器采集、鼠标控制、权限与应用行为。",
            systemImage: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard("显示器与采集", systemImage: "display") {
                    VStack(spacing: 0) {
                        SettingsControlRow(title: "目标显示器", detail: "Monitor 预览与控制目标") {
                            Picker("", selection: selectedDisplayBinding) {
                                Text("未选择").tag(nil as CGDirectDisplayID?)
                                ForEach(model.displays) { display in
                                    Text(display.localizedName).tag(Optional(display.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        settingsDivider

                        SettingsControlRow(title: "采集帧率", detail: "更高帧率会增加资源占用") {
                            Picker("", selection: frameRateBinding) {
                                ForEach([5, 10, 15, 30], id: \.self) { rate in
                                    Text("\(rate) FPS").tag(rate)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        settingsDivider

                        SettingsControlRow(title: "输出分辨率") {
                            Picker("", selection: captureResolutionBinding) {
                                ForEach(CaptureResolutionPreset.selectableCases) { preset in
                                    Text(preset.label).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        settingsDivider

                        SettingsControlRow(title: "预览窗口") {
                            Picker("", selection: previewWindowSizeBinding) {
                                ForEach(PreviewWindowSizePreset.selectableCases) { preset in
                                    Text(preset.label).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        settingsDivider

                        SettingsControlRow(
                            title: "监控窗口置顶",
                            detail: "开启后保持在普通窗口上方；关闭后可被其他窗口盖住"
                        ) {
                            Toggle("", isOn: previewPinnedBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("监控窗口置顶")
                        }
                    }
                }

                SettingsCard("鼠标与权限", systemImage: "cursorarrow.rays") {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: "显示鼠标指针",
                            detail: "截图与预览中包含鼠标指针"
                        ) {
                            Toggle("", isOn: showsCursorBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        settingsDivider

                        SettingsControlRow(
                            title: "Monitor 画面直控",
                            detail: "在预览画面中直接控制目标屏幕"
                        ) {
                            Toggle("", isOn: controlModeBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!model.isControlModeEnabled && !model.canControlTarget)
                        }

                        settingsDivider

                        SettingsControlRow(title: "直控触发键") {
                            Picker("", selection: directControlModifierBinding) {
                                ForEach(DirectControlModifier.allCases) { modifier in
                                    Text(modifier.menuTitle).tag(modifier)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        settingsDivider

                        PermissionSettingsRow(
                            title: "屏幕录制",
                            status: shell.permissionCenter.screenRecordingLabel,
                            onOpen: shell.openScreenRecordingSettings
                        )

                        settingsDivider

                        PermissionSettingsRow(
                            title: "辅助功能",
                            status: shell.permissionCenter.accessibilityLabel,
                            onOpen: shell.openAccessibilitySettings
                        )
                    }
                }

                SettingsCard("应用", systemImage: "app.badge") {
                    VStack(spacing: 0) {
                        SettingsControlRow(
                            title: "开机启动",
                            detail: model.launchAtLoginStatus
                        ) {
                            Button("切换") {
                                model.toggleLaunchAtLogin()
                            }
                        }

                        settingsDivider

                        SettingsControlRow(
                            title: "预览窗口位置",
                            detail: "恢复到默认显示位置"
                        ) {
                            Button("恢复") {
                                model.resetPreviewWindow()
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.vertical, 12)
    }

    private var selectedDisplayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { displayID in
                guard let display = model.displays.first(where: { $0.id == displayID }) else { return }
                Task { await model.selectDisplay(display) }
            }
        )
    }

    private var frameRateBinding: Binding<Int> {
        Binding(
            get: { model.frameRate },
            set: { rate in Task { await model.setFrameRate(rate) } }
        )
    }

    private var captureResolutionBinding: Binding<CaptureResolutionPreset> {
        Binding(
            get: { model.captureResolution },
            set: { preset in Task { await model.setCaptureResolution(preset) } }
        )
    }

    private var previewWindowSizeBinding: Binding<PreviewWindowSizePreset> {
        Binding(
            get: { model.previewWindowSize },
            set: { model.setPreviewWindowSize($0) }
        )
    }

    private var previewPinnedBinding: Binding<Bool> {
        Binding(
            get: { model.previewIsPinned },
            set: { model.setPreviewPinned($0) }
        )
    }

    private var showsCursorBinding: Binding<Bool> {
        Binding(
            get: { model.showsCursor },
            set: { value in Task { await model.setShowsCursor(value) } }
        )
    }

    private var directControlModifierBinding: Binding<DirectControlModifier> {
        Binding(
            get: { model.directControlModifier },
            set: { model.setDirectControlModifier($0) }
        )
    }

    private var controlModeBinding: Binding<Bool> {
        Binding(
            get: { model.isControlModeEnabled },
            set: { enabled in
                guard enabled != model.isControlModeEnabled else { return }
                model.toggleControlMode()
            }
        )
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let status: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("系统设置…", action: onOpen)
        }
    }
}

private extension ToolSuiteCommand {
    var settingsSystemImage: String {
        switch self {
        case .toggleMonitor:
            return "rectangle.on.rectangle"
        case .captureRegion:
            return "viewfinder"
        case .togglePause:
            return "pause.fill"
        case .moveToTarget:
            return "arrow.right.to.line"
        case .moveToMain:
            return "arrow.left.to.line"
        }
    }
}
