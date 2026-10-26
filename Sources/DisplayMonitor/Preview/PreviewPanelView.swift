import DisplayMonitorCore
import SwiftUI

struct PreviewPanelView: View {
    @ObservedObject var model: AppModel
    let sampleDisplayCoordinator: SampleBufferDisplayCoordinator

    var body: some View {
        ZStack {
            SampleBufferView(coordinator: sampleDisplayCoordinator)
                .ignoresSafeArea()

            if shouldShowCenteredState {
                VStack(spacing: 10) {
                    Image(systemName: centeredSymbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(DisplayMonitorColors.brightYellow)
                    Text(model.statusSummary)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.35))
                .allowsHitTesting(false)
            }

            PreviewInputView(
                displayID: model.selectedDisplayID,
                triggerModifier: model.directControlModifier,
                shortcutBindings: model.shortcutRegistrations
                    .filter(\.isRegistered)
                    .map(\.binding),
                isEnabled: model.isControlModeEnabled,
                isAuthorized: model.inputControlPermission == .granted,
                onDirectCaptureChanged: { isActive in
                    model.handleDirectPointerCaptureChanged(isActive)
                },
                onDirectCaptureFailure: { message in
                    model.handleDirectPointerCaptureFailure(message)
                },
                onDirectShortcut: { command in
                    model.handleDirectPointerShortcut(command)
                }
            )
            .allowsHitTesting(false)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
    }

    private var shouldShowCenteredState: Bool {
        switch model.capturePhase {
        case .capturing:
            return false
        default:
            return true
        }
    }

    private var centeredSymbol: String {
        switch model.permissionState {
        case .notGranted, .revoked:
            return "lock.rectangle"
        default:
            switch model.capturePhase {
            case .paused, .pausing:
                return "pause.circle"
            case .failed:
                return "exclamationmark.triangle"
            default:
                return "display"
            }
        }
    }
}

struct PreviewCompanionControlView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PreviewControlBar(model: model)
        .padding(6)
        .frame(width: 560, height: 54)
    }
}

struct PreviewControlBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleControlMode()
            } label: {
                ControlChipLabel(
                    title: controlModeTitle,
                    systemImage: controlModeSymbol,
                    width: 82
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.isControlModeEnabled && !hasOnlineTarget)
            .help(controlModeHelp)
            .accessibilityLabel(model.isControlModeEnabled ? "关闭直控模式" : "开启直控模式")

            Menu {
                if model.displays.isEmpty {
                    Text("未发现显示器")
                } else {
                    ForEach(model.displays) { display in
                        Button {
                            Task { await model.selectDisplay(display) }
                        } label: {
                            Label(
                                display.menuTitle,
                                systemImage: display.id == model.selectedDisplayID
                                    ? "checkmark"
                                    : displaySymbol(for: display)
                            )
                        }
                        .disabled(!display.captureAvailability.isSelectable)
                    }
                }
            } label: {
                ControlChipLabel(
                    title: "屏幕",
                    systemImage: "display",
                    width: 72
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(selectedDisplayHelp)
            .accessibilityLabel("选择监看屏幕")

            Button {
                Task { await model.togglePause() }
            } label: {
                ControlChipLabel(
                    title: isPaused ? "继续" : "暂停",
                    systemImage: isPaused ? "play.fill" : "pause.fill",
                    width: 72
                )
            }
            .buttonStyle(.plain)
            .help(isPaused ? "继续采集" : "暂停采集")
            .accessibilityLabel(isPaused ? "继续采集" : "暂停采集")

            Menu {
                ForEach(CaptureResolutionPreset.selectableCases) { preset in
                    Button {
                        Task { await model.setCaptureResolution(preset) }
                    } label: {
                        Label(
                            preset.label,
                            systemImage: model.captureResolution == preset
                                ? "checkmark"
                                : "rectangle.inset.filled"
                        )
                    }
                }
            } label: {
                ControlChipLabel(
                    title: model.captureResolution.label,
                    systemImage: "rectangle.expand.vertical",
                    width: 116
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换采集输出分辨率")
            .accessibilityLabel("采集输出分辨率 \(model.captureResolution.label)")

            Menu {
                ForEach(PreviewWindowSizePreset.selectableCases) { preset in
                    Button {
                        model.setPreviewWindowSize(preset)
                    } label: {
                        Label(
                            preset.label,
                            systemImage: model.previewWindowSize == preset
                                ? "checkmark"
                                : "rectangle"
                        )
                    }
                }
            } label: {
                ControlChipLabel(
                    title: "窗口",
                    systemImage: "macwindow",
                    width: 72
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("调整预览窗口大小，当前 \(model.previewWindowSize.label)")
            .accessibilityLabel("预览窗口大小 \(model.previewWindowSize.label)")

            Button {
                model.setPreviewPinned(!model.previewIsPinned)
            } label: {
                Image(systemName: model.previewIsPinned ? "pin.fill" : "pin.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.previewIsPinned ? DisplayMonitorColors.brightYellow : Color.secondary)
                    .frame(width: 36, height: 30)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help(model.previewIsPinned ? "取消置顶，允许其他窗口盖住监控窗口" : "置顶监控窗口")
            .accessibilityLabel(model.previewIsPinned ? "取消监控窗口置顶" : "置顶监控窗口")
            .accessibilityValue(model.previewIsPinned ? "已置顶" : "未置顶")
            .accessibilityIdentifier("monitor-preview-pin")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var isPaused: Bool {
        switch model.capturePhase {
        case .paused, .pausing:
            return true
        default:
            return false
        }
    }

    private var controlModeTitle: String {
        if model.isDirectPointerCaptureActive {
            return "直控中"
        }
        return model.isControlModeEnabled
            ? "\(model.directControlModifier.symbol)直控"
            : "操作"
    }

    private var controlModeSymbol: String {
        if model.isDirectPointerCaptureActive {
            return "cursorarrow.rays"
        }
        return model.isControlModeEnabled ? "cursorarrow.rays" : "cursorarrow.click"
    }

    private var selectedDisplayHelp: String {
        guard let selectedDisplayID = model.selectedDisplayID,
              let display = model.displays.first(where: { $0.id == selectedDisplayID }) else {
            return "选择监看屏幕"
        }
        return "当前屏幕：\(display.localizedName)"
    }

    private var hasOnlineTarget: Bool {
        if case .online = model.targetState {
            return true
        }
        return false
    }

    private var controlModeHelp: String {
        if model.isDirectPointerCaptureActive {
            return "松开 \(model.directControlModifier.symbol) 返回 Monitor 窗口"
        }
        if model.isControlModeEnabled {
            return "关闭直控；仅当鼠标位于 Monitor 画面内时，按住 \(model.directControlModifier.symbol) 进入"
        }
        if let message = model.inputControlStatusMessage {
            return message
        }
        if model.inputControlPermission == .granted {
            return "开启直控；触发键可在菜单栏的“直控触发键”中修改"
        }
        return "首次开启直控会请求辅助功能权限（允许控制电脑）"
    }

    private func displaySymbol(for display: DisplayDescriptor) -> String {
        if display.isMirrored {
            return "rectangle.on.rectangle.slash"
        }
        if display.isPrimary {
            return "display"
        }
        return display.captureAvailability.isSelectable
            ? "rectangle.connected.to.line.below"
            : "exclamationmark.triangle"
    }
}

private struct ControlChipLabel: View {
    let title: String
    let systemImage: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(DisplayMonitorColors.brightYellow)
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .frame(width: width, height: 30)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum DisplayMonitorColors {
    static let brightYellow = Color(red: 1.0, green: 0.82, blue: 0.0)
}
