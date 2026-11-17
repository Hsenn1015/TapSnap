import SwiftUI
import TapSnapConfig
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI

struct PrivacySettingsView: View {
    @ObservedObject var config: ConfigStore
    let theme: Theme
    @State private var editing: CustomPrivacyRule?

    var body: some View {
        SettingsPage(title: "隐私打码", theme: theme) {
            SnapSettingGroup(theme: theme) {
                SnapSettingRow("截图后自动检查",
                               subtitle: "在本机识别截图和长图，自动规则直接生成可编辑的打码块。",
                               theme: theme) {
                    SnapToggle(isOn: bind(\.enabled), theme: theme)
                        .accessibilityLabel("截图后自动检查")
                }
            }
            SnapSettingGroup("默认打码样式", theme: theme) {
                PrivacyAppearanceControls(appearance: bind(\.appearance))
                    .padding(10)
            }
            PrivacyAISettingsView(config: config, theme: theme)
            ruleGroup("个人信息", [.mobile, .landline, .identity, .bankCard, .email, .name, .employeeID, .address])
            ruleGroup("开发环境", [.credentials, .verificationCode, .token, .cookie, .privateIP, .internalDomain])
            SnapSettingGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("内部域名后缀")
                        .font(.system(size: 12, weight: .medium))
                    TextField("如 corp.example、internal.example", text: bind(\.internalDomains))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("内部域名后缀")
                    Text("用逗号或空格分隔，匹配域名及其子域名。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
                .padding(10)
            }
            ruleGroup("图片内容", [.barcode, .face])
            customRules
        }
        .sheet(item: $editing) { rule in
            CustomPrivacyRuleEditor(rule: rule) { updated in
                config.update {
                    if let index = $0.privacy.customRules.firstIndex(where: { $0.id == updated.id }) {
                        $0.privacy.customRules[index] = updated
                    } else {
                        $0.privacy.customRules.append(updated)
                    }
                }
                editing = nil
            }
        }
    }

    private func ruleGroup(_ title: String, _ rules: [PrivacyRule]) -> some View {
        SnapSettingGroup(title, theme: theme) {
            ForEach(rules, id: \.self) { rule in
                if rule != rules.first { SnapRowDivider(theme: theme) }
                SnapSettingRow(rule.title, theme: theme) {
                    modePicker(rule.title, selection: Binding(
                        get: { config.settings.privacy[rule] },
                        set: { mode in config.update { $0.privacy[rule] = mode } }
                    ))
                }
            }
        }
    }

    private var customRules: some View {
        SnapSettingGroup("自定义规则", theme: theme) {
            ForEach(config.settings.privacy.customRules) { rule in
                SnapSettingRow(rule.name, subtitle: rule.mode.title, theme: theme) {
                    HStack(spacing: 10) {
                        Button("编辑") { editing = rule }
                        Button(role: .destructive) {
                            config.update { $0.privacy.customRules.removeAll { $0.id == rule.id } }
                        } label: { Image(systemName: "trash") }
                        .accessibilityLabel("删除规则 \(rule.name)")
                    }
                }
                SnapRowDivider(theme: theme)
            }
            SnapSettingRow("按正则匹配", subtitle: "在识别出的每行文字中匹配，例如内部编号或链接参数。", theme: theme) {
                Button("添加规则") { editing = CustomPrivacyRule() }
            }
        }
    }

    private func bind<T>(_ key: WritableKeyPath<PrivacySettings, T>) -> Binding<T> {
        Binding(get: { config.settings.privacy[keyPath: key] },
                set: { value in config.update { $0.privacy[keyPath: key] = value } })
    }
}

private func modePicker(_ title: String, selection: Binding<PrivacyMode>) -> some View {
    Picker(title, selection: selection) {
        ForEach(PrivacyMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
    }
    .labelsHidden()
    .frame(width: 108)
}

private struct CustomPrivacyRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: CustomPrivacyRule
    let save: (CustomPrivacyRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义脱敏规则").font(.headline)
            TextField("规则名称", text: $rule.name).textFieldStyle(.roundedBorder)
            TextField("正则表达式", text: $rule.pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Text("处理方式")
                Spacer()
                modePicker("处理方式", selection: $rule.mode)
            }
            if let message = rule.validationMessage, !rule.name.isEmpty || !rule.pattern.isEmpty {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 390)
    }
}
