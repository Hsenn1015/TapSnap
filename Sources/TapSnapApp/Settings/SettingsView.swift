import AppKit
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapIcons
import TapSnapSystem
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 设置窗口。
///
/// 左侧导航切换截图、贴图、保存、快捷键等分类，右侧显示分组设置。
struct SettingsView: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }

    @State private var section: SettingsSection

    init(environment: AppEnvironment, section: SettingsSection = .general) {
        self.environment = environment
        self.config = environment.config
        _section = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(theme.token(.sidebarBorder))
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.token(.background))
        }
        .frame(width: 640, height: 460)
        .background(theme.token(.background))
        .foregroundStyle(theme.token(.foreground))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                SidebarItem(
                    title: item.title,
                    icon: item.icon,
                    theme: theme,
                    isSelected: section == item
                ) {
                    withAnimation(Interaction.toggle) { section = item }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 168)
        .background(theme.token(.sidebar))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings(environment: environment)
        case .capture: CaptureSettings(environment: environment)
        case .privacy: PrivacySettingsView(config: config, theme: theme)
        case .pin: PinSettings(environment: environment)
        case .annotate: AnnotateSettings(environment: environment)
        case .record: RecordSettings(environment: environment)
        case .longShot: LongShotSettings(environment: environment)
        case .shortcut: ShortcutSettings(environment: environment)
        case .about: AboutSettings(environment: environment)
        }
    }
}

// MARK: - 侧边栏条目

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, capture, privacy, pin, annotate, record, longShot, shortcut, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "截图"
        case .privacy: return "隐私打码"
        case .pin: return "贴图"
        case .annotate: return "标注"
        case .record: return "录屏"
        case .longShot: return "长截图"
        case .shortcut: return "快捷键"
        case .about: return "关于"
        }
    }

    var icon: IconSet {
        switch self {
        case .general: return .settings
        case .capture: return .crop
        case .privacy: return .privacy
        case .pin: return .pin
        case .annotate: return .pen
        case .record: return .record
        case .longShot: return .longShot
        case .shortcut: return .shortcut
        case .about: return .info
        }
    }
}

private struct SidebarItem: View {
    var title: String
    var icon: IconSet
    var theme: Theme
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconView(
                    icon: icon,
                    size: 13,
                    color: isSelected ? theme.token(.sidebarAccentForeground) : theme.token(.sidebarForeground).opacity(0.75)
                )
                .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.token(.sidebarAccentForeground) : theme.token(.sidebarForeground))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                    .fill(background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.98))
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
    }

    private var background: Color {
        if isSelected { return theme.token(.sidebarAccent) }
        if isHovering { return theme.token(.sidebarAccent).opacity(0.6) }
        return .clear
    }
}

// MARK: - 页面骨架

/// 每个设置页统一的头部 + 滚动内容。
struct SettingsPage<Content: View>: View {
    var title: String
    var theme: Theme
    private let content: () -> Content

    init(title: String, theme: Theme, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.theme = theme
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                    .padding(.bottom, 2)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    @ObservedObject private var toolBall = ToolBallController.shared
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(title: "通用", theme: theme) {
            SnapSettingGroup("外观", theme: theme) {
                SnapSettingRow("深色界面", subtitle: "跟随设置而非系统外观", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.appearance.useDarkTheme },
                            set: { value in config.update { $0.appearance.useDarkTheme = value } }
                        ),
                        theme: theme
                    )
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("显示悬浮球", subtitle: "桌面边缘的快捷截图入口", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { toolBall.isVisible },
                            set: { $0 ? toolBall.show() : toolBall.hide() }
                        ),
                        theme: theme
                    )
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("显示桌面工具栏", theme: theme) {
                    SnapToggle(isOn: Binding(get: { config.settings.appearance.showDesktopBar },
                        set: { value in config.update { $0.appearance.showDesktopBar = value } }), theme: theme)
                }

            }
        }
    }
}

// MARK: - 截图

