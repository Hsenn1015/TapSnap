import AppKit
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapIcons
import TapSnapMedia
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

    /// 未指定分类时回到上次停留的分类。
    static let lastSectionKey = "settings.lastSection"

    init(environment: AppEnvironment, section: SettingsSection? = nil) {
        self.environment = environment
        self.config = environment.config
        let stored = UserDefaults.standard.string(forKey: Self.lastSectionKey).flatMap(SettingsSection.init(rawValue:))
        _section = State(initialValue: section ?? stored ?? .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(theme.settingsCardBorder)
                .frame(width: 0.75)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.settingsCanvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 960, minHeight: 480, idealHeight: 580, maxHeight: .infinity)
        .background(theme.settingsCanvas)
        .foregroundStyle(theme.token(.foreground))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onChange(of: section) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: Self.lastSectionKey)
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部留出红黄绿交通灯区域，并支持拖移窗口。
            ZStack(alignment: .bottomLeading) {
                WindowDragArea()
                HStack(spacing: 6) {
                    Spacer()
                    if AppPaths.isDevelopmentBuild {
                        Text("开发版")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.controlAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.controlAccent.opacity(theme.isDark ? 0.20 : 0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(height: 44)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.groups, id: \.title) { group in
                        if let title = group.title {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.token(.mutedForeground).opacity(0.85))
                                .padding(.horizontal, 10)
                                .padding(.top, 11)
                                .padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.items) { item in
                            sidebarItem(item)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }

            Rectangle()
                .fill(theme.settingsCardBorder)
                .frame(height: 0.75)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 4) {
                sidebarItem(.about)
                HStack(spacing: 6) {
                    Text(AppInfo.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                    Text("v\(AppInfo.version)")
                        .font(.system(size: 10.5).monospacedDigit())
                    Spacer()
                }
                .foregroundStyle(theme.token(.mutedForeground).opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                SettingsSidebarBackdrop(isDark: theme.isDark)
                (theme.isDark ? Color.black.opacity(0.14) : Color.white.opacity(0.32))
            }
        }
    }

    @ViewBuilder
    private func sidebarItem(_ item: SettingsSection) -> some View {
        let button = SidebarItem(
            section: item,
            theme: theme,
            isSelected: section == item
        ) {
            withAnimation(Interaction.toggle) { section = item }
        }
        if let key = item.keyEquivalent {
            button
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                .help("\(item.title)（⌘\(String(key))）")
        } else {
            button
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings(environment: environment)
        case .capture: CaptureSettings(environment: environment)
        case .translation:
            SettingsPage(section: .translation, theme: theme) {
                TranslationServiceSettingsView(config: config, theme: theme)
            }
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

/// 侧边栏原生 macOS 毛玻璃材质背景。
private struct SettingsSidebarBackdrop: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - 侧边栏条目

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, capture, translation, privacy, pin, annotate, record, longShot, shortcut, about

    var id: String { rawValue }

    /// 侧边栏分组：基础 / 截图 / 录屏 / 智能，「关于」固定在底部。
    static let groups: [(title: String?, items: [SettingsSection])] = [
        (nil, [.general, .shortcut]),
        ("截图", [.capture, .annotate, .pin, .longShot]),
        ("录屏", [.record]),
        ("智能", [.translation, .privacy]),
    ]

    /// 按侧边栏显示顺序分配 ⌘1…⌘9。
    var keyEquivalent: Character? {
        let ordered = Self.groups.flatMap(\.items)
        guard let index = ordered.firstIndex(of: self), index < 9 else { return nil }
        return Character(String(index + 1))
    }

    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "截图"
        case .translation: return "截图翻译"
        case .privacy: return "隐私打码"
        case .pin: return "贴图"
        case .annotate: return "标注"
        case .record: return "录屏"
        case .longShot: return "长截图"
        case .shortcut: return "快捷键"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观主题、悬浮入口与演示录屏模式"
        case .capture: return "框选工具栏、选区边框风格与默认输出"
        case .translation: return "翻译服务引擎、目标语言与秒译卡片样式"
        case .privacy: return "本机脱敏规则、AI 补查与打码外观"
        case .pin: return "贴图阴影质感、窗口行为与不透明度"
        case .annotate: return "画笔线宽、文字字号与马赛克默认参数"
        case .record: return "录屏帧率、鼠标键位动效与音频权限"
        case .longShot: return "自动滚动节奏与长图拼接重叠比例"
        case .shortcut: return "点击快捷键帽即可录制全局与操作绑定"
        case .about: return "版本信息与使用指南"
        }
    }

    var badgeGradient: [Color] {
        switch self {
        case .general: return [Color(red: 0.28, green: 0.56, blue: 0.99), Color(red: 0.14, green: 0.42, blue: 0.95)]
        case .shortcut: return [Color(red: 0.43, green: 0.44, blue: 0.96), Color(red: 0.31, green: 0.28, blue: 0.89)]
        case .capture: return [Color(red: 0.08, green: 0.67, blue: 0.95), Color(red: 0.02, green: 0.50, blue: 0.86)]
        case .annotate: return [Color(red: 0.62, green: 0.38, blue: 0.97), Color(red: 0.48, green: 0.23, blue: 0.91)]
        case .pin: return [Color(red: 0.98, green: 0.64, blue: 0.14), Color(red: 0.90, green: 0.46, blue: 0.06)]
        case .longShot: return [Color(red: 0.11, green: 0.74, blue: 0.66), Color(red: 0.05, green: 0.58, blue: 0.54)]
        case .record: return [Color(red: 0.96, green: 0.32, blue: 0.34), Color(red: 0.85, green: 0.16, blue: 0.22)]
        case .translation: return [Color(red: 0.07, green: 0.72, blue: 0.85), Color(red: 0.15, green: 0.47, blue: 0.94)]
        case .privacy: return [Color(red: 0.12, green: 0.75, blue: 0.51), Color(red: 0.05, green: 0.59, blue: 0.40)]
        case .about: return [Color(red: 0.47, green: 0.53, blue: 0.62), Color(red: 0.33, green: 0.39, blue: 0.48)]
        }
    }

    var icon: IconSet {
        switch self {
        case .general: return .settings
        case .capture: return .crop
        case .translation: return .translate
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

/// macOS 风格圆角彩色图标徽章。
struct SettingsIconBadge: View {
    let section: SettingsSection
    var size: CGFloat = 21

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: section.badgeGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: section.badgeGradient.last?.opacity(0.28) ?? .clear, radius: 2, y: 1)
            IconView(icon: section.icon, size: size * 0.56, color: .white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SidebarItem: View {
    var section: SettingsSection
    var theme: Theme
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsIconBadge(section: section, size: 21)
                Text(section.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.token(.foreground) : theme.token(.foreground).opacity(0.84))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    theme.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.065),
                                    lineWidth: 0.75
                                )
                        }
                    }
                    .shadow(
                        color: isSelected ? Color.black.opacity(theme.isDark ? 0.22 : 0.06) : .clear,
                        radius: 2.5,
                        y: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.985))
        .onHoverChange { hovering in
            withAnimation(Interaction.hover) { isHovering = hovering }
        }
    }

    private var background: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.11) : Color.white.opacity(0.88)
        }
        if isHovering {
            return theme.isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
        }
        return .clear
    }
}

