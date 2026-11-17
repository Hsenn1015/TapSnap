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
    @State private var result = ""
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        SnapSettingGroup("识别模型", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("AI 补查", selection: provider) {
                    Text("仅本机规则").tag(nil as PrivacyAIProvider?)
                    ForEach(PrivacyAIProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }
                if let draft {
                    TextField("API 地址", text: field(\.baseURL))
                        .accessibilityLabel("API 地址")
                    TextField("模型名称", text: field(\.model))
                        .accessibilityLabel("模型名称")
                    SecureField("API Key", text: $key)
                        .accessibilityLabel("API Key")
                    HStack(spacing: 8) {
                        Button("保存配置") { save(draft) }
                            .disabled(!draft.isConfigured || testTask != nil)
                        Button("测试连接") { test(draft) }
                            .disabled(!draft.isConfigured || testTask != nil)
                            .help("用合成文字测试，不读取屏幕")
                        Button("移除密钥") { removeKey(draft) }
                            .disabled(draft.endpoint == nil || testTask != nil)
                    }
                    if !result.isEmpty {
                        Text(result).font(.caption)
                    }
                    Text(draft.provider == .local
                         ? "填入已运行的本机兼容服务和已安装模型名称。"
                         : "API Key 存在仅当前 macOS 用户可读的本机文件中。")
                        .font(.caption)
                        .foregroundStyle(theme.token(.mutedForeground))
                }
                Text("自动检查使用本机规则。AI 补查支持文字和图片定位，图片定位需要视觉模型，例如 DeepSeek Flash 或 Qwen3-VL。")
                    .font(.caption)
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)
        }
        .onAppear { draft = config.settings.privacy.ai }
        .onDisappear { testTask?.cancel(); testTask = nil; key = "" }
    }

    private var provider: Binding<PrivacyAIProvider?> {
        Binding(get: { draft?.provider }, set: { choice in
            guard choice != draft?.provider else { return }
            testTask?.cancel()
            testTask = nil
            result = ""
            key = ""
            let existing = config.settings.privacy.ai
            draft = choice.map { provider in
                if let existing, existing.provider == provider { return existing }
                return PrivacyAIConfiguration(provider: provider)
            }
            if choice == nil { config.update { $0.privacy.ai = nil } }
        })
    }

    private func field(_ keyPath: WritableKeyPath<PrivacyAIConfiguration, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func save(_ configuration: PrivacyAIConfiguration) {
        do {
            if !key.isEmpty {
                try config.privacyAIKeys.save(key, for: configuration)
                key = ""
            }
            config.update { $0.privacy.ai = configuration }
            if configuration.provider.requiresAPIKey, try config.privacyAIKeys.read(for: configuration) == nil {
                result = "配置已保存，请填写并保存 API Key"
            } else {
                result = "已保存"
            }
        } catch {
            result = (error as? PrivacyAIError)?.message ?? "无法保存配置"
        }
    }

    private func removeKey(_ configuration: PrivacyAIConfiguration) {
        do {
            try config.privacyAIKeys.remove(for: configuration)
            key = ""
            result = "已移除密钥"
        } catch {
            result = (error as? PrivacyAIError)?.message ?? "无法移除密钥"
        }
    }

    private func test(_ configuration: PrivacyAIConfiguration) {
        result = "正在用合成文字测试…"
        let trialKey: String?
        do {
            trialKey = key.isEmpty ? try config.privacyAIKeys.read(for: configuration) : key
        } catch {
            result = (error as? PrivacyAIError)?.message ?? "无法读取 API Key"
            return
        }
        testTask = Task { @MainActor in
            do {
                try await PrivacyAI.testConnection(configuration, key: trialKey)
                guard !Task.isCancelled else { return }
                result = "连接成功"
            } catch {
                guard !Task.isCancelled else { return }
                result = (error as? PrivacyAIError)?.message ?? "连接失败"
            }
            testTask = nil
        }
    }
}