private struct CaptureSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    @State private var customizesSelectionToolbar = false
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(title: "截图", theme: theme) {
            SnapSettingGroup(theme: theme) {
                SnapSettingRow("框选工具栏", subtitle: "选择普通截图时直接显示的按钮", theme: theme) {
                    SnapButton("自定义…", theme: theme, variant: .outline, size: .sm) {
                        customizesSelectionToolbar = true
                    }
                }
            }
            SnapSettingGroup("选区边框", theme: theme) {
                SnapSettingRow("边框样式", theme: theme) {
                    Picker("边框样式", selection: bind(\.capture.selectionBorderStyle)) {
                        ForEach(SelectionBorderStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 144)
                }
                SelectionBorderPreview(style: config.settings.capture.selectionBorderStyle)
                    .frame(height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusSM))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)
            }

            SnapSettingGroup("行为", theme: theme) {
                row("截图时隐藏桌面图标", bind(\.capture.hideDesktopIcons))
                SnapRowDivider(theme: theme)
                row("播放快门声", bind(\.capture.playShutterSound))
                SnapRowDivider(theme: theme)
                row("自动复制到剪贴板", bind(\.capture.autoCopyToClipboard))
                SnapRowDivider(theme: theme)
                row("自动保存到文件", bind(\.capture.autoSaveToFile))
            }

            SnapSettingGroup("选区辅助", theme: theme) {
                row("显示放大镜", bind(\.capture.showMagnifier))
                SnapRowDivider(theme: theme)
                row("显示选区尺寸", bind(\.capture.showSelectionSize))
            }

            SnapSettingGroup("输出", theme: theme) {
                SnapSettingRow("保存格式", theme: theme) {
                    SnapSegmented(
                        items: ["png", "jpeg", "heic", "webp", "avif"],
                        selection: bind(\.capture.saveFormat),
                        theme: theme
                    ) { $0.uppercased() }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("保存目录", theme: theme) {
                    HStack(spacing: 8) {
                        Text(config.settings.capture.saveDirectory)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.token(.mutedForeground))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)
                        SnapButton("更改…", theme: theme, variant: .outline, size: .sm) {
                            chooseSaveDirectory()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $customizesSelectionToolbar) {
            SelectionToolbarSettings(theme: theme, identifiers: config.settings.capture.selectionToolbarActions) { identifiers in
                config.update { $0.capture.selectionToolbarActions = identifiers }
            }
        }
    }

    private func row(_ title: String, _ binding: Binding<Bool>) -> some View {
        SnapSettingRow(title, theme: theme) {
            SnapToggle(isOn: binding, theme: theme)
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            config.update { $0.capture.saveDirectory = url.path }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<TapSnapConfig.Settings, T>) -> Binding<T> {
        Binding(
            get: { config.settings[keyPath: keyPath] },
            set: { value in config.update { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct SelectionBorderPreview: NSViewRepresentable {
    var style: SelectionBorderStyle

    func makeNSView(context: Context) -> PreviewView { PreviewView(frame: .zero) }

    func updateNSView(_ view: PreviewView, context: Context) { view.border.style = style }

    final class PreviewView: NSView {
        let border = SelectionBorderView(frame: .zero)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            border.frame = bounds
            border.autoresizingMask = [.width, .height]
            border.showsResizeHandles = true
            addSubview(border)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            border.selectionRect = bounds.insetBy(dx: max(28, bounds.width * 0.18), dy: 25)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
            context.setFillColor(RGBAColor(rgb: 0xf5f7fa).cgColor)
            context.fill(left)
            context.setFillColor(RGBAColor(rgb: 0x161c25).cgColor)
            context.fill(bounds.offsetBy(dx: left.width, dy: 0))
            if let selection = border.selectionRect, !selection.isEmpty {
                context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                context.addRect(bounds)
                context.addRect(selection)
                context.fillPath(using: .evenOdd)
            }
        }
    }
}

// MARK: - 贴图

private struct PinSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(title: "贴图", theme: theme) {
            SnapSettingGroup("行为", theme: theme) {
                row("默认置顶", bind(\.pin.alwaysOnTop))
                SnapRowDivider(theme: theme)
                row("双击关闭贴图", bind(\.pin.doubleClickToClose))
                SnapRowDivider(theme: theme)
                row("显示阴影", bind(\.pin.showShadow))
                SnapRowDivider(theme: theme)
                row("拖动时吸附屏幕边缘", bind(\.pin.snapToEdges))
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认不透明度", theme: theme) {
                    SnapSlider(
                        value: Binding(
                            get: { config.settings.pin.defaultOpacity },
                            set: { value in config.update { $0.pin.defaultOpacity = value } }
                        ),
                        in: 0.1...1,
                        theme: theme,
                        width: 160
                    )
                }
            }

            SnapButton("关闭所有贴图", theme: theme, variant: .destructive, size: .md) {
                environment.pinGroups.closeAll()
            }
        }
    }

    private func row(_ title: String, _ binding: Binding<Bool>) -> some View {
        SnapSettingRow(title, theme: theme) {
            SnapToggle(isOn: binding, theme: theme)
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<TapSnapConfig.Settings, T>) -> Binding<T> {
        Binding(
            get: { config.settings[keyPath: keyPath] },
            set: { value in config.update { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - 标注

private struct AnnotateSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(title: "标注", theme: theme) {
            SnapSettingGroup("工具默认值", theme: theme) {
                SnapSettingRow("默认线宽", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { config.settings.annotate.defaultLineWidth },
                                set: { value in config.update { $0.annotate.defaultLineWidth = value } }
                            ),
                            in: 1...12,
                            theme: theme,
                            width: 150
                        )
                        valueLabel("\(Int(config.settings.annotate.defaultLineWidth))")
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认字号", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { config.settings.annotate.defaultFontSize },
                                set: { value in config.update { $0.annotate.defaultFontSize = value } }
                            ),
                            in: 10...48,
                            theme: theme,
                            width: 150
                        )
                        valueLabel("\(Int(config.settings.annotate.defaultFontSize))")
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("马赛克像素块", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { Double(config.settings.annotate.mosaicBlockSize) },
                                set: { value in config.update { $0.annotate.mosaicBlockSize = Int(value) } }
                            ),
                            in: 4...40,
                            theme: theme,
                            width: 150
                        )
                        valueLabel("\(config.settings.annotate.mosaicBlockSize) px")
                    }
                }
            }

            SnapSettingGroup("智能", theme: theme) {
                SnapSettingRow("马赛克自动识别人脸", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.annotate.autoMosaicDetectsFaces },
                            set: { value in config.update { $0.annotate.autoMosaicDetectsFaces = value } }
                        ),
                        theme: theme
                    )
                }
            }
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(theme.token(.mutedForeground))
            .frame(width: 46, alignment: .trailing)
    }
}

