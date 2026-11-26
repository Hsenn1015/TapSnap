import AppKit
import SwiftUI
import TapSnapConfig
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI

struct PrivacyAISettingsView: View {
    @ObservedObject var config: ConfigStore
    let theme: Theme
    @State private var draft: PrivacyAIConfiguration?
    @State private var key = ""
    @State private var savedKeySnapshot = ""
    @State private var revealsKey = false
    @State private var result = ""
    @State private var resultIsError = false
    @State private var testTask: Task<Void, Never>?
    @State private var confirmsRemoveKey = false
    @FocusState private var isKeyFocused: Bool

    private var hasUnsavedChanges: Bool {
        if draft != config.settings.privacy.ai { return true }
        if draft != nil, key != savedKeySnapshot { return true }
        return false
    }

    var body: some View {
        SnapSettingGroup("识别模型", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                SnapSettingRow(
                    "AI 补查",
                    subtitle: "自动检查使用本机规则；AI 补查支持文字与图片定位（图片定位需要视觉模型）",
                    theme: theme
                ) {
                    Picker("AI 补查", selection: provider) {
                        Text("仅本机规则").tag(nil as PrivacyAIProvider?)
                        ForEach(PrivacyAIProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(Optional(provider))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                if let draft {
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("API 地址", theme: theme) {
                        SnapTextField(
                            text: field(\.baseURL),
                            theme: theme,
                            placeholder: "https://…/v1",
                            width: 280,
                            monospaced: true
                        )
                        .accessibilityLabel("API 地址")
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("模型名称", theme: theme) {
                        SnapTextField(
                            text: field(\.model),
                            theme: theme,
                            placeholder: "已启用的模型名称",
                            width: 280,
                            monospaced: true
                        )
                        .accessibilityLabel("模型名称")
                    }
                    SnapRowDivider(theme: theme)
                    SnapSettingRow("API Key", theme: theme) {
                        keyField(placeholder: draft.provider.requiresAPIKey ? "输入 API Key" : "可选（本地模型可留空）")
                    }
                    SnapRowDivider(theme: theme)
                    VStack(alignment: .leading, spacing: 10) {
                        if !result.isEmpty {
                            statusBanner
                        }
                        HStack(spacing: 8) {
                            SnapButton(
                                theme: theme,
                                variant: .outline,
                                size: .sm,
                                isEnabled: draft.isConfigured && testTask == nil
                            ) {
                                test(draft)
                            } label: {
                                HStack(spacing: 5) {
                                    if testTask != nil { ProgressView().controlSize(.mini) }
                                    Text(testTask != nil ? "测试中…" : "测试连接")
                                }
                            }
                            .help("用合成文字测试，不读取屏幕")

                            SnapButton(
                                "移除密钥",
                                theme: theme,
                                variant: .ghost,
                                size: .sm,
                                isEnabled: draft.endpoint != nil && !savedKeySnapshot.isEmpty && testTask == nil
                            ) {
                                confirmsRemoveKey = true
                            }

                            Spacer()

                            if hasUnsavedChanges {
                                Text("未保存")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }

                            SnapButton(
                                "保存配置",
                                theme: theme,
                                variant: .primary,
                                size: .sm,
                                isEnabled: draft.isConfigured && hasUnsavedChanges && testTask == nil
                            ) {
                                save(draft)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            draft = config.settings.privacy.ai
            loadSavedKey(for: draft)
        }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
            key = ""
            savedKeySnapshot = ""
            revealsKey = false
        }
        .confirmationDialog("移除已保存的 AI 补查密钥？", isPresented: $confirmsRemoveKey, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) {
                if let draft { removeKey(draft) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后需要重新输入 API Key 才能继续使用该模型。")
        }
    }

    private func keyField(placeholder: String) -> some View {
        HStack(spacing: 6) {
            Group {
                if revealsKey {
                    TextField(placeholder, text: $key)
                } else {
                    SecureField(placeholder, text: $key)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(theme.token(.foreground))
            .focused($isKeyFocused)

            Button {
                revealsKey.toggle()
            } label: {
                Image(systemName: revealsKey ? "eye.slash" : "eye")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(revealsKey ? theme.token(.foreground) : theme.token(.mutedForeground))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(revealsKey ? "隐藏明文密钥" : "查看密钥")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 280, height: 30)
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
        .accessibilityLabel("API Key")
    }

    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(resultIsError ? theme.token(.destructive) : Color.green)
            Text(result)
                .font(.system(size: 11))
                .foregroundStyle(resultIsError ? theme.token(.destructive) : theme.token(.foreground))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (resultIsError ? theme.token(.destructive) : Color.green).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private var provider: Binding<PrivacyAIProvider?> {
        Binding(get: { draft?.provider }, set: { choice in
            guard choice != draft?.provider else { return }
            testTask?.cancel()
            testTask = nil
            result = ""
            resultIsError = false
            revealsKey = false
            // 切回「仅本机规则」时保留已填好的服务商配置，避免误点后丢失地址和模型名。
            if let current = draft, current.isConfigured {
                config.update { $0.privacy.saveAIProfile(current) }
            }
            if let choice {
                let restored = config.settings.privacy.savedAI(for: choice)
                draft = restored
                loadSavedKey(for: restored)
            } else {
                draft = nil
                key = ""
                savedKeySnapshot = ""
                config.update { settings in
                    if let existing = settings.privacy.ai {
                        settings.privacy.saveAIProfile(existing)
                    }
                    settings.privacy.ai = nil
                }
            }
        })
    }

    private func field(_ keyPath: WritableKeyPath<PrivacyAIConfiguration, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" }, set: { value in
            draft?[keyPath: keyPath] = value
            if keyPath == \.baseURL { loadSavedKey(for: draft) }
        })
    }

    private func loadSavedKey(for configuration: PrivacyAIConfiguration?) {
        guard let configuration else {
            key = ""
            savedKeySnapshot = ""
            return
        }
        let stored = (try? config.privacyAIKeys.read(for: configuration)) ?? ""
        key = stored
        savedKeySnapshot = stored
    }

    private func save(_ configuration: PrivacyAIConfiguration) {
        do {
            if !key.isEmpty {
                try config.privacyAIKeys.save(key, for: configuration)
                savedKeySnapshot = key
            }
            config.update {
                $0.privacy.saveAIProfile(configuration)
                $0.privacy.ai = configuration
            }
            if configuration.provider.requiresAPIKey, try config.privacyAIKeys.read(for: configuration) == nil {
                resultIsError = true
                result = "配置已保存，请填写并保存 API Key"
            } else {
                resultIsError = false
                result = "已保存"
            }
        } catch {
            resultIsError = true
            result = (error as? PrivacyAIError)?.message ?? "无法保存配置"
        }
    }

    private func removeKey(_ configuration: PrivacyAIConfiguration) {
        do {
            try config.privacyAIKeys.remove(for: configuration)
            key = ""
            savedKeySnapshot = ""
            revealsKey = false
            resultIsError = false
            result = "已移除密钥"
        } catch {
            resultIsError = true
            result = (error as? PrivacyAIError)?.message ?? "无法移除密钥"
        }
    }

    private func test(_ configuration: PrivacyAIConfiguration) {
        resultIsError = false
        result = "正在用合成文字测试…"
        let trialKey: String?
        do {
            trialKey = key.isEmpty ? try config.privacyAIKeys.read(for: configuration) : key
        } catch {
            resultIsError = true
            result = (error as? PrivacyAIError)?.message ?? "无法读取 API Key"
            return
        }
        testTask = Task { @MainActor in
            do {
                try await PrivacyAI.testConnection(configuration, key: trialKey)
                guard !Task.isCancelled else { return }
                resultIsError = false
                result = "连接成功"
            } catch {
                guard !Task.isCancelled else { return }
                resultIsError = true
                result = (error as? PrivacyAIError)?.message ?? "连接失败"
            }
            testTask = nil
        }
    }
}
