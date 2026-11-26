import AppKit
import SwiftUI
import TapSnapConfig
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI

struct TranslationServiceSettingsView: View {
    @ObservedObject private var config: ConfigStore
    private let theme: Theme
    private let compact: Bool
    private let onCancel: (() -> Void)?
    private let onSave: (_ settingsChanged: Bool) -> Void
    @State private var draft: ScreenshotTranslationSettings
    @State private var key = ""
    @State private var savedKeySnapshot = ""
    @State private var revealsKey = false
    @State private var keyCopied = false
    @State private var status = ""
    @State private var statusIsError = false
    @State private var trial: Task<Void, Never>?
    @State private var confirmsRemoveKey = false
    @FocusState private var isKeyFocused: Bool

    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("fr", "法语"),
        ("de", "德语"),
        ("es", "西班牙语"),
    ]

    init(
        config: ConfigStore,
        theme: Theme = .dark,
        compact: Bool = false,
        onCancel: (() -> Void)? = nil,
        onSave: @escaping (Bool) -> Void = { _ in }
    ) {
        self.config = config
        self.theme = theme
        self.compact = compact
        self.onCancel = onCancel
        self.onSave = onSave
        var initial = config.settings.translation
        if #available(macOS 15, *) {
            if initial.provider == nil { initial.provider = .apple }
        } else if initial.provider == nil || initial.provider == .apple {
            initial.provider = .api
        }
        _draft = State(initialValue: initial)
    }

    private var availableProviders: [ScreenshotTranslationProvider] {
        if #available(macOS 15, *) {
            return [.apple, .api, .local, .online]
        }
        return [.api, .local, .online]
    }

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                settingsPageBody
            }
        }
        .onAppear { loadSavedKey() }
        .onDisappear { clearTrial() }
        .confirmationDialog("移除已保存的翻译密钥？", isPresented: $confirmsRemoveKey, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) {
                if let api = draft.apiConfiguration {
                    removeSavedAPIKey(for: api)
                } else if let model = draft.modelConfiguration {
                    removeSavedModelKey(for: model)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后需要重新填写密钥才能继续使用该翻译服务。")
        }
    }

    /// 设置页中非即时项（服务商、凭据、端点等）是否有尚未保存的改动。
    private var hasUnsavedServiceChanges: Bool {
        let saved = config.settings.translation
        if draft.provider != saved.provider { return true }
        switch draft.provider {
        case .apple, nil:
            return false
        case .api:
            return draft.apiProvider != saved.apiProvider
                || draft.apiConfiguration != saved.apiConfiguration
                || key != savedKeySnapshot
        case .local:
            return draft.modelConfiguration != saved.modelConfiguration
                || key != savedKeySnapshot
        case .online:
            return draft.onlineProvider != saved.onlineProvider
                || draft.modelConfiguration != saved.modelConfiguration
                || key != savedKeySnapshot
        }
    }

    // MARK: - 设置页完整布局

    private var settingsPageBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            SnapSettingGroup("翻译引擎", theme: theme) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("翻译服务")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.token(.foreground))
                        Spacer(minLength: 8)
                        Text(serviceSummary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.token(.mutedForeground))
                            .lineLimit(1)
                    }
                    providerSegmented
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认目标语言", theme: theme) {
                    Picker(
                        "默认目标语言",
                        selection: Binding(
                            get: { draft.targetLanguage },
                            set: { newValue in
                                draft.targetLanguage = newValue
                                config.update { $0.translation.targetLanguage = newValue }
                            }
                        )
                    ) {
                        ForEach(Self.supportedLanguages, id: \.code) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 126)
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow(
                    "打开后自动翻译",
                    subtitle: "关闭后先展示本机 OCR 原文，可勾选段落后再翻译",
                    theme: theme
                ) {
                    SnapToggle(
                        isOn: Binding(
                            get: { draft.autoTranslateOnOpen },
                            set: { newValue in
                                draft.autoTranslateOnOpen = newValue
                                config.update { $0.translation.autoTranslateOnOpen = newValue }
                            }
                        ),
                        theme: theme
                    )
                }
            }

            quickTranslateStyleGroup

            if let api = draft.apiConfiguration {
                apiSettingsGroup(api)
            } else if let model = draft.modelConfiguration {
                modelSettingsGroup(model)
            } else {
                appleSettingsGroup
            }
        }
    }

    private var quickTranslateStyleGroup: some View {
        let secondaryStyles = QuickTranslateStyle.allCases.filter { $0 != .cleanCard }
        return SnapSettingGroup("截图秒译样式", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                quickTranslateStyleCard(for: .cleanCard, badge: "推荐")

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(secondaryStyles, id: \.self) { style in
                        quickTranslateStyleCard(for: style, badge: nil)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func quickTranslateStyleCard(for style: QuickTranslateStyle, badge: String?) -> some View {
        let selected = draft.quickTranslateStyle == style
        return Button {
            draft.quickTranslateStyle = style
            config.update { $0.translation.quickTranslateStyle = style }
        } label: {
            HStack(spacing: 7) {
                quickTranslateStyleAccentDot(for: style)
                Text(style.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(theme.token(.foreground))
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.controlAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(theme.controlAccent.opacity(theme.isDark ? 0.20 : 0.12), in: Capsule())
                }
                Spacer(minLength: 2)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.controlAccent)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? theme.controlAccent.opacity(theme.isDark ? 0.18 : 0.10) : theme.fieldSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? theme.controlAccent : theme.settingsCardBorder,
                        lineWidth: selected ? 1.3 : 0.9
                    )
            )
        }
        .buttonStyle(.plain)
        .help(style.summary)
    }

    @ViewBuilder
    private func quickTranslateStyleAccentDot(for style: QuickTranslateStyle) -> some View {
        let colors: [Color] = switch style {
        case .cleanCard:
            [Color(red: 0.04, green: 0.48, blue: 1.0), Color(red: 0.24, green: 0.56, blue: 1.0)]
        case .liquidGlass:
            [Color(red: 0.20, green: 0.70, blue: 0.96), Color(red: 0.42, green: 0.40, blue: 0.96)]
        case .editorial:
            [Color(red: 0.34, green: 0.68, blue: 0.98), Color(red: 0.39, green: 0.40, blue: 0.94)]
        case .inlineBilingual:
            [Color(red: 0.96, green: 0.70, blue: 0.22), Color(red: 0.92, green: 0.54, blue: 0.18)]
        case .dynamicBubble:
            [Color(red: 0.18, green: 0.78, blue: 0.58), Color(red: 0.20, green: 0.68, blue: 0.92)]
        }
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 9, height: 9)
    }

    private func apiSettingsGroup(_ api: TranslationAPIConfiguration) -> some View {
        SnapSettingGroup("第三方翻译 API", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                SnapSettingRow("翻译引擎", theme: theme) {
                    Picker("翻译引擎", selection: apiProviderBinding) {
                        ForEach(TranslationAPIProvider.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                .help(api.provider.hint)
                SnapRowDivider(theme: theme)

                if api.provider.requiresAppID {
                    SnapSettingRow(api.provider.appIDLabel, theme: theme) {
                        SnapTextField(
                            text: apiField(\.appID),
                            theme: theme,
                            placeholder: "填写 \(api.provider.appIDLabel)",
                            width: 280,
                            monospaced: true
                        )
                        .accessibilityLabel(api.provider.appIDLabel)
                    }
                    SnapRowDivider(theme: theme)
                }

                SnapSettingRow(api.provider.secretLabel, theme: theme) {
                    secureField(
                        placeholder: api.provider.requiresSecret ? "输入密钥" : "可选（留空免密）",
                        width: 280
                    )
                }

                if api.provider.supportsRegion {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("服务区域", theme: theme) {
                        SnapTextField(
                            text: apiField(\.region),
                            theme: theme,
                            placeholder: api.provider.regionPlaceholder,
                            width: 280,
                            monospaced: true
                        )
                    }
                }

                if api.provider.supportsCustomEndpoint {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("自定义端点", theme: theme) {
                        SnapTextField(
                            text: apiField(\.customBaseURL),
                            theme: theme,
                            placeholder: api.provider.endpointPlaceholder,
                            width: 280,
                            monospaced: true
                        )
                    }
                }

                SnapRowDivider(theme: theme)

                VStack(alignment: .leading, spacing: 10) {
                    if !status.isEmpty {
                        statusBanner
                    }

                    HStack(spacing: 8) {
                        SnapButton(theme: theme, variant: .outline, size: .sm, isEnabled: canSave && trial == nil) {
                            testAPI(api)
                        } label: {
                            HStack(spacing: 5) {
                                if trial != nil { ProgressView().controlSize(.mini) }
                                Text(trial != nil ? "试译中…" : "试译 Hello")
                            }
                        }
                        .help("使用示例文字 Hello 测试速度与连通性")

                        SnapButton(
                            "移除已存密钥",
                            theme: theme,
                            variant: .ghost,
                            size: .sm,
                            isEnabled: !savedKeySnapshot.isEmpty && trial == nil
                        ) {
                            confirmsRemoveKey = true
                        }

                        Spacer()

                        if hasUnsavedServiceChanges {
                            Text("未保存")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }

                        SnapButton(
                            "保存翻译服务",
                            theme: theme,
                            variant: .primary,
                            size: .sm,
                            isEnabled: canSave && hasUnsavedServiceChanges && trial == nil,
                            action: save
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func modelSettingsGroup(_ model: PrivacyAIConfiguration) -> some View {
        SnapSettingGroup(draft.provider == .local ? "本机模型连接" : "在线模型连接", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                if draft.provider == .online {
                    SnapSettingRow("服务商", theme: theme) {
                        Picker("服务商", selection: onlineProviderBinding) {
                            ForEach([PrivacyAIProvider.deepSeek, .qwen, .custom], id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 168)
                    }
                    SnapRowDivider(theme: theme)
                }

                SnapSettingRow("服务地址", theme: theme) {
                    SnapTextField(
                        text: modelField(\.baseURL),
                        theme: theme,
                        placeholder: "https://…/v1",
                        width: 280,
                        monospaced: true
                    )
                    .accessibilityLabel("翻译服务地址")
                }
                SnapRowDivider(theme: theme)

                SnapSettingRow("模型名称", theme: theme) {
                    SnapTextField(
                        text: modelField(\.model),
                        theme: theme,
                        placeholder: "已启用的模型名称",
                        width: 280,
                        monospaced: true
                    )
                    .accessibilityLabel("翻译模型名称")
                }
                SnapRowDivider(theme: theme)

                SnapSettingRow("API Key", theme: theme) {
                    secureField(placeholder: "输入 API Key", width: 280)
                }
                SnapRowDivider(theme: theme)

                VStack(alignment: .leading, spacing: 10) {
                    if !status.isEmpty {
                        statusBanner
                    }

                    HStack(spacing: 8) {
                        SnapButton(theme: theme, variant: .outline, size: .sm, isEnabled: canSave && trial == nil) {
                            testModel(model)
                        } label: {
                            HStack(spacing: 5) {
                                if trial != nil { ProgressView().controlSize(.mini) }
                                Text(trial != nil ? "试译中…" : "试译 Hello")
                            }
                        }
                        .help("使用示例文字 Hello 测试，不读取截图")

                        SnapButton(
                            "移除已存密钥",
                            theme: theme,
                            variant: .ghost,
                            size: .sm,
                            isEnabled: model.endpoint != nil && !savedKeySnapshot.isEmpty && trial == nil
                        ) {
                            confirmsRemoveKey = true
                        }

                        Spacer()

                        if hasUnsavedServiceChanges {
                            Text("未保存")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }

                        SnapButton(
                            "保存翻译服务",
                            theme: theme,
                            variant: .primary,
                            size: .sm,
                            isEnabled: canSave && hasUnsavedServiceChanges && trial == nil,
                            action: save
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var appleSettingsGroup: some View {
        SnapSettingGroup("Apple 设备端翻译", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                if !status.isEmpty {
                    statusBanner
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.green)
                    Text("已生效 · 本机离线运行，无需密钥")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
                    Spacer()
                }
            }
            .padding(14)
        }
    }

    // MARK: - 翻译窗口 Popover 紧凑布局

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("翻译服务")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                Spacer()
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.token(.mutedForeground))
                            .frame(width: 22, height: 22)
                            .background(theme.token(.muted), in: Circle())
                    }
                    .buttonStyle(SnapPressStyle(scale: 0.92))
                    .help("关闭")
                }
            }

            providerSegmented
                .frame(maxWidth: .infinity, alignment: .leading)

            if let api = draft.apiConfiguration {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("引擎")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.token(.mutedForeground))
                        Spacer()
                        Picker("翻译引擎", selection: apiProviderBinding) {
                            ForEach(TranslationAPIProvider.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    if api.provider.requiresAppID {
                        compactFieldRow(api.provider.appIDLabel) {
                            SnapTextField(text: apiField(\.appID), theme: theme, placeholder: "填写 \(api.provider.appIDLabel)", width: 220, monospaced: true)
                        }
                    }

                    compactFieldRow(api.provider == .google ? "Key" : "密钥") {
                        secureField(
                            placeholder: api.provider.requiresSecret ? "留空沿用已保存密钥" : "可选，留空走免密通道",
                            width: 220
                        )
                    }

                    if api.provider.supportsRegion {
                        compactFieldRow("区域") {
                            SnapTextField(text: apiField(\.region), theme: theme, placeholder: api.provider.regionPlaceholder, width: 220, monospaced: true)
                        }
                    }

                    if api.provider.supportsCustomEndpoint {
                        compactFieldRow("端点") {
                            SnapTextField(text: apiField(\.customBaseURL), theme: theme, placeholder: api.provider.endpointPlaceholder, width: 220, monospaced: true)
                        }
                    }
                }
                .padding(10)
                .background(theme.token(.muted).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if draft.modelConfiguration != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if draft.provider == .online {
                        HStack {
                            Text("服务商")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(theme.token(.mutedForeground))
                            Spacer()
                            Picker("服务商", selection: onlineProviderBinding) {
                                ForEach([PrivacyAIProvider.deepSeek, .qwen, .custom], id: \.self) {
                                    Text($0.title).tag($0)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }

                    compactFieldRow("地址") {
                        SnapTextField(text: modelField(\.baseURL), theme: theme, placeholder: "https://…/v1", width: 220, monospaced: true)
                            .accessibilityLabel("翻译服务地址")
                    }
                    compactFieldRow("模型") {
                        SnapTextField(text: modelField(\.model), theme: theme, placeholder: "已启用的模型名称", width: 220, monospaced: true)
                            .accessibilityLabel("翻译模型名称")
                    }
                    compactFieldRow("Key") {
                        secureField(placeholder: "留空沿用已保存密钥", width: 220)
                    }
                }
                .padding(10)
                .background(theme.token(.muted).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.primary))
                    Text("本机离线运行，无需密钥")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.token(.muted).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !status.isEmpty {
                statusBanner
            }

            HStack(spacing: 8) {
                Text("打开后自动翻译")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.token(.foreground))
                Spacer()
                SnapToggle(
                    isOn: Binding(
                        get: { draft.autoTranslateOnOpen },
                        set: { newValue in
                            draft.autoTranslateOnOpen = newValue
                            config.update { $0.translation.autoTranslateOnOpen = newValue }
                        }
                    ),
                    theme: theme
                )
            }
            .help("关闭后先展示本机 OCR 原文，方便清理杂项或勾选段落后再翻译")
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.token(.muted).opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                if let api = draft.apiConfiguration {
                    SnapButton(theme: theme, variant: .outline, size: .sm, isEnabled: canSave && trial == nil) {
                        testAPI(api)
                    } label: {
                        HStack(spacing: 4) {
                            if trial != nil { ProgressView().controlSize(.mini) }
                            Text(trial != nil ? "试译中" : "试译")
                        }
                    }
                    .help("使用示例文字 Hello 测试速度与连通性")

                    SnapButton("清密钥", theme: theme, variant: .ghost, size: .sm, isEnabled: trial == nil) {
                        removeSavedAPIKey(for: api)
                    }
                } else if let model = draft.modelConfiguration {
                    SnapButton(theme: theme, variant: .outline, size: .sm, isEnabled: canSave && trial == nil) {
                        testModel(model)
                    } label: {
                        HStack(spacing: 4) {
                            if trial != nil { ProgressView().controlSize(.mini) }
                            Text(trial != nil ? "试译中" : "试译")
                        }
                    }
                    .help("使用示例文字 Hello 测试，不读取截图")

                    if model.endpoint != nil {
                        SnapButton("清密钥", theme: theme, variant: .ghost, size: .sm, isEnabled: trial == nil) {
                            removeSavedModelKey(for: model)
                        }
                    }
                }

                Spacer()

                if let onCancel {
                    SnapButton("取消", theme: theme, variant: .ghost, size: .sm, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }

                SnapButton("保存并应用", theme: theme, variant: .primary, size: .sm, isEnabled: canSave && trial == nil, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 368)
        .background(theme.token(.popover))
        .foregroundStyle(theme.token(.foreground))
    }

    // MARK: - 子组件

    private var providerSegmented: some View {
        SnapSegmented(
            items: availableProviders,
            selection: Binding(
                get: { draft.provider ?? availableProviders.first ?? .api },
                set: { newValue in
                    draft.provider = newValue
                    endpointChanged()
                    // Apple 设备端翻译无需额外凭据，在设置页切过去即生效。
                    if !compact, newValue == .apple {
                        config.update { $0.translation.provider = .apple }
                    }
                }
            ),
            theme: theme,
            fullWidth: true,
            title: \.title
        )
    }

    private var apiProviderBinding: Binding<TranslationAPIProvider> {
        Binding(get: { draft.apiProvider }, set: {
            draft.apiProvider = $0
            endpointChanged()
        })
    }

    private var onlineProviderBinding: Binding<PrivacyAIProvider> {
        Binding(get: { draft.onlineProvider }, set: {
            draft.onlineProvider = $0
            endpointChanged()
        })
    }

    private var serviceSummary: String {
        switch draft.provider {
        case .apple: return "Apple 设备端离线翻译"
        case .api: return "专业翻译 API（\(draft.apiProvider.title)）"
        case .local: return "本机 OpenAI 兼容模型"
        case .online: return "在线大模型（\(draft.onlineProvider.title)）"
        case nil: return "尚未选择翻译服务"
        }
    }

    private func compactFieldRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.token(.mutedForeground))
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)
            Spacer(minLength: 4)
            control()
        }
    }

    private func secureField(placeholder: String, width: CGFloat) -> some View {
        let binding = Binding(get: { key }, set: {
            clearTrial()
            key = $0
        })
        return HStack(spacing: 6) {
            Group {
                if revealsKey {
                    TextField(placeholder, text: binding)
                } else {
                    SecureField(placeholder, text: binding)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.token(.foreground))
            .focused($isKeyFocused)

            if !key.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    keyCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        keyCopied = false
                    }
                } label: {
                    Image(systemName: keyCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(keyCopied ? Color.green : theme.token(.mutedForeground))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(keyCopied ? "已复制密钥" : "复制当前密钥")
            }

            Button {
                revealsKey.toggle()
            } label: {
                Image(systemName: revealsKey ? "eye.slash" : "eye")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(revealsKey ? theme.token(.foreground) : theme.token(.mutedForeground))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(revealsKey ? "隐藏明文密钥" : "查看已配置密钥")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: 30)
        .background(
            isKeyFocused ? theme.settingsCardSurface : theme.fieldSurface,
            in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                .strokeBorder(
                    isKeyFocused ? theme.controlAccent : theme.settingsCardBorder,
                    lineWidth: isKeyFocused ? 1.5 : 1
                )
        )
        .shadow(color: isKeyFocused ? theme.controlAccent.opacity(0.18) : .clear, radius: 3)
        .animation(Interaction.hover, value: isKeyFocused)
        .accessibilityLabel("翻译 API Key")
    }

    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(statusIsError ? theme.token(.destructive) : Color.green)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(statusIsError ? theme.token(.destructive) : theme.token(.foreground))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (statusIsError ? theme.token(.destructive) : Color.green).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    // MARK: - 逻辑

    private var canSave: Bool {
        guard let provider = draft.provider else { return false }
        switch provider {
        case .apple:
            if #available(macOS 15, *) { return true }
            return false
        case .api:
            return draft.apiConfiguration?.isFormValid == true
        case .local, .online:
            guard let model = draft.modelConfiguration else { return false }
            return TextModelTranslation.accepts(model)
        }
    }

    private func modelField(_ path: WritableKeyPath<PrivacyAIConfiguration, String>) -> Binding<String> {
        Binding(get: { draft.modelConfiguration?[keyPath: path] ?? "" }, set: { value in
            guard var model = draft.modelConfiguration else { return }
            model[keyPath: path] = value
            draft.saveModel(model)
            if path == \.baseURL { endpointChanged() } else { clearTrial() }
        })
    }

    private func apiField(_ path: WritableKeyPath<TranslationAPIConfiguration, String>) -> Binding<String> {
        Binding(get: { draft.apiConfiguration?[keyPath: path] ?? "" }, set: { value in
            guard var api = draft.apiConfiguration else { return }
            api[keyPath: path] = value
            draft.saveAPI(api)
            if path == \.customBaseURL { endpointChanged() } else { clearTrial() }
        })
    }

    private func loadSavedKey() {
        keyCopied = false
        if let api = draft.apiConfiguration {
            key = (try? config.translationKeys.read(for: api)) ?? ""
        } else if let model = draft.modelConfiguration {
            key = (try? config.translationKeys.read(for: model)) ?? ""
        } else {
            key = ""
        }
        savedKeySnapshot = key
    }

    private func endpointChanged() {
        clearTrial()
        loadSavedKey()
    }

    private func clearTrial() {
        trial?.cancel()
        trial = nil
        status = ""
        statusIsError = false
    }

    private func removeSavedModelKey(for model: PrivacyAIConfiguration) {
        do {
            try config.translationKeys.remove(for: model)
            revealsKey = false
            endpointChanged()
            statusIsError = false
            status = "已移除该地址保存的密钥"
        } catch {
            statusIsError = true
            status = message(error)
        }
    }

    private func removeSavedAPIKey(for api: TranslationAPIConfiguration) {
        do {
            try config.translationKeys.remove(for: api)
            revealsKey = false
            endpointChanged()
            statusIsError = false
            status = "已移除 \(api.provider.title) 已保存的密钥"
        } catch {
            statusIsError = true
            status = message(error)
        }
    }

    private func modelCredential(for model: PrivacyAIConfiguration) throws -> String? {
        let value = key.isEmpty ? try config.translationKeys.read(for: model) : try PrivacyAI.validatedKey(key)
        if model.provider.requiresAPIKey && value == nil { throw PrivacyAIError.missingKey }
        return value
    }

    private func apiCredential(for api: TranslationAPIConfiguration) throws -> String? {
        let value = key.isEmpty ? try config.translationKeys.read(for: api) : try PrivacyAI.validatedKey(key)
        if api.provider.requiresSecret && value == nil {
            throw TranslationAPIError.missingCredential("请填写 \(api.provider.title) 的 \(api.provider.secretLabel)。")
        }
        return value
    }

    private func save() {
        do {
            if let api = draft.apiConfiguration {
                let checked = try apiCredential(for: api)
                if !key.isEmpty, let checked {
                    try config.translationKeys.save(checked, for: api)
                }
            } else if let model = draft.modelConfiguration {
                let checked = try modelCredential(for: model)
                if !key.isEmpty, let checked {
                    try config.translationKeys.save(checked, for: model)
                }
            }
            let previous = config.settings.translation
            config.update { settings in
                settings.translation.provider = draft.provider
                settings.translation.targetLanguage = draft.targetLanguage
                settings.translation.autoTranslateOnOpen = draft.autoTranslateOnOpen
                settings.translation.quickTranslateStyle = draft.quickTranslateStyle
                if let api = draft.apiConfiguration {
                    settings.translation.apiProvider = draft.apiProvider
                    settings.translation.saveAPI(api)
                } else if let model = draft.modelConfiguration {
                    settings.translation.saveModel(model)
                    if draft.provider == .online { settings.translation.onlineProvider = draft.onlineProvider }
                }
            }
            statusIsError = false
            status = "已保存"
            savedKeySnapshot = key
            TranslationModelClient.prewarm(config: config)
            onSave(config.settings.translation != previous)
        } catch {
            statusIsError = true
            status = message(error)
        }
    }

    private func testAPI(_ api: TranslationAPIConfiguration) {
        do {
            let credential = try apiCredential(for: api)
            statusIsError = false
            status = "正在试译 Hello…"
            let started = Date()
            trial = Task { @MainActor in
                do {
                    let answer = try await ThirdPartyTranslation.translate(
                        "Hello",
                        source: "en",
                        target: "zh-Hans",
                        configuration: api,
                        secret: credential
                    )
                    guard !Task.isCancelled else { return }
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    statusIsError = false
                    status = "试译成功 (\(ms)ms)：Hello → \(answer)"
                } catch {
                    guard !Task.isCancelled else { return }
                    statusIsError = true
                    status = message(error)
                }
                trial = nil
            }
        } catch {
            statusIsError = true
            status = message(error)
        }
    }

    private func testModel(_ model: PrivacyAIConfiguration) {
        do {
            let credential = try modelCredential(for: model)
            statusIsError = false
            status = "正在试译 Hello…"
            let started = Date()
            trial = Task { @MainActor in
                do {
                    let answer = try await TextModelTranslation.translate("Hello", source: "en", target: "zh-Hans",
                                                                         model: model, key: credential)
                    guard !Task.isCancelled else { return }
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    statusIsError = false
                    status = "试译成功 (\(ms)ms)：Hello → \(answer)"
                } catch {
                    guard !Task.isCancelled else { return }
                    statusIsError = true
                    status = message(error)
                }
                trial = nil
            }
        } catch {
            statusIsError = true
            status = message(error)
        }
    }

    private func message(_ error: Error) -> String {
        if let apiError = error as? TranslationAPIError { return apiError.localizedDescription }
        if let reason = error as? PrivacyAIError { return TranslationModelClient.ServiceError(reason).localizedDescription }
        return error.localizedDescription.isEmpty ? "操作未完成，请检查服务配置。" : error.localizedDescription
    }
}