// MARK: - 快捷键

private struct ShortcutSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    @ObservedObject private var center: ShortcutCenter
    @StateObject private var recorder: ShortcutRecorder
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
        self.center = environment.shortcutCenter
        self._recorder = StateObject(wrappedValue: ShortcutRecorder(center: environment.shortcutCenter))
    }

    var body: some View {
        SettingsPage(title: "快捷键", theme: theme) {
            Text("点击录制后按下快捷键，松开即保存。Esc 取消，Delete 清除。")
                .font(.system(size: 11))
                .foregroundStyle(theme.token(.mutedForeground))
            bindings("全局快捷键", for: ShortcutAction.allCases.map(ShortcutRecorder.Target.global))
            bindings("框选与编辑", for: OperationShortcut.all.map(ShortcutRecorder.Target.operation))

            if recorder.action == nil, let message = recorder.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.token(recorder.hasError ? .destructive : .mutedForeground))
            }
            SnapButton("恢复默认快捷键", theme: theme, variant: .outline, size: .md) {
                recorder.cancel()
                config.resetShortcutsToDefaults()
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private func bindings(_ title: String, for actions: [ShortcutRecorder.Target]) -> some View {
        SnapSettingGroup(title, theme: theme) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0 { SnapRowDivider(theme: theme) }
                VStack(alignment: .leading, spacing: 4) {
                    SnapSettingRow(action.displayName, theme: theme) {
                        HStack(spacing: 8) {
                            if recorder.action == action {
                                SnapKbd(recorder.preview, theme: theme)
                                SnapButton("取消", theme: theme, variant: .outline, size: .sm) { recorder.cancel() }
                            } else {
                                let binding = action.binding(in: config)
                                SnapKbd(binding?.displayString ?? "未设置", theme: theme)
                                SnapButton("录制", theme: theme, variant: .outline, size: .sm) { recorder.begin(action) }
                                    .accessibilityLabel("录制\(action.displayName)快捷键")
                                SnapButton("清除", theme: theme, variant: .ghost, size: .sm, isEnabled: binding != nil) {
                                    recorder.clear(action)
                                }
                                .accessibilityLabel("清除\(action.displayName)快捷键")
                            }
                        }
                    }
                    if case .global(let shortcut) = action, recorder.action != action,
                       let failure = center.registrationFailures[shortcut] {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.token(.destructive))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    if recorder.action == action {
                        Text(recorder.message ?? "等待按键…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.token(recorder.hasError ? .destructive : .mutedForeground))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}

// MARK: - 关于

private struct AboutSettings: View {
    let environment: AppEnvironment
    private var theme: Theme { environment.theme }

    var body: some View {
        SettingsPage(title: "关于", theme: theme) {
            SnapButton("打开使用指南", theme: theme, variant: .outline, size: .md) { environment.tutorial.show() }
            SnapSettingGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        IconView(icon: .crop, size: 20, color: theme.token(.foreground))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("TapSnap")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.token(.foreground))
                            Text("版本 \(AppInfo.version) (\(AppInfo.build))")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.token(.mutedForeground))
                        }
                        Spacer()
                    }
                    Text("截图、标注、贴图与录屏工具。识别和翻译在本机处理；首次使用需要下载公式模型或系统语言包。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

// MARK: - 录屏

private struct RecordSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(title: "录屏", theme: theme) {
            SnapSettingGroup("画面", theme: theme) {
                SnapSettingRow("帧率", subtitle: "码率固定 8 Mbps，H.264 硬编", theme: theme) {
                    SnapSegmented(
                        items: [30, 60],
                        selection: Binding(
                            get: { config.settings.record.frameRate },
                            set: { value in config.update { $0.record.frameRate = value } }
                        ),
                        theme: theme
                    ) { fps in
                        "\(fps) fps"
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("包含光标", subtitle: "录制时把鼠标指针画进画面", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.record.includesCursor },
                            set: { value in config.update { $0.record.includesCursor = value } }
                        ),
                        theme: theme
                    )
                }
            }

            SnapSettingGroup("演示", theme: theme) {
                recordingToggle("摄像头画中画", keyPath: \.record.includesCamera)
                recordingToggle("显示快捷键", keyPath: \.record.showsKeyPresses)
                recordingToggle("显示鼠标点击", keyPath: \.record.showsMouseClicks)
                Text("摄像头首次启用时请求权限；快捷键提示只显示组合键，不记录输入文字。")
                    .font(.caption).foregroundStyle(theme.token(.mutedForeground)).padding(12)
            }

            SnapSettingGroup("声音", theme: theme) {
                SnapSettingRow("录制系统声音", subtitle: "录制应用播放的声音", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.record.includesSystemAudio },
                            set: { value in config.update { $0.record.includesSystemAudio = value } }
                        ),
                        theme: theme
                    )
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("录制麦克风", subtitle: "首次使用会请求麦克风权限", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.record.includesMicrophone },
                            set: { value in config.update { $0.record.includesMicrophone = value } }
                        ),
                        theme: theme
                    )
                }
            }
        }
    }
    private func recordingToggle(_ title: String, keyPath: WritableKeyPath<TapSnapConfig.Settings, Bool>) -> some View {
        SnapSettingRow(title, theme: theme) {
            SnapToggle(isOn: Binding(get: { config.settings[keyPath: keyPath] },
                set: { value in config.update { $0[keyPath: keyPath] = value } }), theme: theme)
        }
    }

}

