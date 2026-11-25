using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;

namespace TapSnap.Windows;

internal sealed class RecognitionSettingsWindow : Window
{
    private readonly RecognitionSettings original = RecognitionService.Settings;
    private readonly Dictionary<PrivacyRuleKind, ComboBox> modes = new();
    private readonly StackPanel customEntries = new();
    private readonly List<CustomEntry> customs = new();
    private readonly CheckBox scan = new() { Content = "截图后自动检查" };
    private readonly TextBox language = new();
    private readonly CheckBox copyOcr = new() { Content = "文字识别后自动复制" };
    private readonly CheckBox collapseOcr = new() { Content = "复制时用空格替换换行" };
    private readonly TextBox domains = new();
    private readonly TextBox endpoint = new();
    private readonly TextBox model = new();
    private readonly PasswordBox apiKey = new();
    private readonly CheckBox clearKey = new() { Content = "移除当前保存的 API Key" };
    private readonly CancellationTokenSource lifetime = new();
    private readonly TextBox python = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TabControl tabs = new();

    public RecognitionSettingsWindow(bool openTranslation = false)
    {
        Title = "TapSnap · 脱敏规则与识别模型";
        Width = 650; Height = 720; MinWidth = 500; MinHeight = 455;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SnapTheme.StyleWindow(this);
        var grid = new DockPanel { Margin = new Thickness(15) };

        var footer = new DockPanel { Margin = new Thickness(0, 9, 0, 0) };
        var save = Button("保存");
        save.SetResourceReference(StyleProperty, "SnapPrimary");
        save.IsDefault = true;
        save.Click += (_, _) => Save();
        DockPanel.SetDock(save, Dock.Right);
        footer.Children.Add(save);
        footer.Children.Add(status);
        DockPanel.SetDock(footer, Dock.Bottom);
        grid.Children.Add(footer);

        void AddPage(string title, FrameworkElement content) =>
            tabs.Items.Add(new TabItem { Header = title,
                Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        AddPage("脱敏规则", RuleSettings());
        AddPage("识别与模型", ModelSettings());
        AddPage("截图翻译", BuildTranslationPanel(lifetime.Token));
        if (openTranslation) ShowTranslation();
        grid.Children.Add(tabs);
        Content = grid;
        Closed += (_, _) => { lifetime.Cancel(); lifetime.Dispose(); apiKey.Clear(); };
    }

    public void ShowTranslation() => tabs.SelectedIndex = 2;

    public static FrameworkElement BuildTranslationPanel(CancellationToken lifetimeToken)
    {
        var panel = new StackPanel { Margin = new Thickness(4) };
        var draft = RecognitionService.Settings.Translation.Clone();
        var statusLine = new TextBlock { FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 4, 10) };
        statusLine.SetResourceReference(TextBlock.ForegroundProperty, "Snap.Muted");

        // Group 1: 基本设置
        var basic = SettingsLayout.Group(panel, "翻译引擎");
        var providerBox = new ComboBox
        {
            ItemsSource = new[] { "翻译 API", "本机模型", "在线模型" },
            SelectedIndex = draft.Provider switch
            {
                TranslationProviderKind.Api => 0,
                TranslationProviderKind.Local => 1,
                _ => 2
            },
            Width = 170
        };
        SettingsLayout.Row(basic, "翻译服务", providerBox);

        var targetBox = new ComboBox
        {
            ItemsSource = TranslationCatalog.TargetLanguages,
            DisplayMemberPath = nameof(TranslationLanguageOption.DisplayName),
            Width = 170
        };
        int savedIdx = Array.FindIndex(TranslationCatalog.TargetLanguages,
            l => l.Code.Equals(draft.TargetLanguage, StringComparison.OrdinalIgnoreCase));
        targetBox.SelectedIndex = savedIdx >= 0 ? savedIdx : 1;
        targetBox.SelectionChanged += (_, _) =>
        {
            if (targetBox.SelectedItem is TranslationLanguageOption opt)
            {
                draft.TargetLanguage = opt.Code;
                RecognitionService.Settings.Translation.TargetLanguage = opt.Code;
                RecognitionService.SaveSettings(RecognitionService.Settings);
            }
        };
        SettingsLayout.Row(basic, "默认目标语言", targetBox);

        SettingsLayout.Toggle(basic, "打开后自动翻译", draft.AutoTranslateOnOpen, v =>
        {
            draft.AutoTranslateOnOpen = v;
            RecognitionService.Settings.Translation.AutoTranslateOnOpen = v;
            RecognitionService.SaveSettings(RecognitionService.Settings);
        });

        // Group 2: 截图秒译样式
        var quickGroup = SettingsLayout.Group(panel, "截图秒译样式");
        var styleBox = new ComboBox
        {
            ItemsSource = Enum.GetValues<QuickTranslateStyle>()
                .Select(s => new KeyValuePair<QuickTranslateStyle, string>(s, TranslationCatalog.QuickStyleName(s)))
                .ToArray(),
            DisplayMemberPath = "Value",
            SelectedValuePath = "Key",
            SelectedValue = draft.QuickTranslateStyle,
            Width = 170,
            ToolTip = TranslationCatalog.QuickStyleSummary(draft.QuickTranslateStyle)
        };
        styleBox.SelectionChanged += (_, _) =>
        {
            if (styleBox.SelectedValue is QuickTranslateStyle s)
            {
                draft.QuickTranslateStyle = s;
                styleBox.ToolTip = TranslationCatalog.QuickStyleSummary(s);
                RecognitionService.Settings.Translation.QuickTranslateStyle = s;
                RecognitionService.SaveSettings(RecognitionService.Settings);
            }
        };
        SettingsLayout.Row(quickGroup, "浮卡风格", styleBox);

        // Group 3: 动态服务配置容器
        var configHost = new StackPanel();
        panel.Children.Add(configHost);
        panel.Children.Add(statusLine);

        void RebuildServiceFields()
        {
            configHost.Children.Clear();
            statusLine.Text = "";

            string secretValue = "";
            bool revealSecret = false;

            (FrameworkElement Control, Func<string> GetText, Action<string> SetText) CreateSecretInput(string scope)
            {
                secretValue = TranslationSecrets.Read(scope) ?? "";
                var container = new DockPanel { Width = 230 };
                var copyBtn = new Button { Content = "📋", Width = 26, Height = 26, ToolTip = "复制密钥", Margin = new Thickness(3, 0, 0, 0), Padding = new Thickness(0) };
                var eyeBtn = new Button { Content = "👁", Width = 26, Height = 26, ToolTip = "显示 / 隐藏密钥", Margin = new Thickness(3, 0, 0, 0), Padding = new Thickness(0) };
                DockPanel.SetDock(copyBtn, Dock.Right);
                DockPanel.SetDock(eyeBtn, Dock.Right);
                container.Children.Add(copyBtn);
                container.Children.Add(eyeBtn);

                var plainBox = new TextBox { Text = secretValue, Visibility = Visibility.Collapsed, VerticalContentAlignment = VerticalAlignment.Center };
                var maskedBox = new PasswordBox { Password = secretValue, VerticalContentAlignment = VerticalAlignment.Center };
                bool syncing = false;
                maskedBox.PasswordChanged += (_, _) =>
                {
                    if (syncing) return;
                    syncing = true;
                    secretValue = maskedBox.Password;
                    plainBox.Text = secretValue;
                    syncing = false;
                };
                plainBox.TextChanged += (_, _) =>
                {
                    if (syncing) return;
                    syncing = true;
                    secretValue = plainBox.Text;
                    maskedBox.Password = secretValue;
                    syncing = false;
                };
                eyeBtn.Click += (_, _) =>
                {
                    revealSecret = !revealSecret;
                    plainBox.Visibility = revealSecret ? Visibility.Visible : Visibility.Collapsed;
                    maskedBox.Visibility = revealSecret ? Visibility.Collapsed : Visibility.Visible;
                };
                copyBtn.Click += (_, _) =>
                {
                    if (string.IsNullOrEmpty(secretValue)) return;
                    try { Clipboard.SetText(secretValue); statusLine.Text = "已复制 API Key"; }
                    catch (System.Runtime.InteropServices.ExternalException) { }
                };

                var fieldGrid = new Grid();
                fieldGrid.Children.Add(maskedBox);
                fieldGrid.Children.Add(plainBox);
                container.Children.Add(fieldGrid);

                return (container, () => secretValue, value =>
                {
                    syncing = true;
                    secretValue = value;
                    plainBox.Text = value;
                    maskedBox.Password = value;
                    syncing = false;
                });
            }

            if (draft.Provider == TranslationProviderKind.Api)
            {
                var apiGroup = SettingsLayout.Group(configHost, "翻译 API 配置");
                var apiBox = new ComboBox
                {
                    ItemsSource = Enum.GetValues<TranslationApiProvider>()
                        .Select(p => new KeyValuePair<TranslationApiProvider, string>(p, TranslationCatalog.ApiTitle(p)))
                        .ToArray(),
                    DisplayMemberPath = "Value",
                    SelectedValuePath = "Key",
                    SelectedValue = draft.ApiProvider,
                    Width = 170
                };
                apiBox.SelectionChanged += (_, _) =>
                {
                    if (apiBox.SelectedValue is TranslationApiProvider p && p != draft.ApiProvider)
                    {
                        draft.ApiProvider = p;
                        RebuildServiceFields();
                    }
                };
                SettingsLayout.Row(apiGroup, "翻译引擎", apiBox);

                var profile = draft.GetApiProfile(draft.ApiProvider).Clone();
                TextBox? appIdBox = null;
                if (TranslationCatalog.RequiresAppId(draft.ApiProvider))
                {
                    appIdBox = new TextBox { Text = profile.AppId, Width = 230, VerticalContentAlignment = VerticalAlignment.Center };
                    SettingsLayout.Row(apiGroup, TranslationCatalog.AppIdLabel(draft.ApiProvider), appIdBox);
                }

                string scope = TranslationSecrets.ApiScope(draft.ApiProvider, profile.CustomBaseUrl);
                var secretUi = CreateSecretInput(scope);
                SettingsLayout.Row(apiGroup, TranslationCatalog.SecretLabel(draft.ApiProvider), secretUi.Control);

                TextBox? regionBox = null;
                if (TranslationCatalog.SupportsRegion(draft.ApiProvider))
                {
                    regionBox = new TextBox { Text = profile.Region, Width = 230, VerticalContentAlignment = VerticalAlignment.Center };
                    SettingsLayout.Row(apiGroup, "区域", regionBox);
                }

                TextBox? endpointBox = null;
                if (TranslationCatalog.SupportsCustomEndpoint(draft.ApiProvider))
                {
                    endpointBox = new TextBox { Text = profile.CustomBaseUrl, Width = 230, VerticalContentAlignment = VerticalAlignment.Center };
                    SettingsLayout.Row(apiGroup, "自定义端点", endpointBox);
                }

                var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12, 8, 12, 10) };
                var clearBtn = Button("清除密钥");
                var testBtn = Button("试译");
                var saveBtn = Button("保存配置");
                saveBtn.SetResourceReference(StyleProperty, "SnapPrimary");

                TranslationApiProfile ReadProfile() => new()
                {
                    AppId = appIdBox?.Text.Trim() ?? "",
                    Region = regionBox?.Text.Trim() ?? (draft.ApiProvider == TranslationApiProvider.Tencent ? "ap-beijing" : ""),
                    CustomBaseUrl = endpointBox?.Text.Trim() ?? ""
                };

                saveBtn.Click += (_, _) =>
                {
                    try
                    {
                        var updated = ReadProfile();
                        if (updated.CustomBaseUrl.Length > 0 && ThirdPartyTranslation.ValidateCustomEndpoint(updated.CustomBaseUrl) is null)
                            throw new InvalidOperationException("自定义端点必须是 HTTPS 或本机回环地址。");
                        string keyScope = TranslationSecrets.ApiScope(draft.ApiProvider, updated.CustomBaseUrl);
                        string val = secretUi.GetText().Trim();
                        if (val.Length > 0) TranslationSecrets.Save(keyScope, val);
                        draft.SetApiProfile(draft.ApiProvider, updated);
                        RecognitionService.Settings.Translation = draft.Clone();
                        RecognitionService.SaveSettings(RecognitionService.Settings);
                        TranslationEngine.Prewarm(RecognitionService.Settings);
                        statusLine.Text = "已保存翻译配置";
                    }
                    catch (Exception error) { statusLine.Text = error.Message; }
                };

                clearBtn.Click += (_, _) =>
                {
                    var updated = ReadProfile();
                    TranslationSecrets.Remove(TranslationSecrets.ApiScope(draft.ApiProvider, updated.CustomBaseUrl));
                    secretUi.SetText("");
                    statusLine.Text = "已清除密钥";
                };

                testBtn.Click += async (_, _) =>
                {
                    testBtn.IsEnabled = false;
                    statusLine.Text = "正在试译 Hello…";
                    try
                    {
                        var updated = ReadProfile();
                        string? key = secretUi.GetText().Trim();
                        if (string.IsNullOrEmpty(key))
                            key = TranslationSecrets.Read(TranslationSecrets.ApiScope(draft.ApiProvider, updated.CustomBaseUrl));
                        string translated = await ThirdPartyTranslation.TranslateApiAsync(
                            "Hello", "en", "zh-Hans", draft.ApiProvider, updated, key, lifetimeToken);
                        statusLine.Text = $"试译成功：{translated}";
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception error) { statusLine.Text = error.Message; }
                    finally { testBtn.IsEnabled = true; }
                };

                btnRow.Children.Add(clearBtn);
                btnRow.Children.Add(testBtn);
                btnRow.Children.Add(saveBtn);
                apiGroup.Children.Add(btnRow);
            }
            else
            {
                bool isLocal = draft.Provider == TranslationProviderKind.Local;
                var modelGroup = SettingsLayout.Group(configHost, isLocal ? "本机模型配置" : "在线模型配置");
                if (!isLocal)
                {
                    var presetBox = new ComboBox
                    {
                        ItemsSource = new[] { "DeepSeek", "通义千问", "自定义兼容服务" },
                        SelectedIndex = draft.OnlinePreset switch
                        {
                            OnlineModelPreset.DeepSeek => 0,
                            OnlineModelPreset.Qwen => 1,
                            _ => 2
                        },
                        Width = 170
                    };
                    presetBox.SelectionChanged += (_, _) =>
                    {
                        var next = presetBox.SelectedIndex switch
                        {
                            0 => OnlineModelPreset.DeepSeek,
                            1 => OnlineModelPreset.Qwen,
                            _ => OnlineModelPreset.Custom
                        };
                        if (next != draft.OnlinePreset)
                        {
                            draft.OnlinePreset = next;
                            RebuildServiceFields();
                        }
                    };
                    SettingsLayout.Row(modelGroup, "服务商", presetBox);
                }

                var legacyLocal = isLocal ? RecognitionAi.TranslationDraft(RecognitionService.Settings) : ((string, string)?)null;
                var profile = draft.GetModelProfile(isLocal, draft.OnlinePreset, legacyLocal).Clone();
                var epBox = new TextBox { Text = profile.Endpoint, Width = 230, VerticalContentAlignment = VerticalAlignment.Center };
                var mdlBox = new TextBox { Text = profile.Model, Width = 230, VerticalContentAlignment = VerticalAlignment.Center };
                SettingsLayout.Row(modelGroup, "服务地址", epBox);
                SettingsLayout.Row(modelGroup, "模型名称", mdlBox);

                (FrameworkElement Control, Func<string> GetText, Action<string> SetText)? secretUi = null;
                if (!isLocal)
                {
                    secretUi = CreateSecretInput(TranslationSecrets.ModelScope(false, draft.OnlinePreset, profile.Endpoint));
                    SettingsLayout.Row(modelGroup, "API Key", secretUi.Value.Control);
                }

                var btnRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12, 8, 12, 10) };
                var testBtn = Button("试译");
                var saveBtn = Button("保存配置");
                saveBtn.SetResourceReference(StyleProperty, "SnapPrimary");

