import SwiftUI
import TapSnapConfig
import TapSnapPrivacy
import TapSnapTheme
import TapSnapUI

struct PrivacySettingsView: View {
    @ObservedObject var config: ConfigStore
    let theme: Theme
    @State private var editing: CustomPrivacyRule?
    @State private var pendingDeleteRule: CustomPrivacyRule?

    var body: some View {
        SettingsPage(section: .privacy, theme: theme) {
            SnapSettingGroup(theme: theme) {
                SnapSettingRow(
                    "截图后自动检查",
                    subtitle: "在本机识别截图和长图，自动规则直接生成可编辑的打码块",
                    theme: theme
                ) {
                    SnapToggle(isOn: bind(\.enabled), theme: theme)
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("内部域名后缀")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.token(.foreground))
                    SnapTextField(
                        text: bind(\.internalDomains),
                        theme: theme,
                        placeholder: "如 corp.example、internal.example（逗号或空格分隔）",
                        monospaced: true
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("内部域名后缀")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            ruleGroup("图片内容", [.barcode, .face])
            customRules
        }
        .sheet(item: $editing) { rule in
            CustomPrivacyRuleEditor(rule: rule, theme: theme) { updated in
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
        .confirmationDialog(
            "删除规则「\(pendingDeleteRule?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let rule = pendingDeleteRule else { return }
                config.update { $0.privacy.customRules.removeAll { $0.id == rule.id } }
                pendingDeleteRule = nil
            }
            Button("取消", role: .cancel) { pendingDeleteRule = nil }
        } message: {
            Text("删除后需要重新填写正则才能恢复。")
        }
    }

    private func ruleGroup(_ title: String, _ rules: [PrivacyRule]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .padding(.leading, 6)
                Spacer()
                Menu("全部设为…") {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        Button(mode.title) {
                            config.update { settings in
                                for rule in rules { settings.privacy[rule] = mode }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11.5))
                .foregroundStyle(theme.token(.mutedForeground))
            }
            VStack(spacing: 0) {
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
            .background(theme.settingsCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.settingsCardBorder, lineWidth: 0.75)
            }
            .shadow(
                color: Color.black.opacity(theme.isDark ? 0.22 : 0.045),
                radius: theme.isDark ? 8 : 5,
                y: theme.isDark ? 3 : 1.5
            )
        }
    }

    private var customRules: some View {
        SnapSettingGroup("自定义规则", theme: theme) {
            ForEach(config.settings.privacy.customRules) { rule in
                SnapSettingRow(rule.name, subtitle: "\(rule.mode.title) · \(rule.pattern)", theme: theme) {
                    HStack(spacing: 6) {
                        SnapButton("编辑", theme: theme, variant: .outline, size: .sm) {
                            editing = rule
                        }
                        SnapButton(theme: theme, variant: .ghost, size: .icon) {
                            pendingDeleteRule = rule
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.token(.destructive))
                        }
                        .accessibilityLabel("删除规则 \(rule.name)")
                        .help("删除规则")
                    }
                }
                SnapRowDivider(theme: theme)
            }
            SnapSettingRow("按正则匹配", subtitle: "匹配截图中的自定义编号、工单号或敏感关键词", theme: theme) {
                SnapButton("添加规则", theme: theme, variant: .outline, size: .sm) {
                    editing = CustomPrivacyRule()
                }
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
    .pickerStyle(.menu)
    .frame(width: 112)
}

private struct CustomPrivacyRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: CustomPrivacyRule
    let theme: Theme
    let save: (CustomPrivacyRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义脱敏规则")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.token(.foreground))

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("规则名称")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    SnapTextField(text: $rule.name, theme: theme, placeholder: "如 内部工单号")
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("正则表达式")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.token(.mutedForeground))
                    SnapTextField(text: $rule.pattern, theme: theme, placeholder: #"如 INT-\d{4}"#, monospaced: true)
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    Text("处理方式")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.token(.foreground))
                    Spacer()
                    modePicker("处理方式", selection: $rule.mode)
                }
            }

            if let message = rule.validationMessage, !rule.name.isEmpty || !rule.pattern.isEmpty {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.token(.destructive))
            }

            HStack {
                Spacer()
                SnapButton("取消", theme: theme, variant: .outline, size: .sm) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SnapButton("保存", theme: theme, variant: .primary, size: .sm, isEnabled: rule.validationMessage == nil) {
                    save(rule)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(theme.token(.background))
        .foregroundStyle(theme.token(.foreground))
    }
}