// MARK: - 页面骨架

/// 每个设置页统一的顶栏（可拖移窗口）+ 滚动卡片内容。
struct SettingsPage<Content: View>: View {
    var section: SettingsSection?
    var title: String
    var subtitle: String?
    var theme: Theme
    private let content: () -> Content

    init(section: SettingsSection, theme: Theme, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.title = section.title
        self.subtitle = section.subtitle
        self.theme = theme
        self.content = content
    }

    init(title: String, subtitle: String? = nil, theme: Theme, @ViewBuilder content: @escaping () -> Content) {
        self.section = nil
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                WindowDragArea()
                HStack(spacing: 11) {
                    if let section {
                        SettingsIconBadge(section: section, size: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(theme.token(.foreground))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.token(.mutedForeground))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
            }
            .frame(height: 70)

            Rectangle()
                .fill(theme.settingsCardBorder)
                .frame(height: 0.75)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
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
        SettingsPage(section: .general, theme: theme) {
            SnapSettingGroup("外观", theme: theme) {
                SnapSettingRow("深色界面", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.appearance.useDarkTheme },
                            set: { value in config.update { $0.appearance.useDarkTheme = value } }
                        ),
                        theme: theme
                    )
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("显示悬浮球", theme: theme) {
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

            SnapSettingGroup("录屏与演示", theme: theme) {
                SnapSettingRow(
                    "演示模式（允许录屏）",
                    subtitle: "允许系统截屏、录屏软件或双开 TapSnap 捕获本应用的选区、贴图与工具栏",
                    theme: theme
                ) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.capture.allowSelfCapture },
                            set: { value in config.update { $0.capture.allowSelfCapture = value } }
                        ),
                        theme: theme
                    )
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
        SettingsPage(section: .capture, theme: theme) {
            SnapSettingGroup(theme: theme) {
                SnapSettingRow("框选工具栏", theme: theme) {
                    SnapButton("自定义…", theme: theme, variant: .outline, size: .sm) {
                        customizesSelectionToolbar = true
                    }
                }
            }
            SnapSettingGroup("选区边框", theme: theme) {
                SnapSettingRow("边框风格", theme: theme) {
                    Picker("边框风格", selection: bind(\.capture.selectionBorderStyle)) {
                        ForEach(SelectionBorderStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 152)
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("动态效果", theme: theme) {
                    Picker("动态效果", selection: bind(\.capture.selectionBorderMotion)) {
                        ForEach(config.settings.capture.selectionBorderStyle.availableMotions, id: \.self) { motion in
                            Text(motion.displayName).tag(motion)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 152)
                }
                SnapRowDivider(theme: theme)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("主题配色")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.token(.foreground))
                        Spacer()
                        Text(config.settings.capture.selectionBorderPalette.displayName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.token(.mutedForeground))
                    }
                    borderPaletteSwatchStrip
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
                SelectionBorderPreview(configuration: config.settings.capture.selectionBorderConfiguration)
                    .frame(height: 122)
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
                SnapSettingRow("文件命名", subtitle: fileNamingPreview, theme: theme) {
                    Picker("文件命名", selection: bind(\.capture.fileNamingMode)) {
                        ForEach(CaptureFileNamingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 176)
                }
                if config.settings.capture.fileNamingMode == .customPrefixSequence {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("文件名前缀", subtitle: "留空时默认使用 TapSnap", theme: theme) {
                        TextField("如：退款流程", text: bind(\.capture.fileNamePrefix))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 176)
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("保存目录", theme: theme) {
                    HStack(spacing: 8) {
                        Button {
                            revealSaveDirectory()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10.5))
                                Text(abbreviatedSaveDirectory)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(theme.token(.mutedForeground))
                            .frame(maxWidth: 190, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .help("点击在访达中打开：\(config.settings.capture.saveDirectory)")
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

    private var borderPaletteSwatchStrip: some View {
        let palettes = config.settings.capture.selectionBorderStyle.availablePalettes
        let selected = config.settings.capture.selectionBorderPalette
        let columns = [GridItem(.adaptive(minimum: 94), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(palettes, id: \.self) { palette in
                let swatches = SelectionBorderArtwork.previewSwatches(for: palette)
                let isSelected = palette == selected
                Button {
                    config.update { $0.capture.selectionBorderPalette = palette }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: swatches.0.red, green: swatches.0.green, blue: swatches.0.blue),
                                        Color(red: swatches.1.red, green: swatches.1.green, blue: swatches.1.blue),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.6))
                        Text(palette.displayName)
                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? theme.token(.foreground) : theme.token(.mutedForeground))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? theme.controlAccent.opacity(theme.isDark ? 0.18 : 0.10) : theme.fieldSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? theme.controlAccent : theme.settingsCardBorder, lineWidth: isSelected ? 1.3 : 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ title: String, _ binding: Binding<Bool>) -> some View {
        SnapSettingRow(title, theme: theme) {
            SnapToggle(isOn: binding, theme: theme)
        }
    }

    private var abbreviatedSaveDirectory: String {
        (config.settings.capture.saveDirectory as NSString).abbreviatingWithTildeInPath
    }

    private var fileNamingPreview: String {
        let capture = config.settings.capture
        let ext = capture.saveFormat == "jpeg" ? "jpg" : capture.saveFormat
        switch capture.fileNamingMode {
        case .defaultTimestamp:
            return "示例：TapSnap_2026-11-27_14-05-33.\(ext)"
        case .timestampOnly:
            return "示例：2026-11-27_14-05-33.\(ext)"
        case .customPrefixSequence:
            let prefix = capture.fileNamePrefix.isEmpty ? "TapSnap" : capture.fileNamePrefix
            return "示例：\(prefix)-001.\(ext)"
        case .sourceAppTimestamp:
            return "示例：Safari_2026-11-27_14-05-33.\(ext)"
        }
    }

    private func revealSaveDirectory() {
        let path = (config.settings.capture.saveDirectory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let expanded = (config.settings.capture.saveDirectory as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    config.update { $0.capture.saveDirectory = url.path }
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
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
    var configuration: SelectionBorderConfiguration

    func makeNSView(context: Context) -> PreviewView { PreviewView(frame: .zero) }

    func updateNSView(_ view: PreviewView, context: Context) { view.border.configuration = configuration }

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
    @ObservedObject private var pinGroups: PinGroupManager
    @State private var confirmsCloseAll = false
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
        self.pinGroups = environment.pinGroups
    }

    private var previewAppearance: PinShadowAppearance {
        PinShadowAppearance(
            settings: config.settings.pin,
            ambientPalette: PinAmbientPalette(
                left: RGBAColor(rgb: 0xfb923c, alpha: 1),
                right: RGBAColor(rgb: 0xa855f7, alpha: 1)
            )
        )
    }

    var body: some View {
        SettingsPage(section: .pin, theme: theme) {
            SnapSettingGroup("阴影与外观", theme: theme) {
                row("显示阴影", bind(\.pin.showShadow))
                if config.settings.pin.showShadow {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("阴影样式", subtitle: "在桌面贴图上右键也可快速切换", theme: theme) {
                        Picker("阴影样式", selection: bind(\.pin.shadowStyle)) {
                            ForEach(PinShadowStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 156)
                    }
                    PinShadowPreview(appearance: previewAppearance)
                        .frame(height: 122)
                        .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusSM))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("阴影浓淡", theme: theme) {
                        HStack(spacing: 8) {
                            SnapSlider(
                                value: Binding(
                                    get: { config.settings.pin.shadowIntensity },
                                    set: { value in config.update { $0.pin.shadowIntensity = value } }
                                ),
                                in: 0.5...1.6,
                                step: 0.1,
                                theme: theme,
                                width: 132,
                                onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                            )
                            Text(String(format: "%.1fx", config.settings.pin.shadowIntensity))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.token(.mutedForeground))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("扩散范围", theme: theme) {
                        HStack(spacing: 8) {
                            SnapSlider(
                                value: Binding(
                                    get: { config.settings.pin.shadowSpread },
                                    set: { value in config.update { $0.pin.shadowSpread = value } }
                                ),
                                in: 0.6...1.5,
                                step: 0.1,
                                theme: theme,
                                width: 132,
                                onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                            )
                            Text(String(format: "%.1fx", config.settings.pin.shadowSpread))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.token(.mutedForeground))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    if abs(config.settings.pin.shadowIntensity - 1.0) > 0.01
                        || abs(config.settings.pin.shadowSpread - 1.0) > 0.01 {
                        SnapRowDivider(theme: theme)
                        SnapSettingRow("阴影参数", theme: theme) {
                            SnapButton("恢复默认", theme: theme, variant: .outline, size: .sm) {
                                config.update {
                                    $0.pin.shadowIntensity = 1.0
                                    $0.pin.shadowSpread = 1.0
                                }
                            }
                        }
                    }
                }
            }

            SnapSettingGroup("行为", theme: theme) {
                row("默认置顶", bind(\.pin.alwaysOnTop))
                SnapRowDivider(theme: theme)
                row("双击关闭贴图", bind(\.pin.doubleClickToClose))
                SnapRowDivider(theme: theme)
                row("拖动时吸附屏幕边缘", bind(\.pin.snapToEdges))
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认不透明度", theme: theme) {
                    HStack(spacing: 8) {
                        SnapSlider(
                            value: Binding(
                                get: { config.settings.pin.defaultOpacity },
                                set: { value in config.update { $0.pin.defaultOpacity = value } }
                            ),
                            in: 0.1...1,
                            step: 0.05,
                            theme: theme,
                            width: 132,
                            onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                        )
                        Text("\(Int((config.settings.pin.defaultOpacity * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.token(.mutedForeground))
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }

            let openCount = pinGroups.items.count
            SnapButton(
                openCount > 0 ? "关闭所有贴图（\(openCount)）" : "关闭所有贴图",
                theme: theme,
                variant: .destructive,
                size: .md,
                isEnabled: openCount > 0
            ) {
                confirmsCloseAll = true
            }
        }
        .confirmationDialog(
            "关闭全部 \(pinGroups.items.count) 张贴图？",
            isPresented: $confirmsCloseAll,
            titleVisibility: .visible
        ) {
            Button("全部关闭", role: .destructive) {
                environment.pinGroups.closeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭后的贴图仍可在历史贴图中找回。")
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

private struct PinShadowPreview: NSViewRepresentable {
    let appearance: PinShadowAppearance

    func makeNSView(context: Context) -> Canvas { Canvas(shadowAppearance: appearance) }
    func updateNSView(_ view: Canvas, context: Context) { view.shadowAppearance = appearance }

    final class Canvas: NSView {
        var shadowAppearance: PinShadowAppearance {
            didSet { if shadowAppearance != oldValue { needsDisplay = true } }
        }

        init(shadowAppearance: PinShadowAppearance) {
            self.shadowAppearance = shadowAppearance
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
            context.setFillColor(RGBAColor(rgb: 0xf5f7fa).cgColor)
            context.fill(left)
            context.setFillColor(RGBAColor(rgb: 0x161c25).cgColor)
            context.fill(bounds.offsetBy(dx: left.width, dy: 0))

            let pinWidth = min(196, max(120, bounds.width * 0.44))
            let pinHeight = min(64, max(44, bounds.height * 0.52))
            let opening = CGRect(
                x: (bounds.width - pinWidth) / 2,
                y: (bounds.height - pinHeight) / 2 + 2,
                width: pinWidth,
                height: pinHeight
            ).integral

            PinShadowArtwork.draw(shadowAppearance, in: context, bounds: bounds, opening: opening)

            // 绘制模拟贴图卡片（左白右彩，清晰展现白贴白对比与自适应取色效果）。
            context.saveGState()
            context.clip(to: opening)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(opening)
            let banner = CGRect(x: opening.minX, y: opening.maxY - 18, width: opening.width, height: 18)
            if shadowAppearance.style == .ambilight {
                let space = CGColorSpaceCreateDeviceRGB()
                let colors = [
                    CGColor(red: 0.98, green: 0.57, blue: 0.24, alpha: 1),
                    CGColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: opening.minX, y: opening.midY),
                        end: CGPoint(x: opening.maxX, y: opening.midY),
                        options: []
                    )
                }
            } else {
                context.setFillColor(RGBAColor(rgb: 0xf1f5f9).cgColor)
                context.fill(banner)
                context.setFillColor(RGBAColor(rgb: 0x3b82f6).cgColor)
                context.fill(CGRect(x: opening.minX + 10, y: opening.maxY - 12, width: 28, height: 6))
                context.setFillColor(RGBAColor(rgb: 0x94a3b8, alpha: 0.45).cgColor)
                context.fill(CGRect(x: opening.minX + 10, y: opening.minY + 26, width: opening.width * 0.55, height: 5))
                context.fill(CGRect(x: opening.minX + 10, y: opening.minY + 14, width: opening.width * 0.72, height: 5))
            }
            context.restoreGState()
        }
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
        SettingsPage(section: .annotate, theme: theme) {
            SnapSettingGroup("工具默认值", theme: theme) {
                SnapSettingRow("默认线宽", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { config.settings.annotate.defaultLineWidth },
                                set: { value in config.update { $0.annotate.defaultLineWidth = value.rounded() } }
                            ),
                            in: 1...12,
                            step: 1,
                            theme: theme,
                            width: 150,
                            onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                        )
                        valueLabel("\(Int(config.settings.annotate.defaultLineWidth.rounded())) px")
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认字号", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { config.settings.annotate.defaultFontSize },
                                set: { value in config.update { $0.annotate.defaultFontSize = value.rounded() } }
                            ),
                            in: 10...48,
                            step: 1,
                            theme: theme,
                            width: 150,
                            onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                        )
                        valueLabel("\(Int(config.settings.annotate.defaultFontSize.rounded())) pt")
                    }
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("马赛克像素块", theme: theme) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: Binding(
                                get: { Double(config.settings.annotate.mosaicBlockSize) },
                                set: { value in config.update { $0.annotate.mosaicBlockSize = Int(value.rounded()) } }
                            ),
                            in: 4...40,
                            step: 1,
                            theme: theme,
                            width: 150,
                            onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
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
    @State private var confirmsReset = false
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
        self.center = environment.shortcutCenter
        self._recorder = StateObject(wrappedValue: ShortcutRecorder(center: environment.shortcutCenter))
    }

    var body: some View {
        SettingsPage(section: .shortcut, theme: theme) {
            bindings("全局快捷键", for: ShortcutAction.allCases.map(ShortcutRecorder.Target.global))
            bindings("框选与编辑", for: OperationShortcut.all.map(ShortcutRecorder.Target.operation))

            if recorder.action == nil, recorder.feedbackTarget == nil, let message = recorder.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.token(recorder.hasError ? .destructive : .mutedForeground))
            }
            SnapButton("恢复默认快捷键", theme: theme, variant: .outline, size: .md) {
                confirmsReset = true
            }
        }
        .onDisappear { recorder.cancel() }
        .confirmationDialog("恢复默认快捷键？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                recorder.cancel()
                config.resetShortcutsToDefaults()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有自定义的全局快捷键和操作快捷键都会恢复为初始绑定。")
        }
    }

    private func bindings(_ title: String, for actions: [ShortcutRecorder.Target]) -> some View {
        SnapSettingGroup(title, theme: theme) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0 { SnapRowDivider(theme: theme) }
                VStack(alignment: .leading, spacing: 4) {
                    SnapSettingRow(action.displayName, theme: theme) {
                        HStack(spacing: 6) {
                            if recorder.action == action {
                                ShortcutKeyCap(
                                    label: recorder.preview,
                                    isRecording: true,
                                    isUnset: false,
                                    theme: theme
                                ) {}
                                SnapButton("取消", theme: theme, variant: .outline, size: .sm) { recorder.cancel() }
                            } else {
                                let binding = action.binding(in: config)
                                ShortcutKeyCap(
                                    label: binding?.displayString ?? "点击录制",
                                    isRecording: false,
                                    isUnset: binding == nil,
                                    theme: theme
                                ) {
                                    recorder.begin(action)
                                }
                                .accessibilityLabel("录制\(action.displayName)快捷键")
                                .help(binding == nil ? "点击录制快捷键" : "点击重新录制，录制时按 Delete 可清除")
                                if binding != nil {
                                    SnapButton(theme: theme, variant: .ghost, size: .icon) {
                                        recorder.clear(action)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.token(.mutedForeground))
                                    }
                                    .accessibilityLabel("清除\(action.displayName)快捷键")
                                    .help("清除快捷键")
                                }
                            }
                        }
                    }
                    if case .global(let shortcut) = action, recorder.action != action,
                       let failure = center.registrationFailures[shortcut] {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.token(.destructive))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                    if recorder.action == action {
                        Text(recorder.message ?? "等待按键…（Esc 取消，Delete 清除）")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.token(recorder.hasError ? .destructive : .mutedForeground))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    } else if recorder.feedbackTarget == action, let message = recorder.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(recorder.hasError ? theme.token(.destructive) : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}

/// 可点击的快捷键帽：点击即进入录制，录制中带高亮描边。
private struct ShortcutKeyCap: View {
    let label: String
    let isRecording: Bool
    let isUnset: Bool
    let theme: Theme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isUnset ? .regular : .medium, design: isUnset ? .default : .rounded))
                .foregroundStyle(
                    isRecording ? theme.token(.foreground)
                    : (isUnset ? theme.token(.mutedForeground) : theme.token(.foreground))
                )
                .padding(.horizontal, 10)
                .frame(minWidth: 64, minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isRecording ? theme.controlAccent.opacity(theme.isDark ? 0.22 : 0.12)
                            : (isHovering ? theme.fieldSurface.opacity(1.6) : theme.fieldSurface)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRecording ? theme.controlAccent : (isHovering ? theme.controlAccent.opacity(0.5) : theme.settingsCardBorder),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                }
        }
        .buttonStyle(SnapPressStyle(scale: 0.97))
        .onHoverChange { isHovering = $0 }
    }
}

// MARK: - 关于

private struct AboutSettings: View {
    let environment: AppEnvironment
    private var theme: Theme { environment.theme }

    var body: some View {
        SettingsPage(section: .about, theme: theme) {
            SnapSettingGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        if let icon = NSApp.applicationIconImage {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.14), radius: 6, y: 2)
                        } else {
                            SettingsIconBadge(section: .capture, size: 48)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(AppInfo.displayName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(theme.token(.foreground))
                                if AppPaths.isDevelopmentBuild {
                                    Text("开发版")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(theme.controlAccent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(theme.controlAccent.opacity(0.14), in: Capsule())
                                }
                            }
                            Text("版本 \(AppInfo.version)（Build \(AppInfo.build)）")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(theme.token(.mutedForeground))
                            Text("为 macOS 打造的截图、标注、贴图、长截图、录屏与截图秒译工具")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.token(.mutedForeground))
                                .padding(.top, 2)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        SnapButton("打开使用指南", theme: theme, variant: .primary, size: .sm) {
                            environment.tutorial.show()
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - 录屏

private struct RecordSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    @State private var cameraStatus: PermissionStatus = .notDetermined
    @State private var microphoneStatus: PermissionStatus = .notDetermined
    @State private var screenStatus: PermissionStatus = .notDetermined
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(section: .record, theme: theme) {
            SnapSettingGroup("画面", theme: theme) {
                SnapSettingRow("帧率", subtitle: "码率固定 8 Mbps，H.264 硬件编码", theme: theme) {
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
                SnapSettingRow("包含光标", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.record.includesCursor },
                            set: { value in config.update { $0.record.includesCursor = value } }
                        ),
                        theme: theme
                    )
                }
            }

            SnapSettingGroup("演示与鼠标动效", theme: theme) {
                permissionToggleRow(
                    "摄像头画中画",
                    keyPath: \.record.includesCamera,
                    permission: .camera,
                    status: cameraStatus
                )
                SnapRowDivider(theme: theme)
                recordingToggle("显示快捷键", keyPath: \.record.showsKeyPresses)
                SnapRowDivider(theme: theme)
                recordingToggle("显示鼠标点击", keyPath: \.record.showsMouseClicks)
                if config.settings.record.showsMouseClicks {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("点击动效样式", theme: theme) {
                        Picker("点击动效样式", selection: Binding(
                            get: { config.settings.record.mouseClickStyle },
                            set: { value in config.update { $0.record.mouseClickStyle = value } }
                        )) {
                            ForEach(RecordingMouseClickStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 152)
                    }
                    .padding(.leading, 12)
                }
                SnapRowDivider(theme: theme)
                recordingToggle("显示滚轮滑动", keyPath: \.record.showsMouseScrolls)
                if config.settings.record.showsMouseScrolls {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("滚轮动效样式", theme: theme) {
                        Picker("滚轮动效样式", selection: Binding(
                            get: { config.settings.record.mouseScrollStyle },
                            set: { value in config.update { $0.record.mouseScrollStyle = value } }
                        )) {
                            ForEach(RecordingMouseScrollStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 152)
                    }
                    .padding(.leading, 12)
                }
                if config.settings.record.showsMouseClicks || config.settings.record.showsMouseScrolls {
                    SnapRowDivider(theme: theme)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("动效配色")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.token(.foreground))
                            Spacer()
                            Text(config.settings.record.mouseEffectPalette.displayName)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.token(.mutedForeground))
                        }
                        mousePaletteSwatchStrip
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("动效尺寸", theme: theme) {
                        HStack(spacing: 8) {
                            SnapSlider(
                                value: Binding(
                                    get: { config.settings.record.mouseEffectScale },
                                    set: { value in config.update { $0.record.mouseEffectScale = value } }
                                ),
                                in: 0.75...1.45,
                                step: 0.05,
                                theme: theme,
                                width: 132,
                                onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                            )
                            Text(String(format: "%.2fx", config.settings.record.mouseEffectScale))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.token(.mutedForeground))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    ZStack(alignment: .bottomLeading) {
                        RecordingMouseEffectsPreview(
                            showsClicks: config.settings.record.showsMouseClicks,
                            showsScrolls: config.settings.record.showsMouseScrolls,
                            clickStyle: config.settings.record.mouseClickStyle,
                            scrollStyle: config.settings.record.mouseScrollStyle,
                            palette: config.settings.record.mouseEffectPalette,
                            scale: config.settings.record.mouseEffectScale
                        )
                        Text("点击或滚动预览区可试看效果")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.42), in: Capsule())
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .frame(height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusSM))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }

            SnapSettingGroup("声音", theme: theme) {
                permissionToggleRow(
                    "录制系统声音",
                    keyPath: \.record.includesSystemAudio,
                    permission: .screenCapture,
                    status: screenStatus
                )
                SnapRowDivider(theme: theme)
                permissionToggleRow(
                    "录制麦克风",
                    keyPath: \.record.includesMicrophone,
                    permission: .microphone,
                    status: microphoneStatus
                )
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        cameraStatus = Permissions.status(of: .camera)
        microphoneStatus = Permissions.status(of: .microphone)
        screenStatus = Permissions.status(of: .screenCapture)
    }

    private func permissionToggleRow(
        _ title: String,
        keyPath: WritableKeyPath<TapSnapConfig.Settings, Bool>,
        permission: SystemPermission,
        status: PermissionStatus
    ) -> some View {
        let isOn = config.settings[keyPath: keyPath]
        let needsGrant = isOn && status != .authorized
        return SnapSettingRow(
            title,
            subtitle: needsGrant ? "缺少\(permission.displayName)权限，开始录屏时将无法生效" : nil,
            theme: theme
        ) {
            HStack(spacing: 8) {
                if needsGrant {
                    SnapButton(status == .notDetermined ? "申请权限" : "去授权", theme: theme, variant: .outline, size: .sm) {
                        requestOrOpenPermission(permission, status: status)
                    }
                }
                SnapToggle(
                    isOn: Binding(
                        get: { config.settings[keyPath: keyPath] },
                        set: { value in config.update { $0[keyPath: keyPath] = value } }
                    ),
                    theme: theme
                )
            }
        }
    }

    private func requestOrOpenPermission(_ permission: SystemPermission, status: PermissionStatus) {
        if status == .notDetermined {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Permissions.request(permission)
                DispatchQueue.main.async { refreshPermissions() }
            }
        } else {
            Permissions.openSettingsPanel(for: permission)
        }
    }
    private var mousePaletteSwatchStrip: some View {
        let selected = config.settings.record.mouseEffectPalette
        let columns = [GridItem(.adaptive(minimum: 84), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(RecordingMouseEffectPalette.allCases, id: \.self) { palette in
                let colors = RecordingMouseEffectsArtwork.paletteColors(for: palette)
                let isSelected = palette == selected
                Button {
                    config.update { $0.record.mouseEffectPalette = palette }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: colors.left.red, green: colors.left.green, blue: colors.left.blue),
                                        Color(red: colors.right.red, green: colors.right.green, blue: colors.right.blue),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.6))
                        Text(palette.displayName)
                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? theme.token(.foreground) : theme.token(.mutedForeground))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? theme.controlAccent.opacity(theme.isDark ? 0.18 : 0.10) : theme.fieldSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? theme.controlAccent : theme.settingsCardBorder, lineWidth: isSelected ? 1.3 : 0.8)
                    )
                }
                .buttonStyle(.plain)
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

private struct RecordingMouseEffectsPreview: NSViewRepresentable {
    var showsClicks: Bool
    var showsScrolls: Bool
    var clickStyle: RecordingMouseClickStyle
    var scrollStyle: RecordingMouseScrollStyle
    var palette: RecordingMouseEffectPalette
    var scale: Double

    func makeNSView(context: Context) -> PreviewView { PreviewView(frame: .zero) }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.showsClicks = showsClicks
        view.showsScrolls = showsScrolls
        view.clickStyle = clickStyle
        view.scrollStyle = scrollStyle
        view.palette = palette
        view.effectScale = scale
    }

    final class PreviewView: NSView {
        var showsClicks = true
        var showsScrolls = true
        var clickStyle: RecordingMouseClickStyle = .liquidRipple
        var scrollStyle: RecordingMouseScrollStyle = .glassPill
        var palette: RecordingMouseEffectPalette = .glassBlue
        var effectScale: Double = 1.0

        private struct LiveClick {
            var point: CGPoint
            var born: TimeInterval
            var button: RecordingClickEffect.Button
            var clickCount: Int
        }

        private var timer: Timer?
        private var startTime = ProcessInfo.processInfo.systemUptime
        private var liveClicks: [LiveClick] = []
        private var liveScroll: (point: CGPoint, direction: Double, accumulated: Double, lastTime: TimeInterval)?
        private var lastLeftTap: TimeInterval = -10

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard window != nil else { return }
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        deinit { timer?.invalidate() }

        override func mouseDown(with event: NSEvent) {
            guard showsClicks else { return }
            let pt = convert(event.locationInWindow, from: nil)
            let now = ProcessInfo.processInfo.systemUptime
            let isDouble = now - lastLeftTap < 0.30
            lastLeftTap = now
            liveClicks.append(.init(point: pt, born: now, button: .left, clickCount: isDouble ? 2 : 1))
            needsDisplay = true
        }

        override func rightMouseDown(with event: NSEvent) {
            guard showsClicks else { return }
            let pt = convert(event.locationInWindow, from: nil)
            let now = ProcessInfo.processInfo.systemUptime
            liveClicks.append(.init(point: pt, born: now, button: .right, clickCount: 1))
            needsDisplay = true
        }

        override func scrollWheel(with event: NSEvent) {
            guard showsScrolls else { super.scrollWheel(with: event); return }
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(delta) > 0.01 else { return }
            let pt = convert(event.locationInWindow, from: nil)
            let now = ProcessInfo.processInfo.systemUptime
            let dir: Double = delta < 0 ? 1 : -1
            let prev = liveScroll?.accumulated ?? 0
            liveScroll = (pt, dir, prev - delta, now)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
            ctx.setFillColor(RGBAColor(rgb: 0xf5f7fa).cgColor)
            ctx.fill(left)
            ctx.setFillColor(RGBAColor(rgb: 0x161c25).cgColor)
            ctx.fill(bounds.offsetBy(dx: left.width, dy: 0))

            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startTime
            let unit = CGFloat(effectScale)

            // 清理已结束的手动点击，并绘制手动触发的动效；无手动交互时自动轮播演示。
            liveClicks.removeAll { now - $0.born > 0.65 }
            let hasManualClick = !liveClicks.isEmpty
            let hasManualScroll = liveScroll.map { now - $0.lastTime < 0.55 } ?? false

            if showsClicks {
                if hasManualClick {
                    for item in liveClicks {
                        RecordingMouseEffectsArtwork.drawClick(
                            style: clickStyle,
                            at: item.point,
                            progress: (now - item.born) / 0.62,
                            button: item.button,
                            clickCount: item.clickCount,
                            palette: palette,
                            unit: unit,
                            in: ctx
                        )
                    }
                } else {
                    let period = 1.45
                    let cycle = elapsed.truncatingRemainder(dividingBy: period * 2)
                    let isRight = cycle >= period
                    let u = cycle.truncatingRemainder(dividingBy: period) / 0.68
                    let pt = CGPoint(x: bounds.width * (isRight ? 0.68 : 0.28), y: bounds.midY)
                    if u <= 1 {
                        RecordingMouseEffectsArtwork.drawClick(
                            style: clickStyle,
                            at: pt,
                            progress: u,
                            button: isRight ? .right : .left,
                            clickCount: 1,
                            palette: palette,
                            unit: unit,
                            in: ctx
                        )
                    }
                }
            }

            if showsScrolls {
                if let scroll = liveScroll, hasManualScroll {
                    let age = now - scroll.lastTime
                    let alpha = age < 0.24 ? 1.0 : max(0, 1 - (age - 0.24) / 0.30)
                    RecordingMouseEffectsArtwork.drawScroll(
                        style: scrollStyle,
                        at: scroll.point,
                        alpha: alpha,
                        direction: scroll.direction,
                        accumulated: scroll.accumulated,
                        time: elapsed,
                        palette: palette,
                        unit: unit,
                        in: ctx
                    )
                } else {
                    let dir: Double = elapsed.truncatingRemainder(dividingBy: 3.6) < 1.8 ? 1 : -1
                    let pt = CGPoint(x: bounds.width * (showsClicks ? 0.46 : 0.50), y: bounds.midY)
                    RecordingMouseEffectsArtwork.drawScroll(
                        style: scrollStyle,
                        at: pt,
                        alpha: 0.96,
                        direction: dir,
                        accumulated: elapsed * 38 * dir,
                        time: elapsed,
                        palette: palette,
                        unit: unit,
                        in: ctx
                    )
                }
            }
        }
    }
}

private struct LongShotSettings: View {
    let environment: AppEnvironment
    @ObservedObject private var config: ConfigStore
    private var theme: Theme { environment.theme }

    private enum ScrollPreset: String, CaseIterable, Hashable {
        case slow, standard, fast, custom

        var title: String {
            switch self {
            case .slow: return "慢速"
            case .standard: return "标准"
            case .fast: return "快速"
            case .custom: return "自定义"
            }
        }

        var values: (step: Int, intervalMs: Int)? {
            switch self {
            case .slow: return (140, 700)
            case .standard: return (200, 500)
            case .fast: return (360, 350)
            case .custom: return nil
            }
        }

        static func matching(step: Int, intervalMs: Int) -> ScrollPreset {
            for preset in [ScrollPreset.slow, .standard, .fast] {
                if let pair = preset.values, pair.step == step, pair.intervalMs == intervalMs {
                    return preset
                }
            }
            return .custom
        }
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
    }

    var body: some View {
        SettingsPage(section: .longShot, theme: theme) {
            SnapSettingGroup("自动滚动", theme: theme) {
                SnapSettingRow(
                    "选区就绪后自动滚动",
                    subtitle: "关闭后需手动滚动页面完成拼接",
                    theme: theme
                ) {
                    SnapToggle(isOn: bind(\.longShot.autoScroll), theme: theme)
                }
                if config.settings.longShot.autoScroll {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("滚动速度预设", theme: theme) {
                        SnapSegmented(
                            items: [ScrollPreset.slow, .standard, .fast],
                            selection: Binding(
                                get: {
                                    ScrollPreset.matching(
                                        step: config.settings.longShot.scrollStep,
                                        intervalMs: config.settings.longShot.scrollIntervalMs
                                    )
                                },
                                set: { preset in
                                    guard let values = preset.values else { return }
                                    config.update {
                                        $0.longShot.scrollStep = values.step
                                        $0.longShot.scrollIntervalMs = values.intervalMs
                                    }
                                }
                            ),
                            theme: theme,
                            title: \.title
                        )
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("每次滚动距离", theme: theme) {
                        HStack(spacing: 10) {
                            SnapSlider(
                                value: Binding(
                                    get: { Double(config.settings.longShot.scrollStep) },
                                    set: { value in config.update { $0.longShot.scrollStep = Int(value.rounded()) } }
                                ),
                                in: 20...800,
                                step: 20,
                                theme: theme,
                                width: 150,
                                onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                            )
                            valueLabel("\(config.settings.longShot.scrollStep) pt")
                        }
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("滚动间隔", theme: theme) {
                        HStack(spacing: 10) {
                            SnapSlider(
                                value: Binding(
                                    get: { Double(config.settings.longShot.scrollIntervalMs) },
                                    set: { value in config.update { $0.longShot.scrollIntervalMs = Int(value.rounded()) } }
                                ),
                                in: 300...3000,
                                step: 100,
                                theme: theme,
                                width: 150,
                                onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                            )
                            valueLabel("\(config.settings.longShot.scrollIntervalMs) ms")
                        }
                    }
                }
            }

            SnapSettingGroup("拼接", theme: theme) {
                SnapSettingRow(
                    "保留重叠比例",
                    subtitle: "重叠比例越高拼接越稳，但总滚动次数会增加",
                    theme: theme
                ) {
                    HStack(spacing: 10) {
                        SnapSlider(
                            value: bind(\.longShot.overlapRatio),
                            in: 0.35...0.85,
                            step: 0.05,
                            theme: theme,
                            width: 150,
                            onEditingChanged: { $0 ? config.beginContinuousChange() : config.endContinuousChange() }
                        )
                        valueLabel("\(Int((config.settings.longShot.overlapRatio * 100).rounded()))%")
                    }
                }
            }
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(theme.token(.mutedForeground))
            .frame(width: 54, alignment: .trailing)
    }

    private func bind<T>(_ keyPath: WritableKeyPath<TapSnapConfig.Settings, T>) -> Binding<T> {
        Binding(get: { config.settings[keyPath: keyPath] }, set: { value in config.update { $0[keyPath: keyPath] = value } })
    }
}