private struct LongShotSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }
    init(environment: AppEnvironment) { self.environment = environment; config = environment.config }
    var body: some View {
        SettingsPage(title: "长截图", theme: theme) {
            Toggle("选区就绪后自动滚动", isOn: bind(\.longShot.autoScroll))
            Text("自动识别滚动视口，固定区域保留一次。可随时暂停、手动滚动或指定滚动区域。")
                .font(.caption).foregroundStyle(theme.token(.mutedForeground))
            Stepper("每次滚动 \(config.settings.longShot.scrollStep) 点", value: bind(\.longShot.scrollStep), in: 20...800, step: 20)
            Stepper("滚动间隔 \(config.settings.longShot.scrollIntervalMs) 毫秒", value: bind(\.longShot.scrollIntervalMs), in: 300...3000, step: 100)
            HStack {
                Text("保留重叠 \(Int(config.settings.longShot.overlapRatio * 100))%")
                Slider(value: bind(\.longShot.overlapRatio), in: 0.35...0.85, step: 0.05)
            }
            Text("每轮分成小步连续滚动，间隔至少 300 毫秒。实际步长会按视口高度保留至少 35% 的重叠；多次对齐失败或画面停止移动时会暂停。")
                .font(.caption).foregroundStyle(theme.token(.mutedForeground))
        }
    }
    private func bind<T>(_ keyPath: WritableKeyPath<TapSnapConfig.Settings, T>) -> Binding<T> {
        Binding(get: { config.settings[keyPath: keyPath] }, set: { value in config.update { $0[keyPath: keyPath] = value } })
    }
}
