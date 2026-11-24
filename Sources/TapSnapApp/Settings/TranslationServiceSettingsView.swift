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
    @State private var status = ""
    @State private var statusIsError = false
    @State private var trial: Task<Void, Never>?

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
        .onDisappear { clearTrial(); key = "" }
    }

    // MARK: - 设置页完整布局

    private var settingsPageBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            SnapSettingGroup("翻译引擎", theme: theme) {
                SnapSettingRow("翻译服务", subtitle: serviceSummary, theme: theme) {
                    providerSegmented
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow("默认目标语言", subtitle: "截图翻译时默认译成的语言", theme: theme) {
                    Picker("默认目标语言", selection: $draft.targetLanguage) {
                        ForEach(Self.supportedLanguages, id: \.code) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                SnapRowDivider(theme: theme)
                SnapSettingRow(
                    "打开后自动翻译",
                    subtitle: "关闭后先展示本机 OCR 原文，方便清理杂项或勾选段落后再翻译，节省 API 额度",
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

            if let api = draft.apiConfiguration {
                apiSettingsGroup(api)
            } else if let model = draft.modelConfiguration {
                modelSettingsGroup(model)
            } else {
                appleSettingsGroup
            }
        }
    }

    private func apiSettingsGroup(_ api: TranslationAPIConfiguration) -> some View {
        SnapSettingGroup("第三方翻译 API", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                SnapSettingRow("翻译引擎", subtitle: "低延迟专业翻译，支持整图批量直出", theme: theme) {
                    Picker("翻译引擎", selection: apiProviderBinding) {
                        ForEach(TranslationAPIProvider.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SnapRowDivider(theme: theme)

                if api.provider.requiresAppID {
                    SnapSettingRow(api.provider.appIDLabel, theme: theme) {
                        SnapTextField(
                            text: apiField(\.appID),
                            theme: theme,
                            placeholder: "填写 \(api.provider.appIDLabel)",
                            width: 240,
                            monospaced: true
                        )
                        .accessibilityLabel(api.provider.appIDLabel)
                    }
                    SnapRowDivider(theme: theme)
                }

                SnapSettingRow(
                    api.provider.secretLabel,
                    subtitle: api.provider.requiresSecret ? "仅保存在本机 0600 密钥文件，留空沿用已存" : "留空使用免密快捷通道，填入官方 Key 更稳",
                    theme: theme
                ) {
                    secureField(
                        placeholder: api.provider.requiresSecret ? "留空沿用已保存密钥" : "可选，留空走免密通道",
                        width: 240
                    )
                }

                if api.provider.supportsRegion {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("服务区域", theme: theme) {
                        SnapTextField(
                            text: apiField(\.region),
                            theme: theme,
                            placeholder: api.provider.regionPlaceholder,
                            width: 240,
                            monospaced: true
                        )
                    }
                }

                if api.provider.supportsCustomEndpoint {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("自定义端点", subtitle: "留空使用官方地址，可填反代 URL", theme: theme) {
                        SnapTextField(
                            text: apiField(\.customBaseURL),
                            theme: theme,
                            placeholder: api.provider.endpointPlaceholder,
                            width: 240,
                            monospaced: true
                        )
                    }
                }

                SnapRowDivider(theme: theme)

                VStack(alignment: .leading, spacing: 10) {
                    Text(api.provider.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)

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

                        SnapButton("移除已存密钥", theme: theme, variant: .ghost, size: .sm, isEnabled: trial == nil) {
                            removeSavedAPIKey(for: api)
                        }

                        Spacer()

                        SnapButton("保存翻译服务", theme: theme, variant: .primary, size: .sm, isEnabled: canSave && trial == nil, action: save)
                            .keyboardShortcut(.defaultAction)
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
                        .frame(width: 160)
                    }
                    SnapRowDivider(theme: theme)
                }

                SnapSettingRow("服务地址", theme: theme) {
                    SnapTextField(
                        text: modelField(\.baseURL),
                        theme: theme,
                        placeholder: "https://…/v1",
                        width: 240,
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
                        width: 240,
                        monospaced: true
                    )
                    .accessibilityLabel("翻译模型名称")
                }
                SnapRowDivider(theme: theme)

                SnapSettingRow("API Key", subtitle: "留空则沿用已保存的密钥", theme: theme) {
                    secureField(placeholder: "留空沿用已保存密钥", width: 240)
                }
                SnapRowDivider(theme: theme)

                VStack(alignment: .leading, spacing: 10) {
                    Text(draft.provider == .local
                         ? "填写 localhost 或回环 IP 地址及已下载的模型名称，使用前请先启动本机服务。"
                         : "仅将待翻译文字发送至上方地址，截图原图始终留在本机。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)

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

                        SnapButton("移除已存密钥", theme: theme, variant: .ghost, size: .sm, isEnabled: model.endpoint != nil && trial == nil) {
                            removeSavedModelKey(for: model)
                        }

                        Spacer()

                        SnapButton("保存翻译服务", theme: theme, variant: .primary, size: .sm, isEnabled: canSave && trial == nil, action: save)
                            .keyboardShortcut(.defaultAction)
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
                Text("使用 macOS 原生设备端翻译，无需 API Key，文字与截图均不离开本机。缺少对应语言包时系统将提示一键下载。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .fixedSize(horizontal: false, vertical: true)
                if !status.isEmpty {
                    statusBanner
                }
                HStack {
                    Spacer()
                    SnapButton("保存翻译服务", theme: theme, variant: .primary, size: .sm, isEnabled: canSave, action: save)
                        .keyboardShortcut(.defaultAction)
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

                    Text(api.provider.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
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

                    Text(draft.provider == .local
                         ? "请先启动本机兼容服务，仅允许 localhost / 回环地址。"
                         : "仅发送待翻译文本至上方服务，原图留在本机。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(theme.token(.muted).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.token(.primary))
                        .padding(.top, 1)
                    Text("macOS 设备端离线翻译，无需网络和密钥。缺少语言包时系统会提示下载。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.token(.muted).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !status.isEmpty {
                statusBanner
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("打开后自动翻译")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.foreground))
                    Text("关闭可先清理杂项再手动翻译")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
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
                    endpointChanged()
                    draft.provider = newValue
                }
            ),
            theme: theme,
            title: \.title
        )
    }

    private var apiProviderBinding: Binding<TranslationAPIProvider> {
        Binding(get: { draft.apiProvider }, set: {
            endpointChanged()
            draft.apiProvider = $0
        })
    }

    private var onlineProviderBinding: Binding<PrivacyAIProvider> {
        Binding(get: { draft.onlineProvider }, set: {
            endpointChanged()
            draft.onlineProvider = $0
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
        SecureField(placeholder, text: Binding(get: { key }, set: {
            clearTrial()
            key = $0
        }))
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(theme.token(.foreground))
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .background(theme.token(.background), in: RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.metrics.radiusSM, style: .continuous)
                .strokeBorder(theme.token(.input), lineWidth: 1)
        )
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
            if path == \.baseURL { endpointChanged() } else { clearTrial() }
            model[keyPath: path] = value
            draft.saveModel(model)
        })
    }

    private func apiField(_ path: WritableKeyPath<TranslationAPIConfiguration, String>) -> Binding<String> {
        Binding(get: { draft.apiConfiguration?[keyPath: path] ?? "" }, set: { value in
            guard var api = draft.apiConfiguration else { return }
            if path == \.customBaseURL { endpointChanged() } else { clearTrial() }
            api[keyPath: path] = value
            draft.saveAPI(api)
        })
    }

    private func endpointChanged() {
        clearTrial()
        key = ""
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
                if let api = draft.apiConfiguration {
                    settings.translation.apiProvider = draft.apiProvider
                    settings.translation.saveAPI(api)
                } else if let model = draft.modelConfiguration {
                    settings.translation.saveModel(model)
                    if draft.provider == .online { settings.translation.onlineProvider = draft.onlineProvider }
                }
            }
            key = ""
            statusIsError = false
            status = "已保存"
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
