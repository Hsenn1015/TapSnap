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
        case .translation:
            SettingsPage(title: "截图翻译", theme: theme) {
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

// MARK: - 侧边栏条目

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, capture, translation, privacy, pin, annotate, record, longShot, shortcut, about

    var id: String { rawValue }

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
                SnapSettingRow("演示模式（允许录屏）", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.capture.allowSelfCapture },
                            set: { value in config.update { $0.capture.allowSelfCapture = value } }
                        ),
                        theme: theme
                    )
                }
                .help("开启后允许系统截屏、录屏软件或双开 TapSnap 捕获本应用的选区、贴图与工具栏")
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
                SnapSettingRow("主题配色", theme: theme) {
                    Picker("主题配色", selection: bind(\.capture.selectionBorderPalette)) {
                        ForEach(config.settings.capture.selectionBorderStyle.availablePalettes, id: \.self) { palette in
                            Text(palette.displayName).tag(palette)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 152)
                }
                borderPaletteSwatchStrip
                    .padding(.horizontal, 14)
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
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? theme.token(.secondary) : theme.token(.background).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? theme.token(.primary) : theme.token(.border), lineWidth: isSelected ? 1.2 : 0.8)
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
    private var theme: Theme { environment.theme }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
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
        SettingsPage(title: "贴图", theme: theme) {
            SnapSettingGroup("阴影与外观", theme: theme) {
                row("显示阴影", bind(\.pin.showShadow))
                if config.settings.pin.showShadow {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("阴影样式", theme: theme) {
                        Picker("阴影样式", selection: bind(\.pin.shadowStyle)) {
                            ForEach(PinShadowStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 156)
                    }
                    .help("在桌面贴图上右键也可快速切换")
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
                                theme: theme,
                                width: 132
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
                                theme: theme,
                                width: 132
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
                            Text(AppInfo.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.token(.foreground))
                            Text("版本 \(AppInfo.version) (\(AppInfo.build))")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.token(.mutedForeground))
                        }
                        Spacer()
                    }
                    Text("截图、标注、贴图与录屏工具")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
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
                SnapSettingRow("帧率", theme: theme) {
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
                .help("码率固定 8 Mbps，H.264 硬编")
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
                recordingToggle("摄像头画中画", keyPath: \.record.includesCamera)
                SnapRowDivider(theme: theme)
                recordingToggle("显示快捷键", keyPath: \.record.showsKeyPresses)
                SnapRowDivider(theme: theme)
                recordingToggle("显示鼠标点击", keyPath: \.record.showsMouseClicks)
                SnapRowDivider(theme: theme)
                recordingToggle("显示滚轮滑动", keyPath: \.record.showsMouseScrolls)
                if config.settings.record.showsMouseClicks || config.settings.record.showsMouseScrolls {
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
                    }
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
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("动效配色", theme: theme) {
                        Picker("动效配色", selection: Binding(
                            get: { config.settings.record.mouseEffectPalette },
                            set: { value in config.update { $0.record.mouseEffectPalette = value } }
                        )) {
                            ForEach(RecordingMouseEffectPalette.allCases, id: \.self) { palette in
                                Text(palette.displayName).tag(palette)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 152)
                    }
                    mousePaletteSwatchStrip
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("动效尺寸", theme: theme) {
                        HStack(spacing: 8) {
                            SnapSlider(
                                value: Binding(
                                    get: { config.settings.record.mouseEffectScale },
                                    set: { value in config.update { $0.record.mouseEffectScale = value } }
                                ),
                                in: 0.75...1.45,
                                theme: theme,
                                width: 132
                            )
                            Text(String(format: "%.1fx", config.settings.record.mouseEffectScale))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.token(.mutedForeground))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    RecordingMouseEffectsPreview(
                        showsClicks: config.settings.record.showsMouseClicks,
                        showsScrolls: config.settings.record.showsMouseScrolls,
                        clickStyle: config.settings.record.mouseClickStyle,
                        scrollStyle: config.settings.record.mouseScrollStyle,
                        palette: config.settings.record.mouseEffectPalette,
                        scale: config.settings.record.mouseEffectScale
                    )
                    .frame(height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: theme.metrics.radiusSM))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .help("可在预览区内直接左键、右键、双击或滚轮试看效果")
                }
            }

            SnapSettingGroup("声音", theme: theme) {
                SnapSettingRow("录制系统声音", theme: theme) {
                    SnapToggle(
                        isOn: Binding(
                            get: { config.settings.record.includesSystemAudio },
                            set: { value in config.update { $0.record.includesSystemAudio = value } }
                        ),
                        theme: theme
                    )
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("录制麦克风", theme: theme) {
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
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? theme.token(.secondary) : theme.token(.background).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? theme.token(.primary) : theme.token(.border), lineWidth: isSelected ? 1.2 : 0.8)
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
    init(environment: AppEnvironment) { self.environment = environment; config = environment.config }
    var body: some View {
        SettingsPage(title: "长截图", theme: theme) {
            Toggle("选区就绪后自动滚动", isOn: bind(\.longShot.autoScroll))
            Stepper("每次滚动 \(config.settings.longShot.scrollStep) 点", value: bind(\.longShot.scrollStep), in: 20...800, step: 20)
            Stepper("滚动间隔 \(config.settings.longShot.scrollIntervalMs) 毫秒", value: bind(\.longShot.scrollIntervalMs), in: 300...3000, step: 100)
            HStack {
                Text("保留重叠 \(Int(config.settings.longShot.overlapRatio * 100))%")
                Slider(value: bind(\.longShot.overlapRatio), in: 0.35...0.85, step: 0.05)
            }
        }
    }
    private func bind<T>(_ keyPath: WritableKeyPath<TapSnapConfig.Settings, T>) -> Binding<T> {
        Binding(get: { config.settings[keyPath: keyPath] }, set: { value in config.update { $0[keyPath: keyPath] = value } })
    }
}