                TranslationModelProfile ReadModel() => new() { Endpoint = epBox.Text.Trim(), Model = mdlBox.Text.Trim() };

                if (!isLocal && secretUi is { } keyControl)
                {
                    var clearBtn = Button("清除密钥");
                    clearBtn.Click += (_, _) =>
                    {
                        TranslationSecrets.Remove(TranslationSecrets.ModelScope(false, draft.OnlinePreset, epBox.Text.Trim()));
                        keyControl.SetText("");
                        statusLine.Text = "已清除密钥";
                    };
                    btnRow.Children.Add(clearBtn);
                }

                saveBtn.Click += (_, _) =>
                {
                    try
                    {
                        var updated = ReadModel();
                        var uri = RecognitionAi.TryEndpoint(new RecognitionSettings { AiEndpoint = updated.Endpoint, AiModel = updated.Model });
                        if (uri is null) throw new InvalidOperationException("请填写有效的模型地址和模型名称。");
                        if (isLocal && !uri.IsLoopback) throw new InvalidOperationException("本机模型仅允许 localhost / 回环地址。");
                        if (!isLocal && uri.IsLoopback) throw new InvalidOperationException("在线模型请使用 HTTPS 远程地址。");
                        if (!isLocal && secretUi is { } k)
                        {
                            string val = k.GetText().Trim();
                            if (val.Length > 0) TranslationSecrets.Save(TranslationSecrets.ModelScope(false, draft.OnlinePreset, updated.Endpoint), val);
                        }
                        draft.SetModelProfile(isLocal, draft.OnlinePreset, updated);
                        RecognitionService.Settings.Translation = draft.Clone();
                        if (isLocal)
                        {
                            RecognitionService.Settings.TranslationEndpoint = updated.Endpoint;
                            RecognitionService.Settings.TranslationModel = updated.Model;
                        }
                        RecognitionService.SaveSettings(RecognitionService.Settings);
                        TranslationEngine.Prewarm(RecognitionService.Settings);
                        statusLine.Text = "已保存翻译配置";
                    }
                    catch (Exception error) { statusLine.Text = error.Message; }
                };

                testBtn.Click += async (_, _) =>
                {
                    testBtn.IsEnabled = false;
                    statusLine.Text = "正在试译 Hello…";
                    try
                    {
                        var updated = ReadModel();
                        string? key = isLocal ? null : secretUi?.GetText().Trim();
                        if (!isLocal && string.IsNullOrEmpty(key))
                            key = TranslationSecrets.Read(TranslationSecrets.ModelScope(false, draft.OnlinePreset, updated.Endpoint));
                        string translated = await ThirdPartyTranslation.TranslateModelStreamAsync(
                            "Hello", "en", "zh-Hans", updated, isLocal, key, null, lifetimeToken);
                        statusLine.Text = $"试译成功：{translated}";
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception error) { statusLine.Text = error.Message; }
                    finally { testBtn.IsEnabled = true; }
                };

                btnRow.Children.Add(testBtn);
                btnRow.Children.Add(saveBtn);
                modelGroup.Children.Add(btnRow);
            }
        }

        providerBox.SelectionChanged += (_, _) =>
        {
            draft.Provider = providerBox.SelectedIndex switch
            {
                0 => TranslationProviderKind.Api,
                1 => TranslationProviderKind.Local,
                _ => TranslationProviderKind.Online
            };
            RecognitionService.Settings.Translation.Provider = draft.Provider;
            RecognitionService.SaveSettings(RecognitionService.Settings);
            RebuildServiceFields();
        };

        RebuildServiceFields();
        return panel;
    }

    private StackPanel RuleSettings()
    {
        var stack = new StackPanel { Margin = new Thickness(12) };
        scan.IsChecked = original.ScanAutomatically;
        stack.Children.Add(scan);
        foreach (var rule in PrivacyRules.Definitions)
        {
            var mode = ModeBox(original.Mode(rule.Kind));
            modes.Add(rule.Kind, mode);
            stack.Children.Add(Row(rule.Label, mode));
        }
        domains.Text = original.InternalDomains;
        domains.ToolTip = "多个后缀用空格或逗号分隔，例如 corp.example";
        stack.Children.Add(Row("内部域名后缀", domains));
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        stack.Children.Add(new TextBlock { Text = "自定义正则规则", FontWeight = FontWeights.SemiBold });
        stack.Children.Add(customEntries);
        foreach (var rule in original.CustomRules)
            AddCustom(rule);
        var add = Button("添加规则");
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Click += (_, _) => AddCustom(new CustomPrivacyRule("", "", PrivacyRuleMode.Review));
        stack.Children.Add(add);
        return stack;
    }

    private StackPanel ModelSettings()
    {
        var stack = new StackPanel { Margin = new Thickness(12) };
        language.Text = original.OcrLanguages;
        language.ToolTip = "留空自动选择。Windows 语言如 zh-CN、en-US，Tesseract 语言如 chi_sim+eng";
        stack.Children.Add(Row("本机 OCR 语言", language));
        copyOcr.IsChecked = original.OcrAutoCopy;
        collapseOcr.IsChecked = original.OcrCollapseNewlines;
        stack.Children.Add(copyOcr);
        stack.Children.Add(collapseOcr);
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        var provider = new ComboBox { ItemsSource = new[] { "仅本机规则", "DeepSeek", "Qwen（通义千问）",
            "本机模型（Ollama 等）", "自定义兼容服务" } };
        provider.SelectedIndex = original.AiEndpoint switch
        {
            "" => 0,
            var address when address.StartsWith("https://api.deepseek.com", StringComparison.Ordinal) => 1,
            var address when address.StartsWith("https://dashscope.aliyuncs.com", StringComparison.Ordinal) => 2,
            var address when Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.IsLoopback => 3,
            _ => 4
        };
        provider.SelectionChanged += (_, _) =>
        {
            apiKey.Clear();
            clearKey.IsChecked = false;
            (endpoint.Text, model.Text) = provider.SelectedIndex switch
            {
                0 => ("", ""),
                1 => ("https://api.deepseek.com", "deepseek-flash"),
                2 => ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
                3 => ("http://127.0.0.1:11434/v1", ""),
                _ => (endpoint.Text, model.Text)
            };
        };
        stack.Children.Add(Row("AI 补查预设", provider));
        endpoint.Text = original.AiEndpoint;
        model.Text = original.AiModel;
        stack.Children.Add(Row("服务地址", endpoint));
        stack.Children.Add(Row("模型名称", model));
        stack.Children.Add(Row("API Key", apiKey));
        var test = Button("测试连接");
        bool testing = false;
        test.HorizontalAlignment = HorizontalAlignment.Left;
        test.ToolTip = "发送一段合成文字来测试连接";
        test.Click += async (_, _) =>
        {
            testing = true;
            test.IsEnabled = false;
            status.Text = "正在用合成文字测试…";
            try
            {
                await RecognitionAi.TestAsync(AiDraft(), apiKey.Password.Trim(), lifetime.Token);
                status.Text = "模型连接成功";
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            catch (Exception error) { status.Text = error.Message; }
            finally { testing = false; RefreshKey(); }
        };
        void RefreshKey()
        {
            var uri = RecognitionAi.TryEndpoint(AiDraft());
            test.IsEnabled = uri is not null && !testing;
            bool has = false;
            try { has = uri is not null && RecognitionAi.HasKey(uri); }
            catch (Exception error) when (error is System.Security.Cryptography.CryptographicException or JsonException or IOException) { }
            clearKey.IsEnabled = has;
            if (!has) clearKey.IsChecked = false;
        }
        endpoint.TextChanged += (_, _) => { apiKey.Clear(); clearKey.IsChecked = false; RefreshKey(); };
        model.TextChanged += (_, _) => RefreshKey();
        RefreshKey();
        stack.Children.Add(test);
        stack.Children.Add(clearKey);
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        python.Text = original.FormulaPython;
        python.ToolTip = "留空使用 Install-Formula.ps1 安装的本机环境";
        var pythonRow = new DockPanel();
        var pick = Button("浏览…");
        DockPanel.SetDock(pick, Dock.Right);
        pick.Click += (_, _) =>
        {
            var dialog = new OpenFileDialog { Filter = "Python 解释器 (python.exe)|python.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) == true) python.Text = dialog.FileName;
        };
        pythonRow.Children.Add(pick);
        pythonRow.Children.Add(python);
        stack.Children.Add(Row("公式 Python 路径", pythonRow));
        return stack;
    }

    private RecognitionSettings AiDraft() => new() { AiEndpoint = endpoint.Text.Trim(), AiModel = model.Text.Trim() };

    private void AddCustom(CustomPrivacyRule rule)
    {
        var name = new TextBox { Text = rule.Name, ToolTip = "规则名称" };
        var pattern = new TextBox { Text = rule.Pattern, ToolTip = "正则表达式" };
        var mode = ModeBox(rule.Mode);
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 5) };
        panel.Children.Add(Row("名称", name));
        panel.Children.Add(Row("正则表达式", pattern));
        var actions = new DockPanel();
        var remove = Button("移除");
        DockPanel.SetDock(remove, Dock.Right);
        actions.Children.Add(remove);
        actions.Children.Add(Row("规则模式", mode));
        panel.Children.Add(actions);
        panel.Children.Add(new Separator());
        var entry = new CustomEntry(name, pattern, mode);
        customs.Add(entry);
        remove.Click += (_, _) =>
        {
            customs.Remove(entry);
            customEntries.Children.Remove(panel);
        };
        customEntries.Children.Add(panel);
    }

    private void Save()
    {
        try
        {
            var current = RecognitionService.Settings;
            var settings = new RecognitionSettings
            {
                ScanAutomatically = scan.IsChecked == true,
                OcrLanguages = language.Text.Trim(),
                OcrAutoCopy = copyOcr.IsChecked == true,
                OcrCollapseNewlines = collapseOcr.IsChecked == true,
                InternalDomains = domains.Text.Trim(),
                AiEndpoint = endpoint.Text.Trim(),
                AiModel = model.Text.Trim(),
                TranslationEndpoint = current.TranslationEndpoint,
                TranslationModel = current.TranslationModel,
                Translation = current.Translation.Clone(),
                FormulaPython = python.Text.Trim()
            };
            foreach (var field in modes)
                settings.Modes[field.Key] = (PrivacyRuleMode)field.Value.SelectedIndex;
            foreach (var input in customs)
            {
                string name = input.Name.Text.Trim(), pattern = input.Pattern.Text;
                if (name.Length == 0 || pattern.Length is < 1 or > 512)
                    throw new InvalidOperationException("每条自定义规则需要名称和 1–512 个字符的正则表达式。");
                try { _ = new Regex(pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(35)); }
                catch (ArgumentException) { throw new InvalidOperationException($"自定义规则「{name}」的正则语法有误。"); }
                settings.CustomRules.Add(new CustomPrivacyRule(name, pattern, (PrivacyRuleMode)input.Mode.SelectedIndex));
            }
            Uri? aiEndpoint = settings.AiEndpoint.Length > 0 || settings.AiModel.Length > 0 ? RecognitionAi.Endpoint(settings) : null;
            if (settings.FormulaPython.Length > 0 &&
                (!Path.IsPathFullyQualified(settings.FormulaPython) || !File.Exists(settings.FormulaPython)))
                throw new InvalidOperationException("请选择已安装的 python.exe。");

            if (aiEndpoint is not null)
            {
                string key = apiKey.Password.Trim();
                if (clearKey.IsChecked == true && key.Length == 0)
                    RecognitionAi.SaveKey("", aiEndpoint);
                else if (key.Length > 0)
                    RecognitionAi.SaveKey(key, aiEndpoint);
            }
            RecognitionService.SaveSettings(settings);
            apiKey.Clear();
            Close();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法保存识别设置", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static ComboBox ModeBox(PrivacyRuleMode selected) => new()
    {
        ItemsSource = new[] { "自动打码", "仅提示", "关闭" },
        SelectedIndex = (int)selected,
        Width = 112
    };

    private static DockPanel Row(string label, FrameworkElement control)
    {
        var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
        var caption = new TextBlock { Text = label, Width = 136, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(caption, Dock.Left);
        row.Children.Add(caption);
        row.Children.Add(control);
        return row;
    }

    private static Button Button(string title) => new()
    {
        Content = title, Padding = new Thickness(11, 5, 11, 5), Margin = new Thickness(4, 0, 0, 0)
    };

    private sealed record CustomEntry(TextBox Name, TextBox Pattern, ComboBox Mode);
}
